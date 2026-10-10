import XCTest
import AppKit
@testable import StoryWriter

final class ContextMenuTests: XCTestCase {
    @MainActor func testNativeMenuRetainsActionsAndHonorsDisabledState() throws {
        _ = NSApplication.shared
        var invoked = 0
        let menu = ContextCommand.menu([
            .button("Settings…", checked: true) { invoked += 1 },
            .button("Unavailable", enabled: false) { invoked += 100 },
            .submenu("Project", [.button("Save") { invoked += 10 }])
        ])
        let settings = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(settings.state, .on)
        XCTAssertNotNil(settings.target)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(invoked, 1)
        let disabled = menu.items[1]
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertFalse((disabled.target as? NSMenuItemValidation)?.validateMenuItem(disabled) ?? true)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(invoked, 1)
        menu.items[2].submenu?.performActionForItem(at: 0)
        XCTAssertEqual(invoked, 11)
    }

    @MainActor func testRichAndPlainFieldsExposeApplicableActionsAndSelection() throws {
        let editor = EditorController()
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.textView = view; view.contextEditor = editor
        view.string = "A selected passage. Another sentence."
        let selection = NSRange(location: 2, length: 16)
        view.setSelectedRange(selection)
        view.grammarSession = InlineGrammarSession(view: view, documentLabel: "note", documentKey: UUID().uuidString)
        var received: NSRange?
        view.chapterContextCommands = { range, _ in [.button("Add comment") { received = range }] }
        var opened = false
        view.appContextCommands = { [.button("Settings…") { opened = true }] }
        view.isRichText = true
        var commands = view.writingContextCommands()
        XCTAssertTrue(commands.contains { $0.title == "Formatting" })
        XCTAssertTrue(commands.contains { $0.title == "Review writing" })
        commands.first { $0.title == "Add comment" }?.action?()
        XCTAssertEqual(received, selection)
        commands.first { $0.title == "Settings…" }?.action?()
        XCTAssertTrue(opened)
        view.isRichText = false; view.chapterContextCommands = nil
        view.setSelectedRange(NSRange(location: 0, length: 0))
        commands = view.writingContextCommands()
        XCTAssertFalse(commands.contains { $0.title == "Formatting" || $0.title == "Add comment" })
        XCTAssertTrue(commands.contains { $0.title == "Find in field…" })
        let review = try XCTUnwrap(commands.first { $0.title == "Review writing" }?.children)
        XCTAssertFalse(try XCTUnwrap(review.first { $0.title == "Review selected passage" }).enabled)
        XCTAssertTrue(try XCTUnwrap(review.first { $0.title == "Review entire text" }).enabled)
    }

    @MainActor func testRightClickInsideSelectionPreservesPassageAndNativeEditingMenu() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = view
        view.string = "An opening paragraph. A selected passage."
        view.font = .systemFont(ofSize: 18)
        view.textContainerInset = NSSize(width: 28, height: 36)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let selection = (view.string as NSString).range(of: "selected passage")
        view.setSelectedRange(selection)
        let glyphs = view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: selection.location + 3, length: 1), actualCharacterRange: nil)
        let rect = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let point = view.convert(NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.appContextCommands = { [.button("Settings…") {}] }
        let menu = try XCTUnwrap(view.menu(for: event))
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(menu.items.contains { $0.action == #selector(NSText.copy(_:)) })
        XCTAssertTrue(menu.items.contains { $0.title == "Settings…" })
        window.contentView = nil
    }
}
