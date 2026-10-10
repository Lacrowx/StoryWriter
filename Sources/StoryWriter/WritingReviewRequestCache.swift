import Foundation

// Session-only, bounded cache for identical Osaurus requests, including clean
// reviews. Context and connection settings participate so edits cannot reuse
// a review made with another brief, cast, language, model or style setting.
struct WritingReviewRequestCache {
    struct Key: Equatable {
        var text: String
        var language: String
        var model: LocalModel
        var baseURL: String
        var includeStyle: Bool
        var context: WritingReviewContext
    }
    private var entries: [(Key, [GrammarIssue])] = []
    private let capacity: Int

    init(capacity: Int = 32) { self.capacity = max(1, capacity) }

    mutating func result(for key: Key) -> [GrammarIssue]? {
        guard let index = entries.firstIndex(where: { $0.0 == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.1
    }

    mutating func store(_ issues: [GrammarIssue], for key: Key) {
        entries.removeAll { $0.0 == key }
        entries.append((key, issues))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
