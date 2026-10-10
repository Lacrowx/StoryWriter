import AppKit

enum SpellingReview {
    // Add only unambiguous repeated-letter typos; names and invented world terms are protected.
    static func duplicateLetterIssues(_ text: String, protectedTerms: [String], isCorrect: @escaping (String) -> Bool) -> [GrammarIssue] {
        let protected = Set(protectedTerms.flatMap { $0.split { !$0.isLetter }.map { $0.lowercased() } })
        var issues: [GrammarIssue] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word, !protected.contains(word.lowercased()) else { return }
            let letters = Array(word)
            guard letters.count > 1, zip(letters, letters.dropFirst()).contains(where: { $0 == $1 }), !isCorrect(word) else { return }
            var candidates = Set<String>()
            if letters.count > 1 {
                for index in 1..<letters.count where letters[index] == letters[index - 1] {
                    var changed = letters; changed.remove(at: index)
                    let candidate = String(changed)
                    if isCorrect(candidate) { candidates.insert(candidate) }
                }
            }
            guard candidates.count == 1, let candidate = candidates.first else { return }
            var original = word, replacement = candidate
            if text.components(separatedBy: word).count != 2 {
                let sentence = GrammarText.range(for: .sentence, in: text, selection: NSRange(range, in: text))
                original = (text as NSString).substring(with: sentence)
                let mutable = NSMutableString(string: original)
                let wordRange = NSRange(range, in: text)
                mutable.replaceCharacters(in: NSRange(location: wordRange.location - sentence.location, length: wordRange.length), with: candidate)
                replacement = mutable as String
            }
            guard text.components(separatedBy: original).count == 2, !issues.contains(where: { $0.original == original }) else { return }
            issues.append(GrammarIssue(original: original, replacement: replacement, explanation: "macOS spelling check: ‘\(word)’ contains an extra repeated letter; ‘\(candidate)’ is a recognized spelling.", kind: .spelling))
        }
        return issues
    }

    @MainActor static func candidates(_ text: String, language: String, protectedTerms: [String]) -> [GrammarIssue] {
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        return duplicateLetterIssues(text, protectedTerms: protectedTerms) { word in
            checker.checkSpelling(of: word, startingAt: 0, language: language == "de" ? "de_DE" : "en_US", wrap: false, inSpellDocumentWithTag: tag, wordCount: nil).location == NSNotFound
        }
    }

    static func supplement(_ modelIssues: [GrammarIssue], with spelling: [GrammarIssue], passage: String) -> [GrammarIssue] {
        var issues = modelIssues
        for fix in spelling {
            let range = (passage as NSString).range(of: fix.original)
            if let index = issues.firstIndex(where: { NSIntersectionRange((passage as NSString).range(of: $0.original), range).length > 0 }) {
                if issues[index].replacement.contains(fix.original) {
                    issues[index].replacement = issues[index].replacement.replacingOccurrences(of: fix.original, with: fix.replacement)
                    issues[index].explanation += " " + fix.explanation
                    if issues[index].category == .style { issues[index].kind = .grammar }
                }
            } else { issues.append(fix) }
        }
        return issues
    }
}
