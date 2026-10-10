import Foundation

struct RevisedWritingResult: Codable {
    var revisedText: String
    var explanation: String
    var kind: SuggestionKind?
}

enum WritingReviewDiff {
    private struct Edit { var old: NSRange; var new: NSRange }

    static func reportsNoChanges(_ explanation: String) -> Bool {
        let text = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        // An explicit no-edit assessment cannot justify changing the passage.
        // Keep this narrow: "no grammatical errors, but improve style" is not
        // a no-change report and still allows a meaningful style suggestion.
        let pattern = #"^(?:keine\s+(?:korrektur(?:en)?|änderung(?:en)?|verbesserung(?:en)?)\s+(?:(?:ist|sind)\s+)?(?:erforderlich|notwendig|nötig)|no\s+(?:corrections?|changes?|edits?|improvements?)\s+(?:(?:are|is)\s+)?(?:required|needed|necessary))\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func hasMeaningfulChange(_ original: String, _ replacement: String) -> Bool {
        // Models may trim a chunk or reflow it even when they report no edits.
        // Keep word boundaries significant ("alot" -> "a lot"), but ignore
        // changes to whitespace runs and leading/trailing whitespace.
        func wording(_ text: String) -> String {
            text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return wording(original) != wording(replacement)
    }

    static func issues(original: String, revision: RevisedWritingResult) -> [GrammarIssue] {
        guard !reportsNoChanges(revision.explanation), hasMeaningfulChange(original, revision.revisedText) else { return [] }
        let old = Array(original), new = Array(revision.revisedText)
        let difference = new.difference(from: old)
        let removed = Set(difference.removals.map { change -> Int in if case .remove(let index, _, _) = change { return index }; return -1 })
        let inserted = Set(difference.insertions.map { change -> Int in if case .insert(let index, _, _) = change { return index }; return -1 })
        func offsets(_ characters: [Swift.Character]) -> [Int] { var result = [0]; for character in characters { result.append(result.last! + String(character).utf16.count) }; return result }
        let oldOffsets = offsets(old), newOffsets = offsets(new)
        var edits: [Edit] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                let startI = i, startJ = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                edits.append(Edit(old: NSRange(location: oldOffsets[startI], length: oldOffsets[i] - oldOffsets[startI]), new: NSRange(location: newOffsets[startJ], length: newOffsets[j] - newOffsets[startJ])))
            } else {
                guard i < old.count, j < new.count, old[i] == new[j] else { return [whole(original, revision)] }
                i += 1; j += 1
            }
        }
        var groups: [(NSRange, [Edit])] = []
        for edit in edits {
            let start = GrammarText.range(for: .sentence, in: original, selection: NSRange(location: min(edit.old.location, max(0, original.utf16.count - 1)), length: 0))
            let end = GrammarText.range(for: .sentence, in: original, selection: NSRange(location: min(max(edit.old.location, NSMaxRange(edit.old) - 1), max(0, original.utf16.count - 1)), length: 0))
            let sentence = NSUnionRange(start, end)
            if let last = groups.last, NSIntersectionRange(last.0, sentence).length > 0 {
                groups[groups.count - 1] = (NSUnionRange(last.0, sentence), last.1 + [edit])
            } else { groups.append((sentence, [edit])) }
        }
        var issues: [GrammarIssue] = []
        let revised = revision.revisedText as NSString
        for (range, changes) in groups {
            guard let first = changes.first, let last = changes.last else { continue }
            let newStart = first.new.location - (first.old.location - range.location)
            let newEnd = NSMaxRange(last.new) + (NSMaxRange(range) - NSMaxRange(last.old))
            guard newStart >= 0, newEnd >= newStart, newEnd <= revised.length else { return [whole(original, revision)] }
            let quote = (original as NSString).substring(with: range)
            let replacement = revised.substring(with: NSRange(location: newStart, length: newEnd - newStart))
            guard original.components(separatedBy: quote).count == 2 else { return [whole(original, revision)] }
            if hasMeaningfulChange(quote, replacement) { issues.append(GrammarIssue(original: quote, replacement: replacement, explanation: revision.explanation, kind: revision.kind)) }
        }
        return issues
    }

    private static func whole(_ original: String, _ revision: RevisedWritingResult) -> GrammarIssue {
        GrammarIssue(original: original, replacement: revision.revisedText, explanation: revision.explanation, kind: revision.kind)
    }
}
