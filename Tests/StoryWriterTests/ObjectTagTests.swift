import XCTest
import AppKit
@testable import StoryWriter

final class ObjectTagTests: XCTestCase {
    func testSuggestionsAndTriggerRespectObjectsUnicodeAndEmails() {
        var project = StoryProject.example()
        project.characters.append(Character(name: "Mára Vale", role: "Cartographer"))
        project.worldNotes.append(WorldNote(title: "Silver key", category: .object, summary: "Opens the lighthouse"))
        let objects = project.tagObjects
        XCTAssertEqual(objects.count, project.characters.count + project.worldNotes.count)
        XCTAssertEqual(ObjectTags.matches(objects, query: "silver").first?.group, "Items")
        XCTAssertTrue(ObjectTags.matches(objects, query: "mara").contains { $0.title == "Mára Vale" })
        XCTAssertEqual(ObjectTags.matches(objects, query: "island").first?.group, "Locations")
        for text in ["@", "🌊 @Mára V", "She met (@Mara"] {
            let range = ObjectTags.queryRange(in: text, selection: NSRange(location: text.utf16.count, length: 0))
            XCTAssertNotNil(range)
            XCTAssertTrue((text as NSString).substring(with: range!).hasPrefix("@"))
        }
        for text in ["writer@example.com", "writer@example", "@Mara. Then she left", "@Mara\n", "hello@"] {
            XCTAssertNil(ObjectTags.queryRange(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        }
        XCTAssertNil(ObjectTags.queryRange(in: "@Mara", selection: NSRange(location: 0, length: 5)))
    }

    @MainActor func testTagInsertionSelectionFormattingAndUndo() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds); view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.makeFirstResponder(view)
        let project = StoryProject.example(), object = project.tagObjects.first!
        let session = ObjectTagSession(view: view); session.objects = project.tagObjects; view.tagSession = session
        view.textStorage?.setAttributedString(NSAttributedString(string: "She met @Mara", attributes: WritingStyle.attributes))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        session.refreshSuggestions(); session.insert(object)
        XCTAssertEqual(view.string, "She met Mara Vale")
        let range = (view.string as NSString).range(of: "Mara Vale")
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)), object.reference)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "She met @Mara")
        view.undoManager?.redo()
        XCTAssertEqual(view.string, "She met Mara Vale")
        view.insertText(NSAttributedString(string: " walks", attributes: [.link: object.reference.url]), replacementRange: view.selectedRange())
        let pasted = (view.string as NSString).range(of: "walks").location
        XCTAssertNil(ProjectTagReference.from(view.textStorage?.attribute(.link, at: pasted, effectiveRange: nil)), "Pasted prose after a tag must stay untagged")
        view.insertText(" walked away.", replacementRange: view.selectedRange())
        let after = (view.string as NSString).range(of: "walked").location
        XCTAssertNil(ProjectTagReference.from(view.textStorage?.attribute(.link, at: after, effectiveRange: nil)), "Typing after a tag must not extend its link")
        let nickname = (view.string as NSString).range(of: "Mara")
        view.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: nickname)
        view.setSelectedRange(nickname); session.insert(object)
        XCTAssertTrue(view.string.contains("Mara Vale"), "Tagging existing prose must preserve its label")
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: nickname.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        session.removeSelectedTag()
        XCTAssertNil(ProjectTagReference.from(view.textStorage?.attribute(.link, at: nickname.location, effectiveRange: nil)))
        view.undoManager?.undo()
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: nickname.location, effectiveRange: nil)), object.reference)
    }

    @MainActor func testTagsSurvivePortableCopyAndStayOutOfPublications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ObjectTags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Tagged story", kind: .story)
        let character = Character(name: "Elisa")
        let ref = ProjectTagReference(kind: .character, objectID: character.id)
        let text = NSMutableAttributedString(string: "Elisa reads a letter.", attributes: WritingStyle.attributes)
        text.addAttribute(.link, value: ref.url, range: NSRange(location: 0, length: 5))
        text.addAttribute(.link, value: URL(string: "https://example.com/letter")!, range: NSRange(location: 14, length: 6))
        var chapter = store.project(id)!.chapters[0]; try chapter.setText(text)
        store.update(id) { $0.characters = [character]; $0.chapters = [chapter] }
        XCTAssertTrue(store.saveNow())
        let portable = root.appendingPathComponent("Tagged.storywriter"); try store.exportPackage(id, to: portable)
        let reopened = ProjectStore(root: root.appendingPathComponent("imported"), createExample: false); reopened.importPackage(portable)
        let imported = try XCTUnwrap(reopened.selectedProject)
        XCTAssertNotEqual(imported.id, id)
        let restoredRef = ProjectTagReference.from(imported.chapters[0].attributedText.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(restoredRef, ref)
        XCTAssertTrue(imported.tagObjects.contains { $0.reference == restoredRef })
        var renamed = imported; renamed.characters[0].name = "Elisa Vale"
        XCTAssertEqual(renamed.tagObjects.first { $0.reference == ref }?.title, "Elisa Vale")
        let publicText = ObjectTags.publicationText(imported.chapters[0].attributedText)
        XCTAssertEqual(publicText.string, text.string)
        XCTAssertNil(publicText.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNotNil(publicText.attribute(.link, at: 14, effectiveRange: nil))
        XCTAssertFalse(ExportService.manuscript(project: imported, chapters: imported.chapters).description.contains("storywriter://"))
        for format in [ExportFormat.docx, .rtf, .html, .markdown] {
            let url = root.appendingPathComponent("public.\(format.fileExtension)")
            try ExportService.export(project: imported, chapters: imported.chapters, format: format, to: url)
            if format == .docx || format == .rtf {
                let result = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
                var internalLink = false
                result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, _, _ in if ProjectTagReference.from(value) != nil { internalLink = true } }
                XCTAssertFalse(internalLink)
                XCTAssertTrue(result.string.contains("Elisa reads"))
            } else { XCTAssertFalse(try String(contentsOf: url).contains("storywriter://")) }
        }
        XCTAssertNil(ProjectTagReference(url: URL(string: "https://tag/character/\(character.id)")!))
        XCTAssertNil(ProjectTagReference(url: URL(string: "storywriter://tag/character/not-an-id")!))
    }
}
