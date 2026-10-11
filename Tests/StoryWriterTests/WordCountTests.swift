import XCTest
import AppKit
@testable import StoryWriter

final class WordCountTests: XCTestCase {
    /// The original Character-based definition the fast counter must match.
    private func reference(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0 == "\u{FFFC}" }.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    func testMatchesReferenceDefinition() {
        let samples = [
            "", " ", "\n\n", "One", "Two words", "  leading and trailing  ",
            "Hyphen-ated words — and dashes – count once", "It's Cole's turn.", "— … !?", "1984 was 42 pages",
            "Größe Übermut straße", "Café naïve résumé", "日本語の文章", "emoji 😀 alone 👍🏽 too",
            "keycap 1️⃣ start", "tabs\tand\r\nwindows\u{2028}lines\u{85}next", "picture:\u{FFFC}after", "a\u{FFFC}b",
            "non\u{00A0}breaking space", "combining e\u{301} accent", "“Quoted,” she said.", "x\u{20}\u{301}y"
        ]
        for sample in samples { XCTAssertEqual(sample.wordCount, reference(sample), "Mismatch for \(sample.debugDescription)") }
    }

    func testMatchesReferenceOnRandomText() {
        let pieces = ["Mara", " ", "\n", "—", "😀", "Größe", "42", ",", ".", "\u{FFFC}", "日本", "\t", "e\u{301}", "'", "\u{00A0}"]
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<300 {
            let text = (0..<Int.random(in: 0...40, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
            XCTAssertEqual(text.wordCount, reference(text), "Mismatch for \(text.debugDescription)")
        }
    }

    func testChapterCountFollowsTextChanges() {
        var chapter = Chapter()
        chapter.setEditingText(NSAttributedString(string: "One two three"))
        XCTAssertEqual(chapter.wordCount, 3)
        let earlier = chapter
        chapter.setEditingText(NSAttributedString(string: "One two three four"))
        XCTAssertEqual(chapter.wordCount, 4)
        XCTAssertEqual(earlier.wordCount, 3) // Copies with the same ID keep their own count.
        chapter.plainText = ""
        XCTAssertEqual(chapter.wordCount, 0)
    }
}

final class PassageEditTests: XCTestCase {
    /// The original Character-based definition the UTF-16 version must match.
    private func reference(old: String, new: String) -> (NSRange, Int) {
        let a = Array(old), b = Array(new)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let offset = a.prefix(prefix).reduce(0) { $0 + String($1).utf16.count }
        let range = NSRange(location: offset, length: a[prefix..<(a.count - suffix)].reduce(0) { $0 + String($1).utf16.count })
        return (range, b[prefix..<(b.count - suffix)].reduce(0) { $0 + String($1).utf16.count })
    }

    func testMatchesCharacterBasedEditsIncludingEmojiAndAccents() {
        // No stray combining marks: after a line break or a flag, Swift and NSString (which the
        // editor uses) disagree on where a character ends, and either answer is acceptable there.
        let pieces = ["a", "b", " ", "\n", "😀", "👍🏽", "🇩🇪", "e\u{301}", "日", "Mara", "ß"]
        var generator = SeededGenerator(seed: 0x5EED)
        func random(_ count: Int) -> String { (0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined() }
        for _ in 0..<10_000 {
            let old = random(Int.random(in: 0...12, using: &generator))
            let start = old.index(old.startIndex, offsetBy: Int.random(in: 0...old.count, using: &generator))
            let end = old.index(start, offsetBy: Int.random(in: 0...old.distance(from: start, to: old.endIndex), using: &generator))
            let new = String(old[..<start]) + random(Int.random(in: 0...3, using: &generator)) + String(old[end...])
            let edit = PassageEdit(old: old, new: new), expected = reference(old: old, new: new)
            XCTAssertEqual(edit.range, expected.0, "\(old.debugDescription) → \(new.debugDescription)")
            XCTAssertEqual(edit.replacementLength, expected.1, "\(old.debugDescription) → \(new.debugDescription)")
        }
    }

    func testEditingTextKeepsAnIndependentPlainTextCopy() {
        let storage = NSTextStorage(string: "Before")
        var chapter = Chapter()
        chapter.setEditingText(storage)
        storage.mutableString.append(" after")
        XCTAssertEqual(chapter.plainText, "Before")
    }
}

/// Reproducible randomized inputs (SplitMix64), so a failure can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
