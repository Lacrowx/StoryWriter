import XCTest
import AppKit
@testable import StoryWriter

final class TagNameChoiceTests: XCTestCase {
    private let cole = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Cole Skorp", group: "Characters", symbol: "person", summary: "", aliases: ["Cole", "Der Skorpion", "  Cole  ", ""])

    func testNameChoicesIncludeFullNameAliasesAndCharacterFirstNameOnlyOnce() {
        XCTAssertEqual(ObjectTags.nameChoices(cole), ["Cole Skorp", "Cole", "Der Skorpion"])
        var character = cole; character.aliases = ["cole", "Der Skorpion"]
        XCTAssertEqual(ObjectTags.nameChoices(character), ["Cole Skorp", "cole", "Der Skorpion"])
        let item = TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: UUID()), title: "Silver key", group: "Items", symbol: "key", summary: "", aliases: ["Key"])
        XCTAssertEqual(ObjectTags.nameChoices(item), ["Silver key", "Key"])
    }

    @MainActor private func withEditor(_ body: (ManuscriptTextView, ObjectTagSession, NSWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.orderFront(nil); window.makeFirstResponder(view)
        let session = ObjectTagSession(view: view); session.objects = [cole]; view.tagSession = session
        defer { session.close(); window.orderOut(nil) }
        try body(view, session, window)
    }

    @MainActor func testExactAliasPreservesTypedSpellingFormattingAndUndo() throws {
        try withEditor { view, session, _ in
            for name in ["Cole", "cole", "Der Skorpion", "Cole Skorp"] {
                let source = "🌊 Für @\(name)"
                let original = NSMutableAttributedString(string: source, attributes: WritingStyle.attributes)
                let originalName = (source as NSString).range(of: name)
                original.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: originalName)
                view.textStorage?.setAttributedString(original); view.undoManager?.removeAllActions()
                view.setSelectedRange(NSRange(location: original.length, length: 0)); session.refreshSuggestions()
                XCTAssertEqual(session.insertionLabel(for: cole), name)
                // Layout substitutes the emoji font before editing; compare against that rendered baseline.
                let before = view.attributedString()
                session.insert(cole)
                XCTAssertEqual(view.string, "🌊 Für \(name)")
                let range = (view.string as NSString).range(of: name)
                for index in range.location..<NSMaxRange(range) {
                    XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: index, effectiveRange: nil)), cole.reference)
                }
                let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                XCTAssertNil(view.typingAttributes[.link])
                view.undoManager?.undo(); XCTAssertTrue(view.attributedString().isEqual(to: before))
                view.undoManager?.redo(); XCTAssertEqual(view.string, "🌊 Für \(name)")
            }
        }
    }

    @MainActor func testExplicitChoiceReplacesAliasWithFullNameOrAnotherAlias() throws {
        try withEditor { view, session, _ in
            for name in ObjectTags.nameChoices(cole) {
                let source = "Für @Cole ging es weiter."
                let original = NSMutableAttributedString(string: source, attributes: WritingStyle.attributes)
                original.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: (source as NSString).range(of: "Cole"))
                view.textStorage?.setAttributedString(original); view.undoManager?.removeAllActions()
                view.setSelectedRange(NSRange(location: NSMaxRange((source as NSString).range(of: "@Cole")), length: 0))
                session.refreshSuggestions(); session.insert(cole, label: name)
                XCTAssertEqual(view.string, "Für \(name) ging es weiter.")
                let range = (view.string as NSString).range(of: name)
                var tags: [NSRange] = []
                view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                    if ProjectTagReference.from(value) == self.cole.reference { tags.append(range) }
                }
                XCTAssertEqual(tags, [range])
                let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                view.undoManager?.undo(); XCTAssertTrue(view.attributedString().isEqual(to: original))
            }
        }
    }

    @MainActor func testPartialQueriesUseFullNameWhileExplicitChoicesCanUseAlias() {
        withEditor { view, session, _ in
            for (label, expected) in [(nil, "Cole Skorp"), (Optional("Cole"), "Cole")] {
                view.textStorage?.setAttributedString(NSAttributedString(string: "Für @Col", attributes: WritingStyle.attributes))
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); session.refreshSuggestions()
                XCTAssertEqual(session.insertionLabel(for: cole), "Cole Skorp")
                session.insert(cole, label: label)
                XCTAssertEqual(view.string, "Für \(expected)")
            }
            view.textStorage?.setAttributedString(NSAttributedString(string: "Für @Cole", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); session.refreshSuggestions()
            session.insert(cole, label: "Unrelated name")
            XCTAssertEqual(view.string, "Für @Cole")
        }
    }

    @MainActor func testKeyboardChoosesNameAndCommitsWithReturnOrTab() throws {
        try withEditor { view, session, window in
            @MainActor func key(_ code: UInt16) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            }
            for (arrow, commit, expected) in [(UInt16(123), UInt16(36), "Cole Skorp"), (124, 48, "Der Skorpion")] {
                view.textStorage?.setAttributedString(NSAttributedString(string: "Für @Cole", attributes: WritingStyle.attributes))
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); session.refreshSuggestions()
                XCTAssertTrue(session.visible)
                XCTAssertTrue(session.handleKey(try key(arrow)))
                XCTAssertEqual(session.selectedLabel, expected)
                XCTAssertTrue(session.handleKey(try key(commit)))
                XCTAssertEqual(view.string, "Für \(expected)")
                XCTAssertNil(session.selectedLabel)
                XCTAssertFalse(session.visible)
            }
            view.textStorage?.setAttributedString(NSAttributedString(string: "Für @Cole", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); session.refreshSuggestions()
            XCTAssertTrue(session.handleKey(try key(36)))
            XCTAssertEqual(view.string, "Für Cole")
        }
    }
}
