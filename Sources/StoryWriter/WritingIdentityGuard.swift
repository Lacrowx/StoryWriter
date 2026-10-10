import Foundation
import NaturalLanguage

enum WritingIdentityGuard {
    private struct Word { var text: String; var range: NSRange }

    private static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            if let word { result.append(Word(text: word, range: NSRange(range, in: text))) }
        }
        return result
    }

    static func detectedNames(in text: String, language: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        tagger.setLanguage(language == "de" ? .german : .english, range: text.startIndex..<text.endIndex)
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { names.append(String(text[range])) }
            return true
        }
        return names
    }

    static func protect(_ issues: [GrammarIssue], names: [String], language: String) -> [GrammarIssue] {
        let nameWords = Set(names.flatMap { words($0).map { $0.text.lowercased() } })
        return issues.compactMap { protect($0, nameWords: nameWords, language: language) }
    }

    private static func protect(_ issue: GrammarIssue, nameWords: Set<String>, language: String) -> GrammarIssue? {
        let old = words(issue.original), new = words(issue.replacement)
        let oldKeys = old.map { $0.text.lowercased() }, newKeys = new.map { $0.text.lowercased() }
        let difference = newKeys.difference(from: oldKeys)
        let removed = Set(difference.removals.map { change -> Int in if case .remove(let index, _, _) = change { return index }; return -1 })
        let inserted = Set(difference.insertions.map { change -> Int in if case .insert(let index, _, _) = change { return index }; return -1 })
        func name(_ word: String) -> String? {
            if nameWords.contains(word) { return word }
            // German and English possessives may legitimately inflect a name.
            if word.hasSuffix("s"), nameWords.contains(String(word.dropLast())) { return String(word.dropLast()) }
            return nil
        }
        let feminine: Set<String> = language == "de" ? ["sie", "ihr"] : ["she", "her", "hers", "herself"]
        let masculine: Set<String> = language == "de" ? ["er", "ihm", "ihn"] : ["he", "him", "his", "himself"]
        let neutral: Set<String> = language == "de" ? ["es"] : ["they", "them", "their", "theirs", "themself", "themselves", "it", "its", "itself"]
        func changesGender(_ before: String, _ after: String) -> Bool {
            func group(_ word: String) -> Int? { feminine.contains(word) ? 0 : masculine.contains(word) ? 1 : neutral.contains(word) ? 2 : nil }
            guard let a = group(before), let b = group(after) else { return false }
            return a != b
        }
        var i = 0, j = 0
        var restorations: [(NSRange, String)] = []
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                let a = i, b = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                let oldNames = oldKeys[a..<i].compactMap(name), newNames = newKeys[b..<j].compactMap(name)
                let renamed = oldNames != newNames
                let genderChanged = oldKeys[a..<i].contains { before in newKeys[b..<j].contains { changesGender(before, $0) } }
                if language != "de", genderChanged,
                   oldKeys[a..<i].contains(where: neutral.contains) || newKeys[b..<j].contains(where: neutral.contains) {
                    return nil // Singular/plural agreement may also have been rewritten.
                }
                if renamed || genderChanged {
                    // Recover isolated identity substitutions while retaining
                    // independent grammar edits. Complex rewrites fail closed.
                    guard i - a == j - b, i - a > 0, i - a <= 4 else { return nil }
                    for offset in 0..<(i - a) {
                        let before = oldKeys[a + offset], after = newKeys[b + offset]
                        if name(before) != name(after) || changesGender(before, after) {
                            restorations.append((new[b + offset].range, old[a + offset].text))
                        }
                    }
                }
            } else {
                guard i < old.count, j < new.count, oldKeys[i] == newKeys[j] else { return nil }
                i += 1; j += 1
            }
        }
        guard !restorations.isEmpty else { return issue }
        let replacement = NSMutableString(string: issue.replacement)
        for (range, text) in restorations.sorted(by: { $0.0.location > $1.0.location }) { replacement.replaceCharacters(in: range, with: text) }
        guard WritingReviewDiff.hasMeaningfulChange(issue.original, replacement as String) else { return nil }
        var safe = issue
        safe.replacement = replacement as String
        // The model's explanation may justify the blocked identity change.
        safe.explanation = language == "de"
            ? "Die Namen und Personenbezüge des Originals wurden beibehalten. Prüfe die übrigen vorgeschlagenen Sprachänderungen im Vergleich mit dem Original."
            : "The original names and character references were preserved. Review the remaining suggested wording changes against the original."
        return safe
    }
}
