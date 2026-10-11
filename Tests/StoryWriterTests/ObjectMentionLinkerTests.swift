import AppKit
import XCTest
@testable import StoryWriter

final class ObjectMentionLinkerTests: XCTestCase {
    private func linked(_ text: NSAttributedString, _ name: String) -> ProjectTagReference? {
        let range = (text.string as NSString).range(of: name)
        return ProjectTagReference.from(text.attribute(.link, at: range.location, effectiveRange: nil))
    }

    @MainActor func testCreationLinksEarlierMentionsAcrossChaptersAndPortableCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MentionLinks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Mentions", kind: .story)
        let prose = "🌊 Elisa found the Silver key at Ferry dock. Elisa kept the Silver key."
        var chapter = Chapter(title: "First")
        try chapter.setText(NSAttributedString(string: prose, attributes: [.font: NSFont.boldSystemFont(ofSize: 19)]))
        let originalFont = chapter.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        var second = Chapter(title: "Second")
        try second.setText(NSAttributedString(string: "Ferry dock was empty. Elisa held the Silver key."))
        store.update(id) { $0.chapters = [chapter, second] }
        let elisa = try XCTUnwrap(store.createObject(named: "Elisa", kind: .character, projectID: id))
        let key = try XCTUnwrap(store.createObject(named: "Silver key", kind: .item, projectID: id))
        let dock = try XCTUnwrap(store.createObject(named: "Ferry dock", kind: .location, projectID: id))
        let project = try XCTUnwrap(store.project(id))
        XCTAssertEqual(project.chapters[0].plainText, prose)
        for chapter in project.chapters {
            XCTAssertEqual(linked(chapter.attributedText, "Elisa"), elisa)
            XCTAssertEqual(linked(chapter.attributedText, "Silver key"), key)
            XCTAssertEqual(linked(chapter.attributedText, "Ferry dock"), dock)
        }
        let lastKey = (prose as NSString).range(of: "Silver key", options: .backwards)
        XCTAssertEqual(ProjectTagReference.from(project.chapters[0].attributedText.attribute(.link, at: lastKey.location, effectiveRange: nil)), key)
        XCTAssertEqual(project.chapters[0].attributedText.attribute(.font, at: lastKey.location, effectiveRange: nil) as? NSFont, originalFont)
        XCTAssertNil(project.continuityItems, "Mention links do not invent character knowledge or possession")
        let portable = root.appendingPathComponent("Mentions.storywriter")
        try store.exportPackage(id, to: portable)
        let imported = try ProjectStore.readPackage(portable)
        XCTAssertEqual(linked(imported.chapters[1].attributedText, "Silver key"), key)
        XCTAssertEqual(linked(imported.chapters[0].attributedText, "Ferry dock"), dock)
    }

    @MainActor func testPlanningProfilesLinkWhenNamedAndWhenAliasesAreAdded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanningMentions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "World", kind: .story)
        store.update(id) { $0.chapters[0].plainText = "Mara Vale met Mara at Old Harbor. Captain waited. The Guild watched." }
        let character = Character(), note = WorldNote(category: .location)
        store.update(id) { $0.characters.append(character); $0.worldNotes.append(note) }
        store.update(id) { $0.characters[0].name = "Mara Vale"; $0.worldNotes[0].title = "Old Harbor" }
        XCTAssertTrue(store.saveNow())
        let mara = ProjectTagReference(kind: .character, objectID: character.id)
        var text = try XCTUnwrap(store.project(id)).chapters[0].attributedText
        XCTAssertEqual(linked(text, "Mara Vale"), mara)
        let firstName = (text.string as NSString).range(of: "Mara", options: .backwards)
        XCTAssertEqual(ProjectTagReference.from(text.attribute(.link, at: firstName.location, effectiveRange: nil)), mara)
        XCTAssertNil(linked(text, "Captain"))
        store.update(id) { $0.characters[0].aliases = ["Captain"]; $0.worldNotes.append(WorldNote(title: "The Guild", category: .culture)) }
        XCTAssertTrue(store.saveNow())
        text = try XCTUnwrap(store.project(id)).chapters[0].attributedText
        XCTAssertEqual(linked(text, "Captain"), mara)
        XCTAssertEqual(linked(text, "The Guild"), ProjectTagReference(kind: .world, objectID: store.project(id)!.worldNotes[1].id))
        // Removing a tag remains an explicit writer choice until names change again.
        let unlinked = NSMutableAttributedString(attributedString: text)
        unlinked.removeAttribute(.link, range: (text.string as NSString).range(of: "Captain"))
        store.updateWhileTyping(id) { $0.chapters[0].setEditingText(unlinked) }
        store.update(id) { $0.characters[0].notes = "A note" }
        XCTAssertNil(linked(store.project(id)!.chapters[0].attributedText, "Captain"))
    }

    func testMatchingHonorsAmbiguityLongestNamesUnicodeAndLinks() throws {
        var project = StoryProject.new(title: "Matches", kind: .story)
        project.characters = [Character(name: "Anna Berg"), Character(name: "Anna Lind"), Character(name: "Will"), Character(name: "Zoë")]
        project.worldNotes = [WorldNote(title: "Old Harbor", aliases: ["Harbor"]), WorldNote(title: "Harbor Inn"), WorldNote(title: "Key", category: .object), WorldNote(title: "Door", aliases: ["Key"])]
        let names = ObjectMentionLinker.names(in: project)
        let text = NSMutableAttributedString(string: "🌊 Anna Berg saw Anna. I will ask Will. Zoë met Zoëly. Old\tHarbor, Harbor Inn, Harbor. Key. @Zoë Zoë@example.org. Old\nHarbor. Zoë")
        let website = URL(string: "https://example.org")!
        let finalZoe = (text.string as NSString).range(of: "Zoë", options: .backwards)
        text.addAttribute(.link, value: website, range: finalZoe)
        let matches = ObjectMentionLinker(names: names).matches(in: text, references: Set(names.keys))
        let labels = matches.map { (text.string as NSString).substring(with: $0.range) }
        XCTAssertEqual(labels, ["Anna Berg", "Will", "Zoë", "Old\tHarbor", "Harbor Inn", "Harbor", "Harbor"])
        let harbor = ProjectTagReference(kind: .world, objectID: project.worldNotes[0].id)
        let harborOnly = ObjectMentionLinker(names: names).matches(in: text, references: [harbor])
        XCTAssertFalse(harborOnly.contains { (text.string as NSString).substring(with: $0.range) == "Harbor Inn" })
        XCTAssertFalse(harborOnly.contains { $0.range.location == (text.string as NSString).range(of: "Harbor Inn").location })
        XCTAssertEqual(text.attribute(.link, at: finalZoe.location, effectiveRange: nil) as? URL, website)
    }

    @MainActor func testTypingAProfileNameDoesNotLinkUnfinishedWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettledMentions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Settled names", kind: .story)
        store.update(id) {
            $0.chapters[0].setEditingText(NSAttributedString(string: "The sun rose. The Guild arrived."))
            $0.worldNotes.append(WorldNote(category: .culture))
        }
        store.update(id) { $0.worldNotes[0].title = "The" }
        XCTAssertNil(linked(store.project(id)!.chapters[0].attributedText, "The sun"))
        try await Task.sleep(nanoseconds: 100_000_000)
        store.update(id) { $0.worldNotes[0].title = "The Guild" }
        // Wait for the observable result: a busy CI main actor can start the
        // 600 ms debounce later than the test's own sleep.
        let deadline = Date().addingTimeInterval(3)
        while linked(store.project(id)!.chapters[0].attributedText, "The Guild") == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let chapter = store.project(id)!.chapters[0]
        XCTAssertNil(linked(chapter.attributedText, "The sun"))
        XCTAssertEqual(linked(chapter.attributedText, "The Guild"), ProjectTagReference(kind: .world, objectID: store.project(id)!.worldNotes[0].id))
    }

    @MainActor func testLiveCreationDoesNotLoseEarlierTagsWhenAtQueryIsInserted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMentions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Live", kind: .story)
        let view = ManuscriptTextView(), editor = EditorController()
        let session = ObjectTagSession(view: view); view.tagSession = session
        let prose = "Elisa found Elisa. Then @Elisa"
        view.textStorage?.setAttributedString(NSAttributedString(string: prose, attributes: WritingStyle.attributes))
        view.setSelectedRange(NSRange(location: prose.utf16.count, length: 0))
        store.update(id) { $0.chapters[0].setEditingText(view.attributedString()) }
        let chapterID = store.project(id)!.chapters[0].id
        editor.textView = view; editor.chapterID = chapterID
        let delegate = SavingDelegate { store.updateWhileTyping(id) { $0.chapters[0].setEditingText(view.attributedString()) } }
        view.delegate = delegate
        session.create = { name, kind in
            let reference = store.createObject(named: name, kind: kind, projectID: id)
            if let reference { editor.linkExistingMentions(reference, in: store.project(id)!) }
            return reference
        }
        session.refreshSuggestions(); session.createNew(.character)
        let reference = ProjectTagReference(kind: .character, objectID: store.project(id)!.characters[0].id)
        XCTAssertEqual(view.string, "Elisa found Elisa. Then Elisa")
        let saved = store.project(id)!.chapters[0].attributedText
        for range in StorySearch.ranges("Elisa", in: view.string) {
            XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)), reference)
            XCTAssertEqual(ProjectTagReference.from(saved.attribute(.link, at: range.location, effectiveRange: nil)), reference)
        }
        XCTAssertEqual(view.selectedRange().location, view.string.utf16.count)
        withExtendedLifetime(delegate) {}
    }

    @MainActor func testAttributeMergePreservesSelectionTypingAndUndo() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(); view.allowsUndo = true; window.contentView = view
        window.makeFirstResponder(view)
        defer { window.contentView = nil }
        view.undoManager?.groupsByEvent = false
        view.undoManager?.beginUndoGrouping()
        view.insertText("Mara found Mara.", replacementRange: NSRange(location: 0, length: 0))
        view.undoManager?.endUndoGrouping()
        let selection = NSRange(location: 11, length: 4)
        view.setSelectedRange(selection)
        let incoming = NSMutableAttributedString(attributedString: view.attributedString())
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        for range in StorySearch.ranges("Mara", in: incoming.string) { incoming.addAttribute(.link, value: reference.url, range: range) }
        let typing = view.typingAttributes
        XCTAssertTrue(view.mergeAddedObjectTags(from: incoming))
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.typingAttributes[.font] as? NSFont, typing[.font] as? NSFont)
        XCTAssertEqual(linked(view.attributedString(), "Mara"), reference)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "Mara found Mara.")
        XCTAssertNil(linked(view.attributedString(), "Mara"))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "", "Earlier typing remains in the undo history")
    }
}

@MainActor private final class SavingDelegate: NSObject, NSTextViewDelegate {
    var save: () -> Void
    init(save: @escaping () -> Void) { self.save = save }
    func textDidChange(_ notification: Notification) { save() }
}
