import XCTest
import AppKit
@testable import StoryWriter

final class InlineGrammarTests: XCTestCase {
    @MainActor func testCharacterRecordChangesInvalidateCachedSuggestions() {
        let view = ManuscriptTextView(frame: .zero); view.string = "Elisa wartet."
        var context = WritingReviewContext(characters: [WritingCharacterRecord(name: "Elisa", pronouns: "sie/ihr", summary: "")])
        let key = UUID().uuidString
        let session = InlineGrammarSession(view: view, documentKey: key, context: context)
        session.corrections = GrammarText.locate([GrammarIssue(original: view.string, replacement: "Elisa wartet am Hafen.", explanation: "Style")], chunk: view.string, offset: 0)
        session.reviewed = true; session.drawMarks()
        let restored = InlineGrammarSession(view: view, documentKey: key, context: context)
        XCTAssertEqual(restored.corrections.count, 1)
        context.characters[0].pronouns = "they/them"
        restored.context = context
        XCTAssertTrue(restored.corrections.isEmpty)
        XCTAssertFalse(restored.reviewed)
        let different = InlineGrammarSession(view: view, documentKey: key, context: WritingReviewContext())
        XCTAssertTrue(different.corrections.isEmpty)
    }

    func testCharacterIdentityGuardKeepsGrammarWithoutRenamingOrChangingGender() throws {
        let original = "Für Elisa bedeutete das nun, das Sie allein zu hause war."
        let issue = GrammarIssue(original: original, replacement: "Für Elias bedeutete das nun, dass er allein zu Hause war.", explanation: "Elias is male.", kind: .grammar)
        let fixes = WritingIdentityGuard.protect([issue], names: ["Elisa", "Elias"], language: "de")
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes.first?.replacement, "Für Elisa bedeutete das nun, dass Sie allein zu Hause war.")
        XCTAssertFalse(fixes.first?.explanation.contains("male") == true)
        let onlyIdentity = GrammarIssue(original: "Elisa wartet. Sie ist allein.", replacement: "Elias wartet. Er ist allein.", explanation: "Grammar", kind: .grammar)
        XCTAssertTrue(WritingIdentityGuard.protect([onlyIdentity], names: ["Elisa"], language: "de").isEmpty)
        let gender = GrammarIssue(original: "Elisa said she was tired.", replacement: "Elias said he was tired.", explanation: "Style", kind: .style)
        XCTAssertTrue(WritingIdentityGuard.protect([gender], names: ["Elisa"], language: "en").isEmpty)
        let neutral = GrammarIssue(original: "Alex said they were tired.", replacement: "Alex said he was tired.", explanation: "Agreement", kind: .grammar)
        let neutralFixes = WritingIdentityGuard.protect([neutral], names: ["Alex"], language: "en")
        XCTAssertTrue(neutralFixes.isEmpty, "Do not leave ‘they was’ by partially restoring a gender-and-agreement rewrite")
        let safe = GrammarIssue(original: "Für Elisa war das ungewöhnlich. Sie wartet auf ein Antwort.", replacement: "Für Elisa war das ungewöhnlich. Sie wartet auf eine Antwort.", explanation: "Article", kind: .grammar)
        XCTAssertEqual(WritingIdentityGuard.protect([safe], names: ["Elisa"], language: "de"), [safe])
        let possessive = GrammarIssue(original: "Elisa Tasche ist rot.", replacement: "Elisas Tasche ist rot.", explanation: "Possessive", kind: .grammar)
        XCTAssertEqual(WritingIdentityGuard.protect([possessive], names: ["Elisa"], language: "de"), [possessive])
        let complex = GrammarIssue(original: "Elisa wartet hier.", replacement: "Elias und Ben warten hier.", explanation: "Style", kind: .style)
        XCTAssertTrue(WritingIdentityGuard.protect([complex], names: ["Elisa", "Ben"], language: "de").isEmpty)
    }

    @MainActor func testAcceptingOneSuggestionAdvancesThroughRebasedRangesAndWraps() async throws {
        _ = NSApplication.shared
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.string = "She go home. He walk slowly. They was waiting."
        let session = InlineGrammarSession(view: view)
        view.grammarSession = session
        session.corrections = GrammarText.locate([
            GrammarIssue(original: "She go", replacement: "She goes", explanation: "Agreement"),
            GrammarIssue(original: "He walk", replacement: "He walks", explanation: "Agreement"),
            GrammarIssue(original: "They was", replacement: "They were", explanation: "Agreement")
        ], chunk: view.string, offset: 0)
        let ids = session.corrections.map(\.id)
        session.accept(ids[1])
        for _ in 0..<100 {
            if view.selectedRange() == session.corrections.first(where: { $0.id == ids[2] })?.range { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(view.string, "She go home. He walks slowly. They was waiting.")
        XCTAssertEqual(session.corrections.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "They was", "Open the following suggestion at its shifted range")
        session.accept(ids[2])
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "She go", "Wrap to the earlier pending suggestion")
        session.accept(ids[0])
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(view.string, "She goes home. He walks slowly. They were waiting.")
        XCTAssertTrue(session.corrections.isEmpty)
        XCTAssertEqual(view.selectedRange().length, 0, "Finish without selecting or reopening an accepted suggestion")
    }

    func testWhitespaceOnlyModelChangesDoNotBecomeSuggestions() throws {
        let sentence = "Für Elisa war das etwas ungewöhnlich."
        for original in [sentence + " ", "\n" + sentence + "\n\n", sentence.replacingOccurrences(of: " ", with: "\u{00a0}"), sentence.replacingOccurrences(of: " ", with: "  ")] {
            XCTAssertTrue(WritingReviewDiff.issues(original: original, revision: RevisedWritingResult(revisedText: sentence, explanation: "Keine Korrekturen erforderlich.", kind: .style)).isEmpty)
        }
        let original = "She go home. Für Elisa war das etwas ungewöhnlich. "
        let revision = "She goes home. Für Elisa war das etwas ungewöhnlich."
        let issues = WritingReviewDiff.issues(original: original, revision: RevisedWritingResult(revisedText: revision, explanation: "Subject–verb agreement", kind: .grammar))
        XCTAssertEqual(issues.count, 1, "A real correction must not create another suggestion just for a trimmed space")
        XCTAssertEqual(issues.first?.replacement, "She goes home. ")
        let applied = issues.reduce(original) { $0.replacingOccurrences(of: $1.original, with: $1.replacement) }
        XCTAssertEqual(applied, "She goes home. Für Elisa war das etwas ungewöhnlich. ", "Ignoring whitespace-only edits must preserve the writer's original spacing")
        for (before, after) in [("It was alot.", "It was a lot."), (sentence, "Für Elisa war das ungewöhnlich."), ("Sie wartet", "Sie wartet.")] {
            XCTAssertFalse(WritingReviewDiff.issues(original: before, revision: RevisedWritingResult(revisedText: after, explanation: "Improve wording", kind: .grammar)).isEmpty)
        }
        let wrapped = "{\"issues\":[{\"original\":\"Für Elisa war das etwas ungewöhnlich. \",\"replacement\":\"Für Elisa war das etwas ungewöhnlich.\",\"explanation\":\"Keine Korrekturen erforderlich.\",\"kind\":\"style\"}]}"
        XCTAssertTrue(try OsaurusClient.parseIssues(wrapped, passage: sentence + " ").isEmpty)
        for explanation in ["Keine Korrekturen erforderlich. Der Satz ist grammatikalisch korrekt und enthält keine Fehler.", "Keine Korrektur erforderlich, Satz ist bereits korrekt.", "No corrections are needed. The sentence is already correct."] {
            XCTAssertTrue(WritingReviewDiff.issues(original: sentence, revision: RevisedWritingResult(revisedText: "Für Elias war das etwas ungewöhnlich.", explanation: explanation, kind: .style)).isEmpty, "A no-change assessment must not become a proposed name change")
        }
        XCTAssertFalse(WritingReviewDiff.reportsNoChanges("No grammatical errors, but remove redundant wording."))
        XCTAssertFalse(WritingReviewDiff.reportsNoChanges("Keine Grammatikfehler; Wiederholung für einen klareren Stil entfernen."))
    }

    func testRevisedPassagesBecomeExactNonOverlappingSentenceSuggestions() throws {
        let cases = [
            ("She go home. He walk slowly.\n\nThey was waiting.", "She goes home. He walks slowly.\n\nThey were waiting."),
            ("Grüße 🌊. Sie wartet", "Liebe Grüße 🌊. Sie wartet."),
            ("Go home. Go home.", "Go home. Head home."),
            ("She waited. She left.", "After waiting, she left."),
            ("Sie wartet.", "Sie wartet.")
        ]
        for (original, revised) in cases {
            let issues = WritingReviewDiff.issues(original: original, revision: RevisedWritingResult(revisedText: revised, explanation: "Clarity", kind: .style))
            var ranges: [NSRange] = []
            for issue in issues {
                XCTAssertEqual(original.components(separatedBy: issue.original).count, 2)
                let range = (original as NSString).range(of: issue.original)
                XCTAssertTrue(ranges.allSatisfy { NSIntersectionRange($0, range).length == 0 })
                ranges.append(range)
            }
            let applied = issues.sorted { (original as NSString).range(of: $0.original).location > (original as NSString).range(of: $1.original).location }.reduce(original) { $0.replacingOccurrences(of: $1.original, with: $1.replacement) }
            XCTAssertEqual(applied, revised)
        }
        let changed = WritingReviewDiff.issues(original: cases[0].0, revision: RevisedWritingResult(revisedText: cases[0].1, explanation: "Agreement", kind: .grammar))
        XCTAssertEqual(changed.count, 3)
    }
    func testRepeatedLetterSpellingSupportProtectsNamesAndCombinesWithStyle() throws {
        let known: Set<String> = ["Kind", "Tisch", "Klasse", "Mara"]
        let passage = "Mara sitzt auf dem Tisch. Das Kindd wartet. Klasse."
        let issues = SpellingReview.duplicateLetterIssues(passage, protectedTerms: ["Mara"], isCorrect: known.contains)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.original, "Kindd")
        XCTAssertEqual(issues.first?.replacement, "Kind")
        XCTAssertEqual(issues.first?.category, .spelling)
        XCTAssertTrue(SpellingReview.duplicateLetterIssues("Kindd wartet.", protectedTerms: ["Kindd"], isCorrect: known.contains).isEmpty)
        let style = GrammarIssue(original: "Das Kindd wartet.", replacement: "Das Kindd wartet am Tisch.", explanation: "Style", kind: .style)
        let combined = SpellingReview.supplement([style], with: issues, passage: passage)
        XCTAssertEqual(combined.count, 1)
        XCTAssertFalse(combined[0].replacement.contains("Kindd"))
        XCTAssertEqual(combined[0].category, .grammar)
        XCTAssertEqual(SpellingReview.supplement([], with: issues, passage: passage), issues)
    }
    @MainActor func testEditedTextCannotKeepAnEarlierCleanReviewStatus() async throws {
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        view.string = "She walks home."
        let session = InlineGrammarSession(view: view)
        session.reviewed = true; session.message = "Earlier failure"
        view.string = "She walk home."
        session.textChanged(automatic: false)
        XCTAssertFalse(session.reviewed)
        XCTAssertNil(session.message)
        session.message = "Server unavailable"; session.reviewed = true
        session.cancel()
        XCTAssertFalse(session.checking)
        XCTAssertFalse(session.pending)
    }
    func testSentenceParagraphAndSelectionScopes() throws {
        let text = "She go home. He walk slowly.\n\nThey was waiting."
        let position = (text as NSString).range(of: "walk").location
        let sentence = GrammarText.range(for: .sentence, in: text, selection: NSRange(location: position, length: 0))
        XCTAssertEqual((text as NSString).substring(with: sentence).trimmingCharacters(in: .whitespacesAndNewlines), "He walk slowly.")
        let paragraph = GrammarText.range(for: .paragraph, in: text, selection: NSRange(location: position, length: 0))
        XCTAssertTrue((text as NSString).substring(with: paragraph).contains("She go home. He walk slowly."))
        XCTAssertFalse((text as NSString).substring(with: paragraph).contains("They was"))
        let selected = NSRange(location: 0, length: 12)
        XCTAssertEqual(GrammarText.range(for: .selection, in: text, selection: selected), selected)
        XCTAssertEqual(GrammarText.range(for: .document, in: text, selection: selected).length, text.utf16.count)
    }

    func testLongDocumentsAreChunkedWithoutLosingUnicode() throws {
        let text = String(repeating: "Grüße 👩🏽‍💻 from the harbour.\n", count: 1000)
        let chunks = GrammarText.chunks(text, range: NSRange(location: 0, length: text.utf16.count), limit: 128)
        XCTAssertEqual(chunks.map(\.0).joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.0.utf16.count <= 128 })
        var position = 0
        for (chunk, offset) in chunks { XCTAssertEqual(offset, position); position += chunk.utf16.count }
        let noSpaces = String(repeating: "👩🏽‍💻", count: 100)
        XCTAssertEqual(GrammarText.chunks(noSpaces, range: NSRange(location: 0, length: noSpaces.utf16.count), limit: 23).map(\.0).joined(), noSpaces)
    }

    func testEditsRebaseUnaffectedCorrectionsAndDiscardStaleOnes() throws {
        let old = "She go home.\nThey was waiting."
        let issues = [GrammarIssue(original: "She go", replacement: "She goes", explanation: "Agreement"), GrammarIssue(original: "They was", replacement: "They were", explanation: "Agreement")]
        let corrections = GrammarText.locate(issues, chunk: old, offset: 0)
        let prefixed = "🌊 " + old
        let shifted = GrammarText.rebase(corrections, old: old, new: prefixed)
        XCTAssertEqual(shifted.count, 2)
        XCTAssertEqual(shifted[0].range.location, 3)
        let corrected = old.replacingOccurrences(of: "She go", with: "She goes")
        let remaining = GrammarText.rebase(corrections, old: old, new: corrected)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual((corrected as NSString).substring(with: remaining[0].range), "They was")
    }

    @MainActor func testCorrectionDiffKeepsUnchangedWordFormatting() async throws {
        let text = NSMutableAttributedString(string: "She go home. 🌊", attributes: WritingStyle.attributes)
        let home = (text.string as NSString).range(of: "home")
        text.addAttributes([.font: NSFont.boldSystemFont(ofSize: 18), .link: URL(string: "https://example.com")!], range: home)
        let corrected = GrammarText.replacement(text, with: "She goes home. 🌊")
        XCTAssertEqual(corrected.string, "She goes home. 🌊")
        let index = (corrected.string as NSString).range(of: "home").location
        let font = try XCTUnwrap(corrected.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertNotNil(corrected.attribute(.link, at: index, effectiveRange: nil))
        XCTAssertEqual(GrammarText.replacement(NSAttributedString(string: "hello"), with: "").string, "")
        XCTAssertEqual(GrammarText.replacement(NSAttributedString(string: ""), with: "🌊 Hi").string, "🌊 Hi")
    }

    @MainActor func testProofreadingKeepsColeSkorpTagOnTheNameOnly() throws {
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        let examples = [
            ("Cole Skorp geht durch ein große Eingangstor.", "Cole Skorp geht durch ein großes Eingangstor."),
            ("Cole Skorp war das eine Wunder.", "Für Cole Skorp war das ein Wunder."),
            ("Cole Skorp stand vor dem große Eingangstor.", "Vor dem großen Eingangstor stand Cole Skorp."),
            ("🌊 Cole Skorp geht nun endlich auf die Akademie Atorus.", "🌊 Cole Skorp kann nun endlich die Akademie Atorus besuchen.")
        ]
        for (original, revision) in examples {
            let text = NSMutableAttributedString(string: original, attributes: WritingStyle.attributes)
            text.addAttribute(.link, value: reference.url, range: (original as NSString).range(of: "Cole Skorp"))
            let corrected = GrammarText.replacement(text, with: revision)
            XCTAssertEqual(corrected.string, revision)
            var labels: [String] = []
            corrected.enumerateAttribute(.link, in: NSRange(location: 0, length: corrected.length)) { value, range, _ in
                if ProjectTagReference.from(value) == reference { labels.append((corrected.string as NSString).substring(with: range)) }
            }
            XCTAssertEqual(labels, ["Cole Skorp"], "Tag expanded during: \(original) → \(revision)")
        }
    }

    @MainActor func testProofreadingDoesNotRetagRepeatedNamesOrKeepDeletedTags() {
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        let original = "Cole Skorp geht. Cole Skorp wartet."
        let text = NSMutableAttributedString(string: original, attributes: WritingStyle.attributes)
        text.addAttribute(.link, value: reference.url, range: (original as NSString).range(of: "Cole Skorp"))
        let corrected = GrammarText.replacement(text, with: "Für Cole Skorp geht es weiter. Cole Skorp wartet.")
        let first = (corrected.string as NSString).range(of: "Cole Skorp")
        let second = (corrected.string as NSString).range(of: "Cole Skorp", options: .backwards)
        var range = NSRange()
        XCTAssertEqual(ProjectTagReference.from(corrected.attribute(.link, at: first.location, longestEffectiveRange: &range, in: NSRange(location: 0, length: corrected.length))), reference)
        XCTAssertEqual(range, first)
        XCTAssertNil(corrected.attribute(.link, at: second.location, effectiveRange: nil))
        let deleted = GrammarText.replacement(text, with: "Er geht weiter.")
        deleted.enumerateAttribute(.link, in: NSRange(location: 0, length: deleted.length)) { value, _, _ in
            XCTAssertNil(ProjectTagReference.from(value))
        }
        let world = ProjectTagReference(kind: .world, objectID: UUID())
        let both = NSMutableAttributedString(string: "🌊 Cole Skorp geht zur Akademie Atorus.", attributes: WritingStyle.attributes)
        for (label, tag) in [("Cole Skorp", reference), ("Akademie Atorus", world)] {
            both.addAttribute(.link, value: tag.url, range: (both.string as NSString).range(of: label))
        }
        let revised = GrammarText.replacement(both, with: "🌊 Zur Akademie Atorus geht Cole Skorp.")
        for (label, tag) in [("Cole Skorp", reference), ("Akademie Atorus", world)] {
            let expected = (revised.string as NSString).range(of: label)
            XCTAssertEqual(ProjectTagReference.from(revised.attribute(.link, at: expected.location, longestEffectiveRange: &range, in: NSRange(location: 0, length: revised.length))), tag)
            XCTAssertEqual(range, expected)
        }
    }

    @MainActor func testAcceptingSentenceCorrectionPreservesTagAndUndo() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.makeFirstResponder(view)
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        let original = "Cole Skorp war das eine Wunder."
        let text = NSMutableAttributedString(string: original, attributes: WritingStyle.attributes)
        text.addAttribute(.link, value: reference.url, range: (original as NSString).range(of: "Cole Skorp"))
        view.textStorage?.setAttributedString(text)
        let session = InlineGrammarSession(view: view); view.grammarSession = session
        let revision = "Für Cole Skorp war das ein Wunder."
        session.corrections = GrammarText.locate([GrammarIssue(original: original, replacement: revision, kind: .grammar)], chunk: original, offset: 0)
        session.accept(.document)
        XCTAssertEqual(view.string, revision)
        var range = NSRange()
        let name = (revision as NSString).range(of: "Cole Skorp")
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: name.location, longestEffectiveRange: &range, in: NSRange(location: 0, length: view.string.utf16.count))), reference)
        XCTAssertEqual(range, name)
        XCTAssertNil(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(view.textStorage?.attribute(.link, at: NSMaxRange(name), effectiveRange: nil))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, original)
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil)), reference)
        view.undoManager?.redo()
        XCTAssertEqual(view.string, revision)
        XCTAssertNil(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        session.cancel()
    }

    @MainActor func testParagraphAcceptanceIsOneUndoAndMarksNeverEnterSavedText() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        let original = "She go home. He walk slowly.\n\nThey was waiting."
        view.textStorage?.setAttributedString(NSAttributedString(string: original, attributes: WritingStyle.attributes))
        window.contentView?.addSubview(view); window.makeFirstResponder(view)
        let session = InlineGrammarSession(view: view)
        view.grammarSession = session
        session.corrections = GrammarText.locate([GrammarIssue(original: "She go", replacement: "She goes", explanation: "Agreement"), GrammarIssue(original: "He walk", replacement: "He walks", explanation: "Agreement"), GrammarIssue(original: "They was", replacement: "They were", explanation: "Agreement")], chunk: original, offset: 0)
        session.drawMarks()
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: session.corrections[0].range, actualCharacterRange: nil)
        let mark = manager.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertEqual(session.correction(at: NSPoint(x: mark.midX + view.textContainerOrigin.x, y: mark.midY + view.textContainerOrigin.y))?.id, session.corrections[0].id)
        XCTAssertNil(session.correction(at: NSPoint(x: -20, y: -20)))
        XCTAssertNil(view.textStorage?.attribute(.underlineColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(view.layoutManager?.temporaryAttribute(.underlineColor, atCharacterIndex: 0, effectiveRange: nil))
        session.accept(.paragraph, anchor: NSRange(location: 0, length: 0))
        XCTAssertEqual(view.string, "She goes home. He walks slowly.\n\nThey was waiting.")
        XCTAssertEqual(session.corrections.count, 1)
        XCTAssertEqual((view.string as NSString).substring(with: session.corrections[0].range), "They was")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, original)
        var chapter = Chapter(); try chapter.setText(view.attributedString())
        XCTAssertNil(chapter.attributedText.attribute(.underlineColor, at: 0, effectiveRange: nil))
        session.cancel(); window.orderOut(nil)
    }

    @MainActor func testWholeManuscriptAcceptAndUndoAndStaleTextProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GrammarReviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let projectID = store.create(title: "Proofread", kind: .story)
        var first = Chapter(title: "First"), second = Chapter(title: "Second")
        try first.setText(NSAttributedString(string: "She go home.", attributes: WritingStyle.attributes))
        try second.setText(NSAttributedString(string: "They was waiting.", attributes: WritingStyle.attributes))
        store.update(projectID) { $0.chapters = [first, second] }
        let review = ManuscriptGrammarReview()
        review.reports = [ChapterGrammarReport(id: first.id, title: first.title, snapshot: first.plainText, corrections: GrammarText.locate([GrammarIssue(original: "She go", replacement: "She goes", explanation: "Agreement")], chunk: first.plainText, offset: 0)), ChapterGrammarReport(id: second.id, title: second.title, snapshot: second.plainText, corrections: GrammarText.locate([GrammarIssue(original: "They was", replacement: "They were", explanation: "Agreement")], chunk: second.plainText, offset: 0))]
        review.accept(Set(review.reports.flatMap(\.corrections).map(\.id)), projectID: projectID, store: store)
        XCTAssertEqual(store.project(projectID)?.chapters.map(\.plainText), ["She goes home.", "They were waiting."])
        XCTAssertEqual(review.correctionCount, 0)
        XCTAssertTrue(review.canUndo)
        XCTAssertFalse(store.revisions(projectID).isEmpty)
        review.undo(projectID: projectID, store: store)
        XCTAssertEqual(store.project(projectID)?.chapters.map(\.plainText), ["She go home.", "They was waiting."])
        var changed = first; try changed.setText(NSAttributedString(string: "Her name is Ada.", attributes: WritingStyle.attributes))
        store.update(projectID) { $0.chapters[0] = changed }
        review.accept(Set(review.reports.flatMap(\.corrections).map(\.id)), projectID: projectID, store: store)
        XCTAssertNotNil(review.message)
        XCTAssertEqual(store.project(projectID)?.chapters[1].plainText, "They was waiting.", "Stale group acceptance must not partially change other chapters")
    }
}
