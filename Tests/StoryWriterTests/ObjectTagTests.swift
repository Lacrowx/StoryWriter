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
        XCTAssertEqual(view.string, "She met Mara")
        let range = (view.string as NSString).range(of: "Mara")
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)), object.reference)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "She met @Mara")
        view.undoManager?.redo()
        XCTAssertEqual(view.string, "She met Mara")
        view.insertText(NSAttributedString(string: " walks", attributes: [.link: object.reference.url]), replacementRange: view.selectedRange())
        let pasted = (view.string as NSString).range(of: "walks").location
        XCTAssertNil(ProjectTagReference.from(view.textStorage?.attribute(.link, at: pasted, effectiveRange: nil)), "Pasted prose after a tag must stay untagged")
        view.insertText(" walked away.", replacementRange: view.selectedRange())
        let after = (view.string as NSString).range(of: "walked").location
        XCTAssertNil(ProjectTagReference.from(view.textStorage?.attribute(.link, at: after, effectiveRange: nil)), "Typing after a tag must not extend its link")
        let nickname = (view.string as NSString).range(of: "Mara")
        view.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: nickname)
        view.setSelectedRange(nickname); session.insert(object)
        XCTAssertTrue(view.string.contains("Mara"), "Tagging existing prose must preserve its label")
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

    @MainActor func testAtTagReusesExistingNamesAndPreservesFormattingAndUndo() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds); view.isRichText = true; view.allowsUndo = true
        window.contentView?.addSubview(view); window.makeFirstResponder(view)
        let cole = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Cole Skorp", group: "Characters", symbol: "person", summary: "", aliases: ["Der Skorpion"])
        let academy = TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: UUID()), title: "Akademia Atorus", group: "Locations", symbol: "map", summary: "")
        let session = ObjectTagSession(view: view); session.objects = [cole, academy]; view.tagSession = session
        let examples: [(String, String, TaggedProjectObject, String, String)] = [
            ("🌊 Cole @ wartet.", "@", cole, "🌊 Cole wartet.", "Cole"),
            ("Cole@ wartet.", "@", cole, "Cole wartet.", "Cole"),
            ("Cole Skorp @Co wartet.", "@Co", cole, "Cole Skorp wartet.", "Cole Skorp"),
            ("Der Skorpion @ wartet.", "@", cole, "Der Skorpion wartet.", "Der Skorpion"),
            ("Die @Akademia Atorus lag im Nebel.", "@", academy, "Die Akademia Atorus lag im Nebel.", "Akademia Atorus"),
            ("Die @Akademia Atorus lag im Nebel.", "@Akad", academy, "Die Akademia Atorus lag im Nebel.", "Akademia Atorus"),
            ("Die Akademia Atorus @Aka lag im Nebel.", "@Aka", academy, "Die Akademia Atorus lag im Nebel.", "Akademia Atorus"),
            ("Cole sah Cole @ gehen.", "@", cole, "Cole sah Cole gehen.", "Cole")
        ]
        for (source, query, object, expected, name) in examples {
            view.undoManager?.removeAllActions()
            let text = NSMutableAttributedString(string: source, attributes: WritingStyle.attributes)
            let sourceName = (source as NSString).range(of: name, options: .backwards)
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: sourceName)
            view.textStorage?.setAttributedString(text)
            let trigger = (source as NSString).range(of: query)
            view.setSelectedRange(NSRange(location: NSMaxRange(trigger), length: 0))
            session.refreshSuggestions(); session.insert(object)
            XCTAssertEqual(view.string, expected, source)
            let nameRange = (expected as NSString).range(of: name, options: .backwards)
            func verifyTag() throws {
                var ranges: [NSRange] = []
                view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
                    if ProjectTagReference.from(value) == object.reference { ranges.append(range) }
                }
                XCTAssertEqual(ranges, [nameRange], source)
                let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: nameRange.location, effectiveRange: nil) as? NSFont)
                XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask), source)
                XCTAssertNil(ProjectTagReference.from(view.typingAttributes[.link]))
            }
            try verifyTag()
            view.undoManager?.undo()
            XCTAssertEqual(view.string, source, source)
            XCTAssertNil(view.textStorage?.attribute(.link, at: sourceName.location, effectiveRange: nil))
            view.undoManager?.redo()
            XCTAssertEqual(view.string, expected, source)
            try verifyTag()
            session.close()
        }
    }

    func testExistingMentionMatchesWholeLocalNamesOnly() {
        let cole = TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: UUID()), title: "Cole Skorp", group: "Characters", symbol: "person", summary: "")
        let academy = TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: UUID()), title: "Akademia Atorus", group: "Locations", symbol: "map", summary: "")
        for (source, object) in [("Coleman @", cole), ("Cole ging. @", cole), ("Cole\n@", cole), ("Akademia @", academy), ("Akademia Atorusian @", academy), ("@Akademia Atorusian", academy)] {
            let trigger = (source as NSString).range(of: "@")
            XCTAssertNil(ObjectTags.existingMention(in: source, object: object, beside: trigger), source)
        }
        XCTAssertNil(ObjectTags.queryRange(in: "Cole@example.com", selection: NSRange(location: 12, length: 0), objects: [cole]))
        let source = "Cole ging.\nDann @Co"
        let trigger = (source as NSString).range(of: "@Co")
        XCTAssertNil(ObjectTags.existingMention(in: source, object: cole, beside: trigger))
    }
    @MainActor func testCommandClickOpensNearbyDetailsWithoutChangingProseOrSelection() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
        scroll.documentView = view; window.contentView?.addSubview(scroll); window.orderFront(nil)
        let session = ObjectTagSession(view: view); view.tagSession = session
        defer { session.close(); window.orderOut(nil) }
        let object = StoryProject.example().tagObjects[0]; session.objects = [object]
        let text = NSMutableAttributedString(string: "She met Mara Vale at the shore.", attributes: WritingStyle.attributes)
        let range = (text.string as NSString).range(of: "Mara Vale")
        text.addAttribute(.link, value: object.reference.url, range: range)
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: range.location, length: 4))
        view.textStorage?.setAttributedString(text)
        view.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        var fullProfileOpened = false; session.open = { _ in fullProfileOpened = true }
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let bounds = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = NSPoint(x: bounds.minX + view.textContainerOrigin.x + 3, y: bounds.midY + view.textContainerOrigin.y)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertTrue(session.detailsVisible)
        XCTAssertEqual(session.inspectedReference, object.reference)
        XCTAssertFalse(fullProfileOpened, "Clicking a tag should leave the full profile closed")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertTrue(view.attributedString().isEqual(to: text))
        let anchor = try XCTUnwrap(session.detailsAnchor)
        XCTAssertEqual(anchor.minX, bounds.minX + view.textContainerOrigin.x, accuracy: 1)
        XCTAssertEqual(anchor.width, bounds.width, accuracy: 1, "Formatting changes must not shorten the tagged anchor")
        XCTAssertNil(session.reference(at: NSPoint(x: point.x, y: point.y + 180)))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        XCTAssertFalse(session.detailsVisible)
        scroll.contentView.scroll(to: .zero)
        XCTAssertTrue(session.showDetails(atCharacter: range.location))
        view.insertText("!", replacementRange: NSRange(location: text.length, length: 0))
        XCTAssertFalse(session.detailsVisible, "Typing, pasting, and dictation must dismiss stale anchors")
    }

    @MainActor func testPlainClickOnTagPlacesCaretLikeOrdinaryText() throws {
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let session = ObjectTagSession(view: view); view.tagSession = session
        let object = StoryProject.example().tagObjects[0]; session.objects = [object]
        let text = NSMutableAttributedString(string: "She met Mara Vale at the shore.", attributes: WritingStyle.attributes)
        let range = (text.string as NSString).range(of: "Mara Vale")
        text.addAttribute(.link, value: object.reference.url, range: range)
        view.textStorage?.setAttributedString(text)
        let chapter = Chapter()
        let editor = RichTextEditor(chapter: .constant(chapter), controller: EditorController(), language: "auto", onError: { _ in })
        let coordinator = editor.makeCoordinator()
        XCTAssertTrue(coordinator.textView(view, clickedOnLink: object.reference.url, at: range.location + 2))
        XCTAssertEqual(view.selectedRange(), NSRange(location: range.location + 2, length: 0))
        XCTAssertFalse(session.detailsVisible)
        XCTAssertTrue(view.attributedString().isEqual(to: text))
    }

    @MainActor func testTagHighlightsHugEachLineOfAWrappedTag() throws {
        let storage = NSTextStorage(), manager = ManuscriptLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 150, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        let text = NSMutableAttributedString(string: "Then Annabelle Montgomery-Whitfield arrived.", attributes: WritingStyle.attributes)
        let range = (text.string as NSString).range(of: "Annabelle Montgomery-Whitfield")
        text.addAttribute(.link, value: reference.url, range: range)
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 4))
        storage.setAttributedString(text)
        manager.ensureLayout(for: container)
        let highlights = manager.tagHighlights(in: NSRange(location: 0, length: text.length))
        XCTAssertGreaterThanOrEqual(highlights.count, 2, "A wrapped tag gets one highlight per line")
        XCTAssertTrue(highlights.allSatisfy { $0.kind == .character })
        let font = try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        for highlight in highlights {
            let line = manager.lineFragmentRect(forGlyphAt: manager.glyphIndex(for: highlight.rect.origin, in: container), effectiveRange: nil)
            XCTAssertLessThan(highlight.rect.height, line.height, "Highlights fit the letters, not the line spacing")
            XCTAssertGreaterThanOrEqual(highlight.rect.height, font.ascender - font.descender)
        }
        manager.showsTags = false
        XCTAssertTrue(manager.tagHighlights(in: NSRange(location: 0, length: text.length)).isEmpty)
    }

    @MainActor func testWrappedAndMissingTagsRemainInspectable() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view); window.orderFront(nil)
        let session = ObjectTagSession(view: view); view.tagSession = session
        defer { session.close(); window.orderOut(nil) }
        let reference = ProjectTagReference(kind: .world, objectID: UUID())
        let text = NSMutableAttributedString(string: "The Academy of Cartography and the Navigation of Distant Seas", attributes: WritingStyle.attributes)
        text.addAttribute(.link, value: reference.url, range: NSRange(location: 0, length: text.length))
        view.textStorage?.setAttributedString(text); view.layoutSubtreeIfNeeded()
        XCTAssertTrue(session.showDetails(atCharacter: 0))
        let first = try XCTUnwrap(session.detailsAnchor)
        XCTAssertTrue(session.showDetails(atCharacter: text.length - 1))
        let last = try XCTUnwrap(session.detailsAnchor)
        XCTAssertGreaterThan(last.minY, first.minY, "Wrapped tags should point to the clicked line")
        XCTAssertEqual(session.inspectedReference, reference, "Deleted objects should still show an explanatory bubble")
        XCTAssertTrue(session.detailsVisible)
        XCTAssertFalse(session.showDetails(atCharacter: text.length))
        XCTAssertFalse(session.showDetails(atCharacter: -1))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertFalse(session.detailsVisible)
        XCTAssertNil(session.inspectedReference)
        XCTAssertTrue(view.attributedString().isEqual(to: text))
    }

}

final class DimPaperDisplayTests: XCTestCase {
    func testDarkTextIsLightenedWhenDrawnIncludingNewText() {
        let storage = NSTextStorage(), manager = ManuscriptLayoutManager()
        storage.addLayoutManager(manager)
        let text = NSMutableAttributedString(string: "Plain ", attributes: [.foregroundColor: NSColor.black])
        text.append(NSAttributedString(string: "Red", attributes: [.foregroundColor: NSColor.systemRed]))
        storage.setAttributedString(text)
        storage.append(NSAttributedString(string: " typed")) // New text without any color of its own.
        func display(at index: Int, toScreen: Bool = true) -> (NSColor?, NSRange) {
            var range = NSRange(location: 0, length: storage.length)
            let attributes = manager.layoutManager(manager, shouldUseTemporaryAttributes: [:], forDrawingToScreen: toScreen, atCharacterIndex: index, effectiveRange: &range)
            return (attributes?[.foregroundColor] as? NSColor, range)
        }
        XCTAssertNil(display(at: 0).0, "Ordinary paper keeps the text's own colors")
        manager.dimsText = true
        XCTAssertEqual(display(at: 0).0, ManuscriptLayoutManager.dimTextColor)
        XCTAssertEqual(display(at: 0).1, NSRange(location: 0, length: 6), "Substitution stops where the color changes")
        XCTAssertNil(display(at: 7).0, "Bright colors stay as written")
        XCTAssertEqual(display(at: 10).0, ManuscriptLayoutManager.dimTextColor)
        XCTAssertNil(display(at: 0, toScreen: false).0, "Printing uses the real colors")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.black, "Saved text is unchanged")
    }
}
