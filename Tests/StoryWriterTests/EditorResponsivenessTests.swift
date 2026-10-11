import XCTest
import AppKit
import SwiftUI
import Combine
@testable import StoryWriter

final class EditorResponsivenessTests: XCTestCase {
    @MainActor func testTypingIsImmediatelySaveableAndUndoKeepsFormattingAndTags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypingTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Typing", kind: .story)
        let chapter = try XCTUnwrap(store.project(id)?.chapters.first)
        let controller = EditorController()
        let parent = RichTextEditor(chapter: store.itemBinding(id, \.chapters, id: chapter.id, fallback: chapter),
                                    controller: controller, language: "auto", onError: { XCTFail($0) })
        let coordinator = parent.makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        window.contentView = view
        defer { window.contentView = nil }
        view.isRichText = true; view.allowsUndo = true
        view.delegate = coordinator; controller.textView = view
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        let text = NSMutableAttributedString(string: "Ada waits. 😀", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        text.addAttribute(.link, value: reference.url, range: NSRange(location: 0, length: 3))
        view.textStorage?.setAttributedString(text)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        view.setSelectedRange(NSRange(location: text.length, length: 0))
        window.makeFirstResponder(view)
        view.insertText(" Hello", replacementRange: view.selectedRange())
        let live = try XCTUnwrap(store.project(id)?.chapters.first)
        XCTAssertEqual(live.plainText, "Ada waits. 😀 Hello")
        XCTAssertEqual(live.attributedText.string, live.plainText)
        XCTAssertTrue(store.saveNow()) // No wait or debounce flush is required.
        let reopened = ProjectStore(root: root, createExample: false)
        let saved = try XCTUnwrap(reopened.project(id)?.chapters.first)
        XCTAssertEqual(saved.plainText, live.plainText)
        XCTAssertEqual(ProjectTagReference.from(saved.attributedText.attribute(.link, at: 0, effectiveRange: nil)), reference)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(saved.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)).contains(.boldFontMask))
        view.undoManager?.undo()
        XCTAssertEqual(store.project(id)?.chapters.first?.plainText, text.string)
        XCTAssertEqual(live.attributedText.string, "Ada waits. 😀 Hello") // Earlier snapshots remain immutable.
    }

    func testEditingSnapshotsKeepAttachmentsAndExistingArchiveSchema() throws {
        let text = NSMutableAttributedString(string: "A picture: ", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: Data("reference".utf8))
        attachment.fileWrapper?.preferredFilename = "reference.txt"
        text.append(NSAttributedString(attachment: attachment))
        var chapter = Chapter()
        chapter.setEditingText(text)
        let original = chapter
        text.append(NSAttributedString(string: " Later."))
        chapter.setEditingText(text)
        XCTAssertNotEqual(original.richText, chapter.richText)
        XCTAssertFalse(original.attributedText.string.contains("Later"))
        // Match ProjectStore: unsorted JSON key order is not stable between encodes.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(chapter)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap(object["richText"] as? String)
        let archive = try XCTUnwrap(Data(base64Encoded: encoded))
        let decodedText = try NSAttributedString(data: archive, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        XCTAssertEqual(decodedText.string, text.string)
        let decoded = try JSONDecoder().decode(Chapter.self, from: data)
        let savedAttachment = try XCTUnwrap(decoded.attributedText.attribute(.attachment, at: 11, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(savedAttachment.fileWrapper?.regularFileContents, Data("reference".utf8))
        XCTAssertEqual(decoded.plainText, text.string)
        XCTAssertEqual(try encoder.encode(chapter), data)
    }

    @MainActor func testUnchangedToolbarStateDoesNotPublishAgain() {
        let editor = EditorController()
        let view = ManuscriptTextView(frame: .zero)
        view.textStorage?.setAttributedString(NSAttributedString(string: "Hello.", attributes: WritingStyle.attributes))
        editor.textView = view
        editor.refresh()
        var changes = 0
        let observation = editor.objectWillChange.sink { changes += 1 }
        for _ in 0..<20 { editor.refresh() }
        XCTAssertEqual(changes, 0)
        view.setSelectedRange(NSRange(location: 2, length: 0)); editor.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // Caret moves publish once they settle.
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(observation) {}
    }

    func testLongChapterTypingCost() throws {
        let text = NSMutableAttributedString(string: String(repeating: "The writer follows the story.\n", count: 6000), attributes: [.font: NSFont.systemFont(ofSize: 18)])
        var chapter = Chapter()
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<30 {
            text.append(NSAttributedString(string: "a"))
            try chapter.setText(text)
        }
        let archiveTime = CFAbsoluteTimeGetCurrent() - start
        let editingStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<30 {
            text.append(NSAttributedString(string: "a"))
            chapter.setEditingText(text)
        }
        let editingTime = CFAbsoluteTimeGetCurrent() - editingStart
        print("Typing benchmark, 174,000 characters: archive \(archiveTime * 1000 / 30) ms/key; snapshot \(editingTime * 1000 / 30) ms/key")
        XCTAssertEqual(chapter.attributedText.string, text.string)
        let saved = try JSONDecoder().decode(Chapter.self, from: JSONEncoder().encode(chapter))
        XCTAssertEqual(saved.plainText, text.string)
    }
}

final class TypingRefreshTests: XCTestCase {
    @MainActor func testTypingUpdatesStoreAtOnceButRedrawsAfterPause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypingRefresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Typing", kind: .story)
        let chapter = try XCTUnwrap(store.project(id)?.chapters.first)
        let binding = store.itemBinding(id, \.chapters, id: chapter.id, fallback: chapter, whileTyping: true)
        _ = store.saveNow()
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        for word in ["One", "One two", "One two three"] {
            var edited = binding.wrappedValue
            edited.setEditingText(NSAttributedString(string: word))
            binding.wrappedValue = edited
        }
        XCTAssertEqual(store.project(id)?.chapters.first?.plainText, "One two three") // Saving and export see it now.
        XCTAssertLessThanOrEqual(changes, 1) // At most the "Saving…" status, not one redraw per key.
        let before = changes
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertGreaterThan(changes, before) // Word counts and outlines refresh once typing pauses.
        withExtendedLifetime(observation) {}
    }

    @MainActor func testCaretMovesWhileTypingRefreshAfterPauseButSelectionsAtOnce() {
        let editor = EditorController()
        let view = ManuscriptTextView(frame: .zero)
        view.textStorage?.setAttributedString(NSAttributedString(string: "Hello there.", attributes: WritingStyle.attributes))
        editor.textView = view
        editor.refresh()
        var changes = 0
        let observation = editor.objectWillChange.sink { changes += 1 }
        view.setSelectedRange(NSRange(location: 2, length: 0)); editor.refresh()
        view.setSelectedRange(NSRange(location: 3, length: 0)); editor.refresh()
        XCTAssertEqual(editor.selectionRange, NSRange(location: 3, length: 0)) // Always current for commands.
        XCTAssertEqual(changes, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(changes, 1)
        view.setSelectedRange(NSRange(location: 0, length: 5)); editor.refresh()
        XCTAssertGreaterThanOrEqual(changes, 2) // Selecting enables selection commands immediately.
        withExtendedLifetime(observation) {}
    }
}
