import Foundation

enum WritingReviewResponseError: LocalizedError {
    case format, quotes, truncated
    var errorDescription: String? {
        switch self {
        case .format: return "The model did not return usable corrections. Try another local model. Your writing has not been changed."
        case .quotes: return "The model did not quote the passage accurately. Try a smaller selection or another local model. Your writing has not been changed."
        case .truncated: return "The model's response was cut short. Try a smaller selection. Your writing has not been changed."
        }
    }
}

enum WritingReviewResponse {
    static func issues(_ content: String, passage: String, includeStyle: Bool) throws -> [GrammarIssue] {
        // Ignore reasoning, including any example JSON inside it. An unfinished
        // reasoning block is never treated as the final answer.
        var answer = content
        while let start = answer.range(of: "<think>", options: .caseInsensitive) {
            guard let end = answer.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<answer.endIndex) else {
                answer = String(answer[..<start.lowerBound]); break
            }
            answer.removeSubrange(start.lowerBound..<end.upperBound)
        }
        // Prefer the final structured answer over earlier examples. Do not mine
        // nested objects from an unknown or incomplete response envelope.
        for candidate in jsonValues(answer).reversed() {
            guard let data = removingTrailingCommas(candidate).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let rows = correctionRows(value) else { continue }
            if rows.isEmpty { return [] }
            let decoded = rows.compactMap { row -> GrammarIssue? in
                guard let fields = row as? [String: Any],
                      let original = fields["original"] as? String,
                      let replacement = fields["replacement"] as? String else { return nil }
                let kind = (fields["kind"] as? String).flatMap { SuggestionKind(rawValue: $0.lowercased()) }
                return GrammarIssue(original: original, replacement: replacement, explanation: fields["explanation"] as? String ?? "", kind: kind)
            }
            guard !decoded.isEmpty else { throw WritingReviewResponseError.format }
            let changed = decoded.filter { !WritingReviewDiff.reportsNoChanges($0.explanation) && WritingReviewDiff.hasMeaningfulChange($0.original, $0.replacement) }
            var seen = Set<String>(), ranges: [NSRange] = []
            let source = passage as NSString
            // Clear errors take precedence over optional style rewrites. Shorter
            // edits win ties so accepting a correction changes less prose.
            let ordered = changed.sorted {
                if ($0.category == .style) != ($1.category == .style) { return $0.category != .style }
                return $0.original.utf16.count < $1.original.utf16.count
            }
            var usable: [GrammarIssue] = []
            var hasAccurateQuote = false
            for issue in ordered {
                guard !issue.original.isEmpty else { continue }
                let range = source.range(of: issue.original, options: .literal)
                guard range.location != NSNotFound else { continue }
                let remainder = NSRange(location: range.location + 1, length: source.length - range.location - 1)
                guard source.range(of: issue.original, options: .literal, range: remainder).location == NSNotFound else { continue }
                hasAccurateQuote = true
                guard includeStyle || issue.category != .style,
                      seen.insert(issue.id).inserted,
                      !ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                ranges.append(range); usable.append(issue)
            }
            if !changed.isEmpty && !hasAccurateQuote { throw WritingReviewResponseError.quotes }
            return usable.sorted { source.range(of: $0.original, options: .literal).location < source.range(of: $1.original, options: .literal).location }
        }
        throw WritingReviewResponseError.format
    }

    private static func correctionRows(_ value: Any) -> [Any]? {
        if let rows = value as? [Any] { return rows }
        guard let fields = value as? [String: Any] else { return nil }
        if let rows = fields["issues"] as? [Any] { return rows }
        if let rows = fields["corrections"] as? [Any] { return rows }
        if fields["original"] is String && fields["replacement"] is String { return [fields] }
        return nil
    }

    private static func jsonValues(_ content: String) -> [String] {
        var values: [String] = [], stack: [Swift.Character] = []
        var start: String.Index?, quoted = false, escaped = false
        for index in content.indices {
            let character = content[index]
            if stack.isEmpty {
                guard character == "{" || character == "[" else { continue }
                start = index; stack.append(character); quoted = false; escaped = false
            } else if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" || character == "[" { stack.append(character) }
            else if character == "}" || character == "]" {
                guard stack.last == (character == "}" ? "{" : "[") else { return values }
                stack.removeLast()
                if stack.isEmpty, let start { values.append(String(content[start...index])) }
            }
        }
        return values
    }

    private static func removingTrailingCommas(_ value: String) -> String {
        var result = "", quoted = false, escaped = false
        for index in value.indices {
            let character = value[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == ",", let next = value[value.index(after: index)...].first(where: { !$0.isWhitespace }), next == "}" || next == "]" { continue }
            result.append(character)
        }
        return result
    }
}
