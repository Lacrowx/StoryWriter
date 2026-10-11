import Foundation

enum MLXModelQualityCheck {
    struct Sample: Sendable {
        let language: String
        let text: String
        let expectedFragments: [String]

        func catchesError(_ issues: [GrammarIssue]) -> Bool {
            let source = text as NSString
            let edits = issues.compactMap { issue -> (NSRange, String)? in
                let range = source.range(of: issue.original, options: .literal)
                guard !issue.original.isEmpty, range.location != NSNotFound else { return nil }
                return (range, issue.replacement)
            }.sorted { $0.0.location > $1.0.location }
            let corrected = NSMutableString(string: text)
            for (range, replacement) in edits { corrected.replaceCharacters(in: range, with: replacement) }
            return expectedFragments.contains { (corrected as String).contains($0) }
        }
    }
    static let english = Sample(language: "en", text: "She go to the harbour yesterday.", expectedFragments: ["She went", "She had gone"])
    static let german = Sample(language: "de", text: "Sie hat ein Brief bekommen.", expectedFragments: ["einen Brief"])
}
