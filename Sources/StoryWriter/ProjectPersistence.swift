import Foundation

/// One ordered writer per library. Encoding and automatic revision I/O run
/// outside the main actor; explicit save/quit can drain the same writer.
final class ProjectPersistence {
    let queue = DispatchQueue(label: "StoryWriter.project-persistence", qos: .utility)

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
                continuation.yield(Self.write(requests))
                continuation.finish()
            }
        }
        return Task {
            for await result in stream { return result }
            return []
        }
    }
    func saveNow(_ requests: [Request]) -> [Outcome] {
        queue.sync { Self.write(requests) }
    }
    private static func write(_ requests: [Request]) -> [Outcome] {
        requests.map { request in
            var result = Outcome(id: request.project.id, generation: request.generation)
            do {
                // Encode before touching history so a failed archive leaves it intact.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(request.project)
                try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
                if request.revisionDue { result.revisionDate = try checkpoint(request.directory) }
                try data.write(to: request.directory.appendingPathComponent("project.json"), options: .atomic)
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
