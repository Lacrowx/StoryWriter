import AppKit
import Combine
import UniformTypeIdentifiers

enum ProjectError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct Revision: Identifiable {
    var url: URL
    var date: Date
    var name: String?
    var id: String { url.path }
}

@MainActor
final class ProjectStore: ObservableObject {
    var projects: [StoryProject] = [] {
        willSet { if !typing { objectWillChange.send() } }
    }
    private var typing = false
    private var typingRefresh: Task<Void, Never>?
    private var mentionLinkTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingMentionLinks: [UUID: Set<ProjectTagReference>] = [:]
    @Published var selectedProjectID: UUID? {
        didSet { workspacePreferences.projectID = selectedProjectID }
    }
    @Published var saveStatus = "Saved on this Mac"
    @Published var errorMessage: String?
    @Published var search = ""
    @Published var showArchived = false
    @Published var backupConfigurations: [UUID: BackupConfiguration] = [:]
    var backupTasks: [UUID: Task<Void, Never>] = [:]
    var backupGenerations: [UUID: UUID] = [:]
    var backupRunning = Set<UUID>()
    let root: URL
    private let workspaceDefaults: UserDefaults
    var workspacePreferences: WorkspacePreferences { WorkspacePreferences(root: root, defaults: workspaceDefaults) }
    private var saveTask: Task<Void, Never>?
    private var dirty = Set<UUID>()
    private var lastRevision: [UUID: Date] = [:]
    private var syncObservation: AnyCancellable?
    lazy var sync: DriveSync = {
        let service = DriveSync(store: self)
        // Menus and the library's sheet binding also read child sync state.
        syncObservation = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return service
    }()

    init(root: URL? = nil, createExample: Bool = true, workspaceDefaults: UserDefaults = .standard) {
        let override = ProcessInfo.processInfo.environment["STORYWRITER_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.root = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StoryWriter/Projects", isDirectory: true)
        self.workspaceDefaults = workspaceDefaults
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let directories = try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "storywriter" && !$0.lastPathComponent.hasPrefix(".") }
            for directory in directories {
                do {
                    let project = try Self.readPackage(directory)
                    guard directory.lastPathComponent == "\(project.id.uuidString).storywriter" else { throw ProjectError.invalid("Project folder and identifier do not match.") }
                    projects.append(project)
                } catch { errorMessage = "Could not open \(directory.lastPathComponent). Your files were left in place. \(error.localizedDescription)" }
            }
            projects.sort { $0.modifiedAt > $1.modifiedAt }
            if directories.isEmpty && createExample { let example = StoryProject.example(); projects.append(example); dirty.insert(example.id); _ = saveNow() }
            selectedProjectID = workspacePreferences.resumesWorkspace ? projects.first(where: { $0.id == workspacePreferences.projectID && !$0.archived })?.id
                ?? projects.first(where: { !$0.archived })?.id : nil
            loadBackupSettings()
            for project in projects { scheduleBackup(project.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    var selectedProject: StoryProject? { projects.first { $0.id == selectedProjectID } }
    var visibleProjects: [StoryProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { $0.archived == showArchived && (query.isEmpty || [$0.title, $0.author, $0.genre, $0.premise].joined(separator: " ").localizedCaseInsensitiveContains(query)) }
    }

    func toggleArchivedProjects() {
        showArchived.toggle()
        selectedProjectID = visibleProjects.first?.id
    }

    func project(_ id: UUID) -> StoryProject? { projects.first { $0.id == id } }
    func packageURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).storywriter", isDirectory: true) }
    func mediaURL(_ source: ReferenceSource, projectID: UUID, snapshot: Bool = false) -> URL? {
        guard let path = snapshot ? source.snapshotPath : source.relativePath, Self.isSafeRelativePath(path) else { return nil }
        return packageURL(projectID).appendingPathComponent(path)
    }

    func update(_ id: UUID, linkMentions: Bool = true, _ change: (inout StoryProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let previousNames = linkMentions ? ObjectMentionLinker.names(in: projects[index]) : [:]
        let previousReferences = linkMentions ? Set(projects[index].characters.map { ProjectTagReference(kind: .character, objectID: $0.id) }
            + projects[index].worldNotes.map { ProjectTagReference(kind: .world, objectID: $0.id) }) : []
        change(&projects[index])
        if linkMentions {
            let names = ObjectMentionLinker.names(in: projects[index])
            let changed = Set(names.keys.filter { names[$0] != previousNames[$0] })
            let created = changed.subtracting(previousReferences)
            if !created.isEmpty { ObjectMentionLinker(names: names).link(in: &projects[index], references: created) }
            let edited = changed.intersection(previousReferences)
            if !edited.isEmpty {
                pendingMentionLinks[id, default: []].formUnion(edited)
                mentionLinkTasks[id]?.cancel()
                mentionLinkTasks[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    self?.flushMentionLinks(id)
                }
            }
        } else if !typing {
            // Revision restoration must preserve its original links exactly.
            mentionLinkTasks.removeValue(forKey: id)?.cancel(); pendingMentionLinks.removeValue(forKey: id)
        }
        projects[index].modifiedAt = Date()
        dirty.insert(id); if saveStatus != "Saving…" { saveStatus = "Saving…" }
        saveTask?.cancel()
        let delay = ApplicationPreferences(defaults: workspaceDefaults).autosaveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = self?.saveNow()
        }
    }

    private func flushMentionLinks(_ id: UUID) {
        mentionLinkTasks.removeValue(forKey: id)?.cancel()
        guard let references = pendingMentionLinks.removeValue(forKey: id),
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        ObjectMentionLinker(names: ObjectMentionLinker.names(in: projects[index])).link(in: &projects[index], references: references)
    }

    /// Keeps typed text current for saving, search, and export, but redraws the
    /// views that depend on it once the writer pauses instead of on every key.
    func updateWhileTyping(_ id: UUID, _ change: (inout StoryProject) -> Void) {
        typing = true; update(id, linkMentions: false, change); typing = false
        typingRefresh?.cancel()
        typingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.objectWillChange.send()
        }
    }

    @discardableResult func create(title: String, kind: ProjectKind) -> UUID {
        let project = StoryProject.new(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled \(kind.label.lowercased())" : title, kind: kind)
        showArchived = false; search = ""
        projects.insert(project, at: 0); selectedProjectID = project.id; dirty.insert(project.id); _ = saveNow()
        return project.id
    }

    @discardableResult func saveNow() -> Bool {
        saveTask?.cancel()
        for id in Array(pendingMentionLinks.keys) { flushMentionLinks(id) }
        let hadChanges = !dirty.isEmpty
        var failed = false
        for id in Array(dirty) {
            guard let project = project(id) else { continue }
            do {
                let directory = packageURL(id)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let manifest = directory.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath: manifest.path), Date().timeIntervalSince(lastRevision[id] ?? .distantPast) > ApplicationPreferences(defaults: workspaceDefaults).revisionInterval {
                    try checkpoint(id)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(project).write(to: manifest, options: .atomic)
                dirty.remove(id)
                scheduleBackup(id)
            } catch { failed = true; errorMessage = "Your latest changes could not be saved: \(error.localizedDescription)" }
        }
        saveStatus = failed ? "Save failed — retry with ⌘S" : "Saved on this Mac"
        if !failed && hadChanges { sync.saved() }
        return !failed
    }

    func checkpoint(_ id: UUID, name: String? = nil) throws {
        let directory = packageURL(id)
        let manifest = directory.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        let history = directory.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let date = Date()
        let revision = history.appendingPathComponent("\(date.timeIntervalSince1970)-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: manifest, to: revision)
        if let name { try name.write(to: revision.appendingPathExtension("label"), atomically: true, encoding: .utf8) }
        lastRevision[id] = date
        for old in revisions(id).filter({ $0.name == nil }).dropFirst(30) { try FileManager.default.removeItem(at: old.url) }
    }

    func revisions(_ id: UUID) -> [Revision] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: packageURL(id).appendingPathComponent("History"), includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { Revision(url: $0, date: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, name: try? String(contentsOf: $0.appendingPathExtension("label"), encoding: .utf8)) }.sorted { $0.date > $1.date }
    }

    func restore(_ revision: Revision, projectID: UUID) {
        do {
            let restored = try Self.decode(Data(contentsOf: revision.url))
            guard restored.id == projectID else { throw ProjectError.invalid("This revision belongs to a different project.") }
            guard saveNow() else { return }
            try checkpoint(projectID)
            update(projectID, linkMentions: false) { $0 = restored }
            _ = saveNow()
        } catch { errorMessage = error.localizedDescription }
    }

    func importPackage(_ url: URL) {
        do {
            var imported = try Self.readPackage(url)
            let local = packageURL(imported.id)
            if url.standardizedFileURL == local.standardizedFileURL { showArchived = imported.archived; search = ""; selectedProjectID = imported.id; return }
            imported.id = UUID(); imported.archived = false; imported.modifiedAt = Date()
            let destination = packageURL(imported.id)
            try FileManager.default.copyItem(at: url, to: destination)
            // Revisions retain the old identifier and cannot be applied to the imported copy.
            let history = destination.appendingPathComponent("History")
            if FileManager.default.fileExists(atPath: history.path) { try FileManager.default.removeItem(at: history) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(imported).write(to: destination.appendingPathComponent("project.json"), options: .atomic)
            lastRevision[imported.id] = Date()
            showArchived = false; search = ""
            projects.insert(imported, at: 0); dirty.insert(imported.id); selectedProjectID = imported.id; _ = saveNow()
        } catch { errorMessage = "Could not import project: \(error.localizedDescription)" }
    }

    func exportPackage(_ id: UUID, to destination: URL) throws {
        guard saveNow() else { throw ProjectError.invalid("Save your changes before making a portable copy.") }
        guard destination.standardizedFileURL != packageURL(id).standardizedFileURL else { throw ProjectError.invalid("Choose a location outside the app's library.") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".storywriter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: packageURL(id), to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }

    func importFiles(_ urls: [URL], projectID: UUID) {
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw ProjectError.invalid("Choose individual reference files, rather than folders.") }
                var source = ReferenceSource(title: url.deletingPathExtension().lastPathComponent)
                source.relativePath = "Media/\(source.id.uuidString)/\(url.lastPathComponent)"
                let destination = packageURL(projectID).appendingPathComponent(source.relativePath!)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: destination)
                update(projectID) { $0.sources.append(source) }
            } catch { errorMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)" }
        }
        _ = saveNow()
    }

    func addLink(_ rawURL: String, title: String, projectID: UUID) throws {
        let cleaned = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.contains("://") ? cleaned : "https://\(cleaned)"
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw ProjectError.invalid("Enter a valid http or https web address.") }
        let source = ReferenceSource(title: title.isEmpty ? (url.host ?? value) : title, webURL: url.absoluteString)
        update(projectID) { $0.sources.append(source) }
    }

    func saveWebArchive(_ data: Data, sourceID: UUID, projectID: UUID) {
        do {
            let path = "Media/\(sourceID.uuidString)/Saved page.webarchive"
            let destination = packageURL(projectID).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            update(projectID) { project in if let i = project.sources.firstIndex(where: { $0.id == sourceID }) { project.sources[i].snapshotPath = path } }
            _ = saveNow()
        } catch { errorMessage = "Could not save the page offline: \(error.localizedDescription)" }
    }

    func importChapter(_ url: URL, projectID: UUID) {
        do {
            let text: NSAttributedString
            if ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) {
                text = NSAttributedString(string: try String(contentsOf: url, encoding: .utf8), attributes: WritingStyle.attributes)
            } else { text = try NSAttributedString(url: url, options: [:], documentAttributes: nil) }
            var chapter = Chapter(title: url.deletingPathExtension().lastPathComponent, status: .drafting)
            try chapter.setText(text)
            update(projectID) { $0.chapters.append(chapter) }
        } catch { errorMessage = "Could not import chapter: \(error.localizedDescription)" }
    }

    nonisolated static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && !path.contains("\\")
    }

    nonisolated static func decode(_ data: Data) throws -> StoryProject {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(StoryProject.self, from: data)
        guard project.schemaVersion == 1 else { throw ProjectError.invalid("This project uses an unsupported format. Update StoryWriter to open it.") }
        var ids: [UUID] = project.chapters.map(\.id)
        ids.append(contentsOf: project.characters.map(\.id))
        ids.append(contentsOf: project.worldNotes.map(\.id))
        ids.append(contentsOf: project.sources.map(\.id))
        for chapter in project.chapters {
            ids.append(contentsOf: (chapter.scenes ?? []).map(\.id))
            ids.append(contentsOf: (chapter.comments ?? []).map(\.id))
            ids.append(contentsOf: (chapter.continuityEvents ?? []).map(\.id))
        }
        ids.append(contentsOf: (project.continuityItems ?? []).map(\.id))
        ids.append(contentsOf: (project.initialContinuity ?? []).map(\.id))
        guard Set(ids).count == ids.count else { throw ProjectError.invalid("The project contains duplicate item identifiers.") }
        for chapter in project.chapters {
            let scenes = chapter.scenes ?? []
            guard scenes.isEmpty || (scenes.first?.start == 0 && scenes.map(\.start) == scenes.map(\.start).sorted() && scenes.allSatisfy { $0.start >= 0 && $0.start <= chapter.plainText.utf16.count }) else { throw ProjectError.invalid("The project contains invalid scene boundaries.") }
            for comment in chapter.comments ?? [] {
                guard comment.start >= 0, comment.length > 0, comment.detached || (comment.start <= chapter.plainText.utf16.count && comment.length <= chapter.plainText.utf16.count - comment.start) else { throw ProjectError.invalid("The project contains an invalid passage comment.") }
            }
            for event in chapter.continuityEvents ?? [] {
                guard event.start >= 0, event.length >= 0, event.start <= Int.max - event.length,
                      event.detached || Continuity.validatesAnchor(event, in: chapter.plainText) else { throw ProjectError.invalid("The project contains an invalid continuity passage.") }
            }
        }
        let items = project.continuityItems ?? []
        for item in items {
            guard !Continuity.normalized(item.name).isEmpty else { throw ProjectError.invalid("A continuity item has no name.") }
            var ancestor = item.parentID, visited = Set([item.id])
            while let id = ancestor {
                guard visited.insert(id).inserted, let parent = items.first(where: { $0.id == id }), parent.category == item.category else { throw ProjectError.invalid("The project contains an invalid continuity topic.") }
                ancestor = parent.parentID
            }
        }
        for event in (project.initialContinuity ?? []) + project.chapters.flatMap({ $0.continuityEvents ?? [] }) {
            guard let item = items.first(where: { $0.id == event.itemID }), item.category == event.action.category else { throw ProjectError.invalid("A continuity change refers to a missing or incompatible item.") }
        }
        for source in project.sources {
            for path in [source.relativePath, source.snapshotPath].compactMap({ $0 }) where !isSafeRelativePath(path) { throw ProjectError.invalid("The project contains an invalid media path.") }
            if let link = source.webURL, let url = URL(string: link), !["http", "https"].contains(url.scheme?.lowercased() ?? "") { throw ProjectError.invalid("The project contains an unsupported web address.") }
        }
        return project
    }

    nonisolated static func readPackage(_ url: URL) throws -> StoryProject {
        guard url.pathExtension == "storywriter" else { throw ProjectError.invalid("Choose a .storywriter project.") }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw ProjectError.invalid("Choose the original project rather than a symbolic link.") }
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let item as URL in enumerator where (try item.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw ProjectError.invalid("Projects containing symbolic links cannot be imported.")
            }
        }
        return try decode(Data(contentsOf: url.appendingPathComponent("project.json")))
    }
}
