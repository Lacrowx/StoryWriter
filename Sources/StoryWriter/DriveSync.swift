import AppKit
import Combine
import Foundation

private struct DriveSyncState: Codable {
    var folder: String?
    var bookmark: Data?
    var deviceID = UUID()
    var heads: [UUID: UUID] = [:]
}

struct DriveReview: Identifiable {
    var id = UUID()
    var projectID: UUID { local.project.id }
    var base: DriveRevision?
    var local: DriveRevision
    var incoming: DriveRevision
    var conflicts: [MergeConflict]
}

@MainActor
final class DriveSync: ObservableObject {
    weak var store: ProjectStore?
    @Published private(set) var status = "Sync is off"
    @Published private(set) var folder: URL?
    @Published private(set) var reviews: [UUID: DriveReview] = [:]
    @Published var reviewProjectID: UUID?
    @Published private(set) var running = false
    private var state = DriveSyncState()
    private let stateURL: URL
    let cache: URL
    private var timer: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var epoch = UUID()
    private var scoped = false
    private var scopedURL: URL?
    private var started = false
    private var knownGraph: [UUID: DriveRevision] = [:]

    init(store: ProjectStore) {
        self.store = store
        stateURL = store.root.appendingPathComponent(".drive-sync.json")
        cache = store.root.appendingPathComponent(".drive-sync-cache", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) { state = try JSONDecoder().decode(DriveSyncState.self, from: Data(contentsOf: stateURL)) }
            if let path = state.folder {
                var stale = false
                let selected = state.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) } ?? URL(fileURLWithPath: path, isDirectory: true)
                folder = selected; scoped = selected.startAccessingSecurityScopedResource(); scopedURL = selected
                status = "Checking for changes…"
                if stale { state.bookmark = try? selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil); try persist() }
            }
        } catch { status = "Sync needs attention: \(error.localizedDescription)" }
    }
    deinit {
        timer?.cancel(); scheduled?.cancel()
        if scoped { scopedURL?.stopAccessingSecurityScopedResource() }
    }
    private func persist() throws { try JSONEncoder().encode(state).write(to: stateURL, options: .atomic) }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose a StoryWriter sync folder"
        panel.message = "Choose the same folder in iCloud Drive on each Mac. All stories and reference collections in this library will connect. Your writing also stays saved locally."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try configure(folder: url) } catch { store?.errorMessage = error.localizedDescription }
    }
    func configure(folder selected: URL, start: Bool = true) throws {
        guard let store else { return }
        try PortableBackup.validate(folder: selected, library: store.root)
        guard (try selected.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw ProjectError.invalid("Choose an existing sync folder.") }
        let previous = state
        state.folder = selected.path
        state.bookmark = try selected.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if folder?.standardizedFileURL != selected.standardizedFileURL { state.heads = [:] }
        do { try persist() } catch { state = previous; throw error }
        stopTasks()
        if scoped { folder?.stopAccessingSecurityScopedResource() }
        folder = selected; scoped = selected.startAccessingSecurityScopedResource(); scopedURL = selected
        knownGraph = [:]; reviews = [:]; reviewProjectID = nil; status = "Checking for changes…"
        if start { self.start() }
    }
    func disconnect() {
        let previous = state
        state.folder = nil; state.bookmark = nil
        do { try persist() } catch { state = previous; store?.errorMessage = error.localizedDescription; return }
        stopTasks()
        if scoped { folder?.stopAccessingSecurityScopedResource() }
        scoped = false; folder = nil; knownGraph = [:]; reviews = [:]; reviewProjectID = nil; status = "Sync is off"
    }
    private func stopTasks() { epoch = UUID(); timer?.cancel(); scheduled?.cancel(); timer = nil; scheduled = nil; started = false }
    func start() {
        guard folder != nil, !started else { return }
        started = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    func saved() {
        guard folder != nil else { return }
        if !running { status = reviews.isEmpty ? "Changes waiting to sync" : "Changes need review" }
        guard started, scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.scheduled = nil
            await self?.checkNow()
        }
    }
    func projectStatus(_ id: UUID) -> String { reviews[id] != nil ? "Changes need review" : status }
    private func setHead(_ revision: DriveRevision) throws {
        let previous = state.heads
        state.heads[revision.project.id] = revision.id
        do { try persist() } catch { state.heads = previous; throw error }
    }
    private func currentEpoch(_ expected: UUID) -> Bool { epoch == expected && folder != nil && !Task.isCancelled }

    func checkNow() async {
        guard !running, let folder, let store else { return }
        running = true; defer { running = false }
        let generation = epoch, cache = cache, deviceID = state.deviceID
        let deviceName = Host.current().localizedName ?? "Another Mac"
        status = "Checking for changes…"
        do {
            guard store.saveNow() else { status = "Save locally before syncing"; return }
            var locals: [UUID: DriveRevision] = [:]
            // Publish durable local branches first, even while a conflict is open.
            for snapshot in store.projects {
                let package = store.packageURL(snapshot.id), parent = state.heads[snapshot.id]
                var local = try await Task.detached(priority: .utility) {
                    try DriveSyncTransport.capture(project: snapshot, package: package, cache: cache, parents: parent.map { [$0] } ?? [], deviceID: deviceID, deviceName: deviceName)
                }.value
                guard currentEpoch(generation) else { return }
                if let parent {
                    let previous = try await Task.detached(priority: .utility) { try DriveSyncTransport.cached(parent, cache: cache) }.value
                    guard currentEpoch(generation) else { return }
                    if DriveSyncTransport.sameProject(previous.project, local.project), previous.assets == local.assets {
                        local.id = previous.id; local.parents = previous.parents
                    }
                }
                if local.id != parent {
                    let outgoing = local
                    try await Task.detached(priority: .utility) { try DriveSyncTransport.publish(outgoing, folder: folder, cache: cache) }.value
                    guard currentEpoch(generation) else { return }
                    try setHead(local)
                }
                locals[snapshot.id] = local
                // An edit during file I/O must become its own version next time.
                guard store.project(snapshot.id) == snapshot else { status = "Changes waiting to sync"; return }
            }
            let known = knownGraph
            let scan = try await Task.detached(priority: .utility) { try DriveSyncTransport.scan(folder: folder, cache: cache, known: known) }.value
            guard currentEpoch(generation) else { return }
            knownGraph = scan.revisions
            var graph = scan.revisions
            // Missing parents in the shared folder leave these local branches safe
            // but pending. Do not reconcile against incomplete remote history.
            for (id, local) in locals { if graph[local.id] == nil { locals[id] = nil } }
            for projectID in Set(graph.values.map { $0.project.id }).sorted(by: { $0.uuidString < $1.uuidString }) {
                if store.project(projectID) != nil, locals[projectID] == nil { continue }
                for incoming in DriveSyncTransport.heads(graph, projectID: projectID) {
                    guard currentEpoch(generation) else { return }
                    guard let local = locals[projectID] else {
                        guard store.project(projectID) == nil else { break }
                        guard try await apply(incoming, expected: nil, generation: generation) else { return }
                        try setHead(incoming); locals[projectID] = incoming
                        continue
                    }
                    guard store.project(projectID) == local.project else { status = "Changes waiting to sync"; return }
                    if local.id == incoming.id || DriveSyncTransport.ancestors(local.id, revisions: graph).contains(incoming.id) { continue }
                    if DriveSyncTransport.ancestors(incoming.id, revisions: graph).contains(local.id) {
                        guard try await apply(incoming, expected: local.project, generation: generation) else { return }
                        try setHead(incoming); locals[projectID] = incoming; reviews[projectID] = nil
                        continue
                    }
                    let base = DriveSyncTransport.commonBase(local.id, incoming.id, revisions: graph)
                    let result = try await Task.detached(priority: .utility) { try Self.merged(base: base, local: local, incoming: incoming, deviceID: deviceID, deviceName: deviceName) }.value
                    guard currentEpoch(generation), store.project(projectID) == local.project else { status = "Changes waiting to sync"; return }
                    if !result.conflicts.isEmpty {
                        if reviews[projectID]?.local.id != local.id || reviews[projectID]?.incoming.id != incoming.id {
                            reviews[projectID] = DriveReview(base: base, local: local, incoming: incoming, conflicts: result.conflicts)
                        }
                        break
                    }
                    var revision = result.revision
                    revision.deviceID = deviceID; revision.deviceName = deviceName
                    let outgoing = revision
                    try await Task.detached(priority: .utility) { try DriveSyncTransport.publish(outgoing, folder: folder, cache: cache) }.value
                    guard currentEpoch(generation) else { return }
                    guard try await apply(revision, expected: local.project, generation: generation) else { return }
                    try setHead(revision); locals[projectID] = revision; graph[revision.id] = revision; reviews[projectID] = nil
                }
            }
            status = !reviews.isEmpty ? "Changes need review" : scan.waiting ? "Waiting for iCloud files" : "Available in sync folder"
        } catch {
            if currentEpoch(generation) { status = "Sync needs attention: \(error.localizedDescription)" }
        }
    }

    private nonisolated static func merged(base: DriveRevision?, local: DriveRevision, incoming: DriveRevision, deviceID: UUID, deviceName: String,
                        choices: [String: MergeChoice] = [:]) throws -> (revision: DriveRevision, conflicts: [MergeConflict]) {
        var project: StoryProject, conflicts: [MergeConflict]
        if let base {
            let result = try ProjectMerge.merge(base: base.project, local: local.project, incoming: incoming.project, choices: choices)
            project = result.project; conflicts = result.conflicts
        } else if DriveSyncTransport.sameProject(local.project, incoming.project) {
            project = local.project; conflicts = []
        } else {
            let id = "Story/unrelated history"
            conflicts = [MergeConflict(id: id, title: "Choose a version: no single shared starting point", local: ProjectMerge.summary(local.project), incoming: ProjectMerge.summary(incoming.project))]
            project = choices[id] == .incoming ? incoming.project : local.project
        }
        var assets: [String: String] = [:]
        for path in Set(local.assets.keys).union(incoming.assets.keys).sorted() {
            let b = base?.assets[path], l = local.assets[path], r = incoming.assets[path]
            if l == r || r == b { assets[path] = l }
            else if l == b { assets[path] = r }
            else {
                let id = "Reference file/" + path
                conflicts.append(MergeConflict(id: id, title: "Reference file changed on both Macs: " + (path as NSString).lastPathComponent, local: l == nil ? "Missing" : "This Mac's file", incoming: r == nil ? "Missing" : "Other Mac's file"))
                assets[path] = choices[id] == .incoming ? r : l
            }
        }
        let referencedPaths = project.sources.flatMap { [$0.relativePath, $0.snapshotPath].compactMap { $0 } }
        if referencedPaths.contains(where: { assets[$0] == nil }) {
            let id = "Story/reference records"
            conflicts.append(MergeConflict(id: id, title: "Reference files and their records need review", local: ProjectMerge.summary(local.project), incoming: ProjectMerge.summary(incoming.project)))
            let preferred = choices[id] == .incoming ? incoming : local
            project = preferred.project; assets = preferred.assets
        }
        project.modifiedAt = Date()
        return (DriveRevision(parents: [local.id, incoming.id], deviceID: deviceID, deviceName: deviceName, project: project, assets: assets), conflicts)
    }

    private func apply(_ revision: DriveRevision, expected: StoryProject?, generation: UUID) async throws -> Bool {
        guard let store, currentEpoch(generation), store.project(revision.project.id) == expected else { status = "Changes waiting to sync"; return false }
        guard store.saveNow() else { throw ProjectError.invalid("Your latest local changes could not be saved.") }
        if expected != nil { try store.checkpoint(revision.project.id) }
        let package = store.packageURL(revision.project.id), cache = cache
        let staging = try await Task.detached(priority: .utility) { try DriveSyncTransport.prepare(revision, package: package, cache: cache) }.value
        defer { try? FileManager.default.removeItem(at: staging) }
        guard currentEpoch(generation), store.project(revision.project.id) == expected else { status = "Changes waiting to sync"; return false }
        try DriveSyncTransport.install(staging, at: package)
        if let index = store.projects.firstIndex(where: { $0.id == revision.project.id }) { store.projects[index] = revision.project }
        else { store.projects.append(revision.project); if store.selectedProjectID == nil, !revision.project.archived { store.selectedProjectID = revision.project.id } }
        store.scheduleBackup(revision.project.id)
        return true
    }

    func resolve(_ review: DriveReview, choices: [String: MergeChoice], keepBoth: Bool = false) async -> Bool {
        guard !running, let folder, let store, reviews[review.projectID]?.id == review.id else { return false }
        // Keep the dialog honest if the writer continued editing after opening it.
        guard store.project(review.projectID) == review.local.project else { await checkNow(); return false }
        running = true; defer { running = false }
        let generation = epoch, cache = cache
        do {
            let deviceID = state.deviceID, deviceName = Host.current().localizedName ?? "Mac"
            let result = try await Task.detached(priority: .utility) { try Self.merged(base: review.base, local: review.local, incoming: review.incoming, deviceID: deviceID, deviceName: deviceName, choices: choices) }.value
            guard currentEpoch(generation), store.project(review.projectID) == review.local.project else { status = "Changes waiting to sync"; return false }
            guard keepBoth || result.conflicts.allSatisfy({ choices[$0.id] != nil }) else {
                reviews[review.projectID] = DriveReview(base: review.base, local: review.local, incoming: review.incoming, conflicts: result.conflicts)
                status = "Changes need review"; return false
            }
            if keepBoth {
                var copy = review.incoming
                copy.id = UUID(); copy.parents = []; copy.deviceID = state.deviceID
                copy.project.id = UUID(); copy.project.title += " — from " + review.incoming.deviceName
                guard try await apply(copy, expected: nil, generation: generation) else { return false }
            }
            let revision = result.revision
            try await Task.detached(priority: .utility) { try DriveSyncTransport.publish(revision, folder: folder, cache: cache) }.value
            guard currentEpoch(generation), try await apply(revision, expected: review.local.project, generation: generation) else { return false }
            try setHead(revision); reviews[review.projectID] = nil; status = reviews.isEmpty ? "Available in sync folder" : "Changes need review"
            return true
        } catch { if currentEpoch(generation) { status = "Sync needs attention: \(error.localizedDescription)" }; return false }
    }
}
