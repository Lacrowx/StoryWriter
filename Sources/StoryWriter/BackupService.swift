import AppKit
import Foundation

struct BackupConfiguration: Codable, Equatable {
    var folder: String
    var lastSuccess: Date?
    var lastModified: Date?
    var error: String?
}

enum PortableBackup {
    static func validate(folder: URL, library: URL) throws {
        let target = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let source = library.resolvingSymlinksInPath().standardizedFileURL.path
        guard target != source, !target.hasPrefix(source + "/"), !source.hasPrefix(target + "/"), folder.pathExtension != "storywriter" else {
            throw ProjectError.invalid("Choose a backup folder separate from the working library and project packages.")
        }
    }
    static func copy(package: URL, to folder: URL) throws -> URL {
        let manager = FileManager.default
        guard (try folder.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw ProjectError.invalid("Your backup folder is unavailable. Reconnect its drive or choose another folder.") }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent("\(package.deletingPathExtension().lastPathComponent)-\(stamp)-\(UUID().uuidString.prefix(8)).storywriter")
        let temporary = folder.appendingPathComponent(".storywriter-backup-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: package, to: temporary)
        // A complete copy is promoted only after its manifest can be decoded.
        _ = try ProjectStore.decode(Data(contentsOf: temporary.appendingPathComponent("project.json")))
        try manager.moveItem(at: temporary, to: destination)
        return destination
    }
}

extension ProjectStore {
    var backupDefaultsKey: String { "StoryWriter.backups.\(root.standardizedFileURL.path)" }
    func loadBackupSettings() {
        if let data = UserDefaults.standard.data(forKey: backupDefaultsKey), let values = try? JSONDecoder().decode([UUID: BackupConfiguration].self, from: data) { backupConfigurations = values }
    }
    func persistBackupSettings() {
        if let data = try? JSONEncoder().encode(backupConfigurations) { UserDefaults.standard.set(data, forKey: backupDefaultsKey) }
    }
    func chooseBackupFolder(_ id: UUID) {
        let panel = NSOpenPanel(); panel.title = "Choose an automatic backup folder"
        panel.message = "StoryWriter keeps dated portable copies here when your saved project changes. Choose a folder on another drive for protection against drive failure."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try configureBackup(id, folder: folder) } catch { errorMessage = error.localizedDescription }
    }
    func configureBackup(_ id: UUID, folder: URL) throws {
        try PortableBackup.validate(folder: folder, library: root)
        guard project(id) != nil else { throw ProjectError.invalid("This project is no longer available.") }
        backupTasks[id]?.cancel(); backupTasks[id] = nil
        backupGenerations[id] = nil
        backupRunning.remove(id)
        backupConfigurations[id] = BackupConfiguration(folder: folder.path)
        persistBackupSettings(); scheduleBackup(id, immediately: true)
    }
    func disableBackup(_ id: UUID) {
        backupTasks[id]?.cancel(); backupTasks[id] = nil
        backupGenerations[id] = nil
        backupRunning.remove(id)
        backupConfigurations[id] = nil; persistBackupSettings()
    }
    func backupStatus(_ id: UUID) -> String {
        guard let configuration = backupConfigurations[id] else { return "Automatic backup is off" }
        if let error = configuration.error { return "Backup failed: \(error)" }
        if let date = configuration.lastSuccess { return "Last backup: \(date.formatted(date: .abbreviated, time: .shortened))" }
        return "First backup pending"
    }
    func scheduleBackup(_ id: UUID, immediately: Bool = false) {
        guard let configuration = backupConfigurations[id], let project = project(id),
              immediately || configuration.lastModified != project.modifiedAt else { return }
        if backupTasks[id] != nil {
            guard immediately, !backupRunning.contains(id) else { return }
            backupTasks[id]?.cancel(); backupTasks[id] = nil
        }
        let delay = immediately ? 0 : max(0, ApplicationPreferences().backupInterval - Date().timeIntervalSince(configuration.lastSuccess ?? .distantPast))
        let generation = UUID()
        backupGenerations[id] = generation
        backupTasks[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, self.backupGenerations[id] == generation else { return }
            guard self.saveNow(), let current = self.project(id), self.backupConfigurations[id]?.folder == configuration.folder else { self.backupTasks[id] = nil; return }
            let package = self.packageURL(id), folder = URL(fileURLWithPath: configuration.folder, isDirectory: true)
            let modified = current.modifiedAt
            self.backupRunning.insert(id)
            do {
                _ = try await Task.detached(priority: .utility) { try PortableBackup.validate(folder: folder, library: package.deletingLastPathComponent()); return try PortableBackup.copy(package: package, to: folder) }.value
                guard !Task.isCancelled, self.backupGenerations[id] == generation else { return }
                guard self.backupConfigurations[id]?.folder == configuration.folder else { self.backupTasks[id] = nil; return }
                self.backupConfigurations[id]?.lastSuccess = Date(); self.backupConfigurations[id]?.lastModified = modified; self.backupConfigurations[id]?.error = nil
            } catch { guard !Task.isCancelled, self.backupGenerations[id] == generation else { return }; if self.backupConfigurations[id]?.folder == configuration.folder { self.backupConfigurations[id]?.error = error.localizedDescription } }
            self.persistBackupSettings(); self.backupTasks[id] = nil; self.backupRunning.remove(id)
            if self.backupConfigurations[id]?.error == nil { self.scheduleBackup(id) }
        }
    }
}
