import Foundation

/// One ordered writer per library. Encoding and automatic revision I/O run
/// outside the main actor; explicit save/quit can drain the same writer.
// Mutable state is confined to `queue`; callers only enqueue ordered work.
final class ProjectPersistence: @unchecked Sendable {
    let queue = DispatchQueue(label: "StoryWriter.project-persistence", qos: .utility)
    // Preserve the in-memory edit timestamp's precision; the legacy JSON date
    // format rounds to seconds. Access only on the ordered writer.
    private var savedModificationDates: [UUID: Date] = [:]

    struct Request {
        let project: StoryProject
        let directory: URL
        let generation: UUID
        let revisionDue: Bool
    }
    struct Outcome {
        let id: UUID
        let generation: UUID
        var revisionDate: Date?
        var error: String?
    }

    func save(_ requests: [Request]) -> Task<[Outcome], Never> {
        // Enqueue synchronously, before the main actor can accept a manual
        // save. Starting the queue operation inside a Task would allow an old
        // snapshot to be enqueued after a newer explicit save.
        let stream = AsyncStream<[Outcome]> { continuation in
            queue.async {
                continuation.yield(self.write(requests))
                continuation.finish()
            }
        }
        return Task {
            for await result in stream { return result }
            return []
        }
    }
    func saveNow(_ requests: [Request]) -> [Outcome] {
        queue.sync { write(requests) }
    }

    func backup(package: URL, folder: URL) async throws -> Date {
        // Serialize package copies with saves so the manifest and history
        // belong to the same durable snapshot, even if typing continues.
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try PortableBackup.validate(folder: folder, library: package.deletingLastPathComponent())
                    let project = try ProjectStore.readPackage(package)
                    _ = try PortableBackup.copy(package: package, to: folder)
                    continuation.resume(returning: self.savedModificationDates[project.id] ?? project.modifiedAt)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func write(_ requests: [Request]) -> [Outcome] {
        requests.map { request in
            var result = Outcome(id: request.project.id, generation: request.generation)
            do {
                // Encode before touching history so a failed archive leaves it intact.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(request.project)
                try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
                if request.revisionDue { result.revisionDate = try Self.checkpoint(request.directory) }
                try data.write(to: request.directory.appendingPathComponent("project.json"), options: .atomic)
                savedModificationDates[request.project.id] = request.project.modifiedAt
            } catch { result.error = error.localizedDescription }
            return result
        }
    }

    @discardableResult static func checkpoint(_ directory: URL, name: String? = nil) throws -> Date? {
        let manager = FileManager.default
        let manifest = directory.appendingPathComponent("project.json")
        guard manager.fileExists(atPath: manifest.path) else { return nil }
        let history = directory.appendingPathComponent("History", isDirectory: true)
        try manager.createDirectory(at: history, withIntermediateDirectories: true)
        let date = Date()
        let revision = history.appendingPathComponent("\(date.timeIntervalSince1970)-\(UUID().uuidString).json")
        try manager.copyItem(at: manifest, to: revision)
        if let name { try name.write(to: revision.appendingPathExtension("label"), atomically: true, encoding: .utf8) }
        let urls = try manager.contentsOfDirectory(at: history, includingPropertiesForKeys: [.creationDateKey])
        let automatic = urls.filter { $0.pathExtension == "json" && !manager.fileExists(atPath: $0.appendingPathExtension("label").path) }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for old in automatic.dropFirst(30) { try manager.removeItem(at: old) }
        return date
    }
}
