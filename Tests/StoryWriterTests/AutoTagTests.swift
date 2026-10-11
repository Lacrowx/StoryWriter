import AppKit
import XCTest
@testable import StoryWriter

final class AutoTagTests: XCTestCase {
    private let mara = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Mara Vale", group: "Characters", symbol: "person", summary: "")
    private let will = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Will", group: "Characters", symbol: "person", summary: "")
    private let harbor = TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: UUID()), title: "Old Harbor", group: "Locations", symbol: "map", summary: "", aliases: ["the Harbor"])
    private let annaA = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Anna Berg", group: "Characters", symbol: "person", summary: "")
    private let annaB = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Anna Lind", group: "Characters", symbol: "person", summary: "")
    private var objects: [TaggedProjectObject] { [mara, will, harbor, annaA, annaB] }

    private func match(_ text: String, links: [(String, Any)] = []) -> (NSRange, ProjectTagReference)? {
        let storage = NSMutableAttributedString(string: text)
        for (phrase, value) in links { storage.addAttribute(.link, value: value, range: (text as NSString).range(of: phrase)) }
        // The boundary is the final character the writer just typed.
        return ObjectTags.autoTagMatch(in: storage, boundary: storage.length - 1, objects: objects).map { ($0.range, $0.object.reference) }
    }

    func testMatchesKnownNamesEndingAtTheTypedBoundary() throws {
        let cases: [(String, String, ProjectTagReference)] = [
            ("Then Mara ", "Mara", mara.reference), ("Then Mara Vale,", "Mara Vale", mara.reference),
            ("I saw Will.", "Will", will.reference), ("“Old Harbor”", "Old Harbor", harbor.reference),
            ("down to the Harbor ", "the Harbor", harbor.reference), ("Mara'", "Mara", mara.reference),
            ("Mara\n", "Mara", mara.reference)
        ]
        for (text, name, reference) in cases {
            let result = try XCTUnwrap(match(text), text)
            XCTAssertEqual((text as NSString).substring(with: result.0), name, text)
            XCTAssertEqual(result.1, reference, text)
        }
    }

    func testIgnoresCaseMismatchesPartialWordsAmbiguityAndAtQueries() {
        XCTAssertNil(match("I will "))            // Lowercase prose is not the name Will.
        XCTAssertNil(match("Tamara "))            // Only whole words.
        XCTAssertNil(match("Willow "))
        XCTAssertNil(match("Anna "))              // Two characters share this first name.
        XCTAssertNil(match("@Mara "))             // The @ completion handles its own query.
        XCTAssertNil(match("Mara"))               // No boundary typed yet.
    }

    func testRespectsExistingTagsAndLinks() throws {
        XCTAssertNil(match("Mara Vale ", links: [("Mara Vale", mara.reference.url)])) // Already tagged.
        XCTAssertNil(match("Mara ", links: [("Mara", URL(string: "https://example.com")!)]))
        XCTAssertNil(match("Mara Vale ", links: [("Vale", harbor.reference.url)]))
        // Typing the surname extends the first-name tag to the full name.
        let extended = try XCTUnwrap(match("Mara Vale ", links: [("Mara", mara.reference.url)]))
        XCTAssertEqual(extended.0, NSRange(location: 0, length: 9))
    }

    @MainActor private func withEditor(_ body: (ManuscriptTextView, ObjectTagSession) throws -> Void) rethrows {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.orderFront(nil); window.makeFirstResponder(view)
        let session = ObjectTagSession(view: view); session.objects = objects; view.tagSession = session
        defer { session.close(); window.orderOut(nil) }
        try body(view, session)
    }

    @MainActor private func type(_ text: String, into view: NSTextView, waitingForTagAt index: Int? = nil) {
        for character in text {
            view.insertText(String(character), replacementRange: view.selectedRange())
            RunLoop.main.run(until: Date().addingTimeInterval(0.005)) // Each key is its own event.
        }
        // Auto-tagging runs after the keystroke finishes; slower machines may need a moment longer.
        let deadline = Date().addingTimeInterval(1)
        while let index, reference(in: view, at: index) == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func reference(in view: NSTextView, at index: Int) -> ProjectTagReference? {
        ProjectTagReference.from(view.textStorage?.attribute(.link, at: index, effectiveRange: nil))
    }

    @MainActor func testTypingTagsNamesWithSeparateUndo() throws {
        try withEditor { view, _ in
            view.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: WritingStyle.attributes))
            view.typingAttributes = WritingStyle.attributes.merging([.font: NSFont.boldSystemFont(ofSize: 18)]) { $1 }
            type("Then Mara ", into: view, waitingForTagAt: 5)
            type("waited", into: view)
            XCTAssertEqual(view.string, "Then Mara waited")
            XCTAssertEqual(reference(in: view, at: 5), mara.reference)
            XCTAssertEqual(reference(in: view, at: 8), mara.reference)
            XCTAssertNil(reference(in: view, at: 9), "The space after the name stays untagged")
            XCTAssertNil(reference(in: view, at: 12), "Following prose stays untagged")
            XCTAssertTrue(NSFontManager.shared.traits(of: view.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont).contains(.boldFontMask))
            XCTAssertEqual(view.selectedRange(), NSRange(location: view.string.utf16.count, length: 0))
            // Undo removes the typing after the tag, then the tag, keeping the word.
            view.undoManager?.undo()
            XCTAssertEqual(view.string, "Then Mara ")
            XCTAssertEqual(reference(in: view, at: 5), mara.reference)
            view.undoManager?.undo()
            XCTAssertEqual(view.string, "Then Mara ")
            XCTAssertNil(reference(in: view, at: 5))
        }
    }

    @MainActor func testPastesUndoAndDisabledSettingDoNotTag() throws {
        try withEditor { view, session in
            view.insertText("Then Mara ", replacementRange: NSRange(location: 0, length: 0)) // A paste arrives at once.
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            XCTAssertNil(reference(in: view, at: 5))
            view.textStorage?.setAttributedString(NSAttributedString(string: ""))
            session.autoTagsNames = false
            type("Then Mara ", into: view)
            XCTAssertNil(reference(in: view, at: 5))
        }
    }
}

final class NameCompletionTests: XCTestCase {
    private let mara = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Mara Vale", group: "Characters", symbol: "person", summary: "")
    private let annaA = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Anna Berg", group: "Characters", symbol: "person", summary: "")
    private let annaB = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Anna Lind", group: "Characters", symbol: "person", summary: "")
    private let harbor = TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: UUID()), title: "Old Harbor", group: "Locations", symbol: "map", summary: "")
    private var objects: [TaggedProjectObject] { [mara, annaA, annaB, harbor] }

    private func completion(_ text: String, caret: Int? = nil) -> (prefix: String, name: String, reference: ProjectTagReference)? {
        let caret = caret ?? text.utf16.count
        return ObjectTags.completion(in: text, caret: caret, objects: objects).map {
            ((text as NSString).substring(with: $0.prefix), $0.name, $0.object.reference)
        }
    }

    func testCompletesUniquePrefixesOfKnownNames() throws {
        let cases: [(String, String, String, ProjectTagReference)] = [
            ("Then Ma", "Ma", "Mara", mara.reference),           // The shortest name of a single entry.
            ("Then Mara V", "Mara V", "Mara Vale", mara.reference), // Several words.
            ("Then Anna B", "Anna B", "Anna Berg", annaA.reference),
            ("near Old H", "Old H", "Old Harbor", harbor.reference),
            ("“Ma", "Ma", "Mara", mara.reference)
        ]
        for (text, prefix, name, reference) in cases {
            let result = try XCTUnwrap(completion(text), text)
            XCTAssertEqual(result.prefix, prefix, text); XCTAssertEqual(result.name, name, text); XCTAssertEqual(result.reference, reference, text)
        }
    }

    func testOffersNothingWhenUnclearOrUnhelpful() {
        XCTAssertNil(completion("Then M"))          // Too short.
        XCTAssertNil(completion("Then ma"))         // Case differs.
        XCTAssertNil(completion("Then An"))         // Two different Annas.
        XCTAssertNil(completion("Tama"))            // Inside another word.
        XCTAssertNil(completion("Then Mara"))       // Already complete.
        XCTAssertNil(completion("@Ma"))             // The @ completion handles its own query.
        XCTAssertNil(completion("Then Ma later", caret: 7)) // Ghost text would cover following words.
        XCTAssertNotNil(completion("Then Ma\nNext", caret: 7))
    }

    @MainActor func testTabAcceptsCompletionAsOneTaggedUndoStep() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.orderFront(nil); window.makeFirstResponder(view)
        let session = ObjectTagSession(view: view); session.objects = objects; view.tagSession = session
        defer { session.close(); window.orderOut(nil) }
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        view.insertText("Then Ma", replacementRange: NSRange(location: 0, length: 0))
        session.refreshCompletion()
        XCTAssertEqual(session.completion?.name, "Mara")
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        view.keyDown(with: tab)
        XCTAssertEqual(view.string, "Then Mara")
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: 5, effectiveRange: nil)), mara.reference)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 9, length: 0))
        XCTAssertNil(session.completion)
        XCTAssertNil(view.typingAttributes[.link], "Typing after a completed name is ordinary prose")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "Then Ma")
        // Without a suggestion, Tab types a tab as usual.
        session.refreshCompletion()
        session.completionsEnabled = false; session.refreshCompletion()
        XCTAssertNil(session.completion)
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.keyDown(with: tab)
        XCTAssertEqual(view.string, "Then Ma\t")
    }
}
