import AppKit
import XCTest
@testable import StoryWriter

final class SpaceTagTests: XCTestCase {
    private let cole = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Cole Skorp", group: "Characters", symbol: "person", summary: "", aliases: ["Cole", "Der Skorpion"])
    private let item = TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: UUID()), title: "Silver key", group: "Items", symbol: "key", summary: "", aliases: ["Key"])

    @MainActor private func withEditor(_ body: (ManuscriptTextView, ObjectTagSession, NSWindow) throws -> Void) rethrows {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.orderFront(nil); window.makeFirstResponder(view)
        let session = ObjectTagSession(view: view); session.objects = [cole, item]; view.tagSession = session
        defer { session.close(); window.orderOut(nil) }
        try body(view, session, window)
    }

    @MainActor private func key(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "", charactersIgnoringModifiers: code == 49 ? " " : "", isARepeat: false, keyCode: code)
        return try XCTUnwrap(event)
    }

    @MainActor func testSpaceTagsExactNamesAndAliasesAndKeepsFollowingProseUntagged() throws {
        try withEditor { view, session, window in
            for (name, object) in [("Cole", cole), ("cole", cole), ("Cole Skorp", cole), ("Der Skorpion", cole), ("Silver key", item), ("Key", item)] {
                let source = "Für @\(name)"
                let original = NSMutableAttributedString(string: source, attributes: WritingStyle.attributes)
                original.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: (source as NSString).range(of: name))
                view.textStorage?.setAttributedString(original)
                view.setSelectedRange(NSRange(location: original.length, length: 0)); session.refreshSuggestions()
                view.undoManager?.removeAllActions()
                XCTAssertTrue(session.handleKey(try key(49, window: window)))
                XCTAssertEqual(view.string, "Für \(name) ")
                XCTAssertEqual(view.selectedRange(), NSRange(location: view.string.utf16.count, length: 0))
                XCTAssertFalse(session.visible)
                let nameRange = (view.string as NSString).range(of: name)
                var ranges: [NSRange] = []
                view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                    if ProjectTagReference.from(value) == object.reference { ranges.append(range) }
                }
                XCTAssertEqual(ranges, [nameRange])
                XCTAssertNil(view.typingAttributes[.link])
                let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: nameRange.location, effectiveRange: nil) as? NSFont)
                XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                view.undoManager?.undo(); XCTAssertTrue(view.attributedString().isEqual(to: original), "Tag and space should undo together")
                view.undoManager?.redo(); XCTAssertEqual(view.string, "Für \(name) ")
                view.insertText("ging weiter", replacementRange: view.selectedRange())
                let prose = (view.string as NSString).range(of: "ging weiter")
                view.textStorage?.enumerateAttribute(.link, in: prose) { value, _, _ in XCTAssertNil(value) }
                XCTAssertEqual(view.string, "Für \(name) ging weiter")
            }
        }
    }

    @MainActor func testSpaceDoesNotCompletePartialMultiwordOrUnknownQueries() throws {
        try withEditor { view, session, window in
            for query in ["@", "@Der", "@Silver", "@Col", "@Unknown"] {
                view.textStorage?.setAttributedString(NSAttributedString(string: query, attributes: WritingStyle.attributes))
                view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); session.refreshSuggestions()
                XCTAssertFalse(session.handleKey(try key(49, window: window)), query)
                XCTAssertEqual(view.string, query)
            }
            view.textStorage?.setAttributedString(NSAttributedString(string: "@Der", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: 4, length: 0)); session.refreshSuggestions()
            view.keyDown(with: try key(49, window: window))
            XCTAssertEqual(view.string, "@Der ")
            view.insertText("Skorpion", replacementRange: view.selectedRange()); session.refreshSuggestions()
            view.keyDown(with: try key(49, window: window))
            XCTAssertEqual(view.string, "Der Skorpion ")
        }
    }

    @MainActor func testSpaceAcceptsDeliberatelyChosenNameOrObject() throws {
        try withEditor { view, session, window in
            view.textStorage?.setAttributedString(NSAttributedString(string: "@Cole", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: 5, length: 0)); session.refreshSuggestions()
            XCTAssertTrue(session.handleKey(try key(123, window: window)))
            XCTAssertEqual(session.selectedLabel, "Cole Skorp")
            XCTAssertTrue(session.handleKey(try key(49, window: window)))
            XCTAssertEqual(view.string, "Cole Skorp ")
            view.textStorage?.setAttributedString(NSAttributedString(string: "@Col", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: 4, length: 0)); session.refreshSuggestions()
            XCTAssertTrue(session.handleKey(try key(125, window: window)))
            XCTAssertTrue(session.handleKey(try key(49, window: window)))
            XCTAssertEqual(view.string, "Cole Skorp ")
        }
    }

    @MainActor func testSharedAliasesAndToolbarBrowsingNeedExplicitChoice() throws {
        try withEditor { view, session, window in
            var other = cole; other.reference.objectID = UUID(); other.title = "Cole Vale"
            session.objects.append(other)
            view.textStorage?.setAttributedString(NSAttributedString(string: "@Cole", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: 5, length: 0)); session.refreshSuggestions()
            XCTAssertFalse(session.handleKey(try key(49, window: window)))
            XCTAssertEqual(view.string, "@Cole")
            XCTAssertTrue(session.handleKey(try key(125, window: window)))
            XCTAssertTrue(session.handleKey(try key(49, window: window)))
            XCTAssertEqual(view.string, "Cole ")
            XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil)), other.reference)
            session.browse()
            XCTAssertFalse(session.handleKey(try key(49, window: window)))
        }
    }

    @MainActor func testModifiedSpaceAndStaleCaretDoNotCommit() throws {
        try withEditor { view, session, window in
            view.textStorage?.setAttributedString(NSAttributedString(string: "@Cole", attributes: WritingStyle.attributes))
            view.setSelectedRange(NSRange(location: 5, length: 0)); session.refreshSuggestions()
            for modifiers: NSEvent.ModifierFlags in [.command, .control, .option] {
                XCTAssertFalse(session.handleKey(try key(49, window: window, modifiers: modifiers)))
            }
            view.setSelectedRange(NSRange(location: 3, length: 0))
            XCTAssertFalse(session.handleKey(try key(49, window: window)))
            XCTAssertEqual(view.string, "@Cole")
        }
    }
}
