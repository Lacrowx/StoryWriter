import XCTest
import AppKit
@testable import StoryWriter

final class SelectionQuickActionTests: XCTestCase {
    @MainActor private func fixture(width: CGFloat = 600) -> (NSWindow, ManuscriptTextView, EditorController, SelectionQuickActionSession) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
        view.isRichText = true; view.allowsUndo = true
        scroll.documentView = view; window.contentView?.addSubview(scroll)
        let editor = EditorController(); editor.textView = view; view.contextEditor = editor
        view.textStorage?.setAttributedString(NSAttributedString(string: "🌊 Before. Mara Vale carries the silver key. After.", attributes: WritingStyle.attributes))
        let grammar = InlineGrammarSession(view: view, documentLabel: "chapter", documentKey: UUID().uuidString)
        view.grammarSession = grammar
        let tags = ObjectTagSession(view: view); tags.objects = StoryProject.example().tagObjects; view.tagSession = tags
        let session = SelectionQuickActionSession(view: view); view.selectionActions = session
        window.orderFront(nil); window.makeFirstResponder(view); view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        return (window, view, editor, session)
    }

    @MainActor func testOnlyNonemptyTextSelectionsHaveActions() {
        let (window, view, editor, session) = fixture()
        defer { session.close(); window.orderOut(nil); _ = editor }
        for range in [NSRange(location: 0, length: 0), NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1), NSRange(location: 1000, length: 1)] {
            XCTAssertFalse(SelectionQuickActionSession.isPassage(range, in: view.string))
        }
        XCTAssertFalse(SelectionQuickActionSession.isPassage(NSRange(location: 0, length: 3), in: " \n\t"))
        XCTAssertTrue(SelectionQuickActionSession.isPassage(NSRange(location: 0, length: 2), in: "🌊"))
        XCTAssertFalse(session.present())
        XCTAssertFalse(session.visible)
    }

    @MainActor func testActionsKeepExactPassageAndRefuseStaleTextOrSelection() throws {
        let (window, view, editor, session) = fixture()
        defer { session.close(); window.orderOut(nil); _ = editor }
        let range = (view.string as NSString).range(of: "Mara Vale carries")
        var received: NSRange?
        view.chapterContextCommands = { range, _ in [.button("Add comment to selection") { received = range }] }
        view.setSelectedRange(range)
        XCTAssertTrue(session.present())
        let comment = try XCTUnwrap(session.chapterCommands.first)
        window.makeFirstResponder(nil)
        comment.action?()
        XCTAssertEqual(received, range)
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertFalse(session.visible)
        XCTAssertTrue(session.present())
        let stale = try XCTUnwrap(session.chapterCommands.first)
        received = nil
        view.setSelectedRange(NSRange(location: 0, length: 2))
        stale.action?()
        XCTAssertNil(received)
        view.setSelectedRange(range); XCTAssertTrue(session.present())
        let oldText = try XCTUnwrap(session.chapterCommands.first)
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Changed ")
        oldText.action?()
        XCTAssertNil(received)
    }

    @MainActor func testFormattingTargetsSelectionAndRemainsUndoable() throws {
        let (window, view, editor, session) = fixture()
        defer { session.close(); window.orderOut(nil); _ = editor }
        let original = view.attributedString().copy() as! NSAttributedString
        let range = (view.string as NSString).range(of: "Mara Vale")
        view.setSelectedRange(range); XCTAssertTrue(session.present())
        session.formatting.first { $0.title == "Bold" }?.action?()
        XCTAssertEqual(view.string, original.string)
        let selected = try XCTUnwrap(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: selected).contains(.boldFontMask))
        let outside = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: outside).contains(.boldFontMask))
        view.undoManager?.undo()
        XCTAssertTrue(view.attributedString().isEqual(to: original))
    }

    @MainActor func testTagActionsInspectWholeSelectionAndSuggestionsStayScoped() throws {
        let (window, view, editor, session) = fixture()
        defer { session.close(); window.orderOut(nil); _ = editor }
        let object = try XCTUnwrap(view.tagSession?.objects.first)
        let tagged = (view.string as NSString).range(of: "Mara Vale")
        view.textStorage?.addAttribute(.link, value: object.reference.url, range: tagged)
        let full = NSRange(location: 0, length: view.string.utf16.count)
        view.setSelectedRange(full); XCTAssertTrue(session.present())
        XCTAssertTrue(session.tagCommands.contains { $0.title == "Open \(object.title)" })
        XCTAssertTrue(session.tagCommands.contains { $0.title == "Remove tags from selection" })
        var opened: ProjectTagReference?
        view.tagSession?.open = { opened = $0 }
        session.tagCommands.first { $0.title == "Open \(object.title)" }?.action?()
        XCTAssertEqual(opened, object.reference)
        view.setSelectedRange((view.string as NSString).range(of: "After")); XCTAssertTrue(session.present())
        XCTAssertFalse(session.tagCommands.contains { $0.title.hasPrefix("Open ") || $0.title == "Remove tags from selection" })
        XCTAssertTrue(session.suggestionCommands.isEmpty)
        let grammar = try XCTUnwrap(view.grammarSession)
        grammar.corrections = [LocatedCorrection(issue: GrammarIssue(original: "After", replacement: "Later", explanation: "", kind: .style), range: view.selectedRange())]
        XCTAssertTrue(session.suggestionCommands.first?.title.contains("1 suggestion") == true)
        view.setSelectedRange(tagged); XCTAssertTrue(session.present())
        XCTAssertTrue(session.suggestionCommands.isEmpty, "Suggestions outside the selected passage must not be accepted")
    }

    @MainActor func testWrappedSelectionAnchorAndDismissalOnScrollEscapeAndEdits() throws {
        let (window, view, editor, session) = fixture(width: 360)
        defer { session.close(); window.orderOut(nil); _ = editor }
        view.textStorage?.setAttributedString(NSAttributedString(string: String(repeating: "A selected passage across several lines. ", count: 20), attributes: WritingStyle.attributes))
        let range = NSRange(location: 0, length: view.string.utf16.count)
        view.setSelectedRange(range); XCTAssertTrue(session.present())
        let anchor = try XCTUnwrap(session.anchor)
        XCTAssertLessThan(anchor.height, 60, "The bubble should anchor to one visible line, not the full selection")
        XCTAssertTrue(view.visibleRect.contains(anchor))
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        XCTAssertFalse(session.visible)
        XCTAssertTrue(session.present(), "A selection beginning offscreen still has a visible line anchor")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertFalse(session.visible)
        XCTAssertEqual(view.selectedRange(), range)
        XCTAssertTrue(session.present())
        view.insertText("Replacement", replacementRange: range)
        XCTAssertFalse(session.visible)
    }

    @MainActor func testKeyboardSelectionPresentsAfterPauseAndCollapsedSelectionDismisses() async throws {
        let (window, view, editor, session) = fixture()
        defer { session.close(); window.orderOut(nil); _ = editor }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        view.setSelectedRange((view.string as NSString).range(of: "Mara Vale"))
        session.selectionChanged()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(session.visible)
        view.setSelectedRange(NSRange(location: 0, length: 0)); session.selectionChanged()
        XCTAssertFalse(session.visible)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(session.visible)
    }
    @MainActor func testNameSuggestionKeepsItsOwnBubble() async throws {
        let (window, view, editor, session) = fixture()
        let names = ObjectNameSession(view: view); view.objectNames = names
        defer { names.cancel(); session.close(); window.orderOut(nil); _ = editor }
        names.textChanged()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        let range = (view.string as NSString).range(of: "Mara Vale")
        view.setSelectedRange(range); session.selectionChanged()
        names.show(ObjectNameSuggestion(name: "Mara Vale", range: range, kind: .character))
        window.makeFirstResponder(view)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(names.popoverVisible)
        XCTAssertFalse(session.visible, "Quick actions must not replace an existing name suggestion card")
    }

}
