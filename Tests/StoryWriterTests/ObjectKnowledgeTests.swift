import XCTest
import AppKit
import Combine
@testable import StoryWriter

final class ObjectKnowledgeTests: XCTestCase {
    private func story() -> StoryProject {
        var project = StoryProject.new(title: "Objects", kind: .story)
        project.characters = [Character(name: "Maya"), Character(name: "Theo")]
        project.chapters[0].plainText = "Maya sees the key. Theo takes it."
        project.worldNotes = [WorldNote(title: "Brass key", category: .object, aliases: ["key"])]
        return project
    }
    func testKnowledgeAndPossessionAreIndependentAndFollowCursor() throws {
        var project = story()
        let worldID = project.worldNotes[0].id, chapterID = project.chapters[0].id
        let knows = try project.useContinuityChoice(worldID, category: .knowledge)
        let carries = try project.useContinuityChoice(worldID, category: .possession)
        XCTAssertNotEqual(knows.id, carries.id)
        XCTAssertEqual(knows.worldObjectID, carries.worldObjectID)
        try project.recordContinuity(itemID: knows.id, characterID: project.characters[0].id, action: .learns, chapterID: chapterID, range: NSRange(location: 0, length: 18))
        try project.recordContinuity(itemID: carries.id, characterID: project.characters[1].id, action: .gets, chapterID: chapterID, range: NSRange(location: 19, length: 13))
        let before = Continuity.objectStates(in: project, worldID: worldID, chapterID: chapterID, offset: 17)
        XCTAssertNil(before[0].knowledge)
        let after = Continuity.objectStates(in: project, worldID: worldID, chapterID: chapterID, offset: 32)
        XCTAssertEqual(after[0].knowledgeLabel, "Knows about it")
        XCTAssertNil(after[0].possession)
        XCTAssertNil(after[1].knowledge)
        XCTAssertEqual(after[1].possession?.latest.event.action, .gets)
        XCTAssertThrowsError(try project.recordContinuity(itemID: knows.id, characterID: project.characters[0].id, action: .learns, chapterID: chapterID, range: NSRange(location: 32, length: 0)))
        let reused = try project.createContinuityItem(name: "key", category: .knowledge)
        XCTAssertEqual(reused.id, knows.id)
        try project.recordContinuity(itemID: knows.id, characterID: project.characters[0].id, action: .forgets, chapterID: chapterID, range: NSRange(location: 32, length: 0))
        XCTAssertEqual(Continuity.objectStates(in: project, worldID: worldID, chapterID: chapterID, offset: 32)[0].knowledgeLabel, "Forgotten")
        XCTAssertNil(Continuity.objectStates(in: project, worldID: worldID, chapterID: chapterID, offset: 0)[0].knowledge)
    }
    func testPlansDetachedSourcesAndDetailsDoNotEstablishObjectAwareness() throws {
        var project = story()
        let worldID = project.worldNotes[0].id, chapterID = project.chapters[0].id
        let item = try project.useContinuityChoice(worldID, category: .knowledge)
        let detail = try project.createContinuityItem(name: "Key opens the vault", category: .knowledge, parentID: item.id)
        XCTAssertFalse(project.continuityChoices(for: .knowledge, parentID: item.id).contains { $0.id == worldID })
        try project.recordContinuity(itemID: detail.id, characterID: project.characters[0].id, action: .learns, chapterID: nil)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[1].id, action: .learns, chapterID: chapterID, range: NSRange(location: 18, length: 0), planned: true)
        XCTAssertTrue(Continuity.objectStates(in: project, worldID: worldID, chapterID: chapterID, offset: 32).allSatisfy { $0.knowledge == nil })
        project.chapters[0].continuityEvents?[0].planned = false
        project.chapters[0].continuityEvents?[0].detached = true
        XCTAssertNil(Continuity.objectStates(in: project, worldID: worldID, chapterID: chapterID, offset: 32)[1].knowledge)
    }
    func testObjectCreationReusesAliasesAndDoesNotGrantKnowledge() throws {
        var project = story()
        let reused = try project.addStoryObject(name: " KEY ")
        XCTAssertEqual(reused.id, project.worldNotes[0].id)
        project.characters.append(Character(name: "Letter"))
        let created = try project.addStoryObject(name: "Letter", summary: "A sealed envelope")
        XCTAssertEqual(created.category, .object)
        XCTAssertEqual(created.summary, "A sealed envelope")
        XCTAssertEqual(project.worldNotes.count, 2)
        XCTAssertNil(project.continuityItems)
        XCTAssertTrue(Continuity.objectStates(in: project, worldID: created.id, chapterID: project.chapters[0].id, offset: 32).allSatisfy { $0.knowledge == nil && $0.possession == nil })
        project.worldNotes.append(WorldNote(title: "key", category: .object))
        XCTAssertThrowsError(try project.addStoryObject(name: "key"))
    }
    @MainActor func testLinkedKnowledgeAndPossessionSurviveSaveAndPortableImport() throws {
        var project = story()
        let worldID = project.worldNotes[0].id
        for action in [ContinuityAction.learns, .gets] {
            let item = try project.useContinuityChoice(worldID, category: action.category)
            try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: action, chapterID: nil)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ObjectKnowledge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        store.projects = [project]; store.update(project.id) { $0 = project }
        XCTAssertTrue(store.saveNow())
        let portable = root.appendingPathComponent("Objects.storywriter")
        try store.exportPackage(project.id, to: portable)
        store.importPackage(portable)
        let restored = try XCTUnwrap(store.selectedProject)
        let row = Continuity.objectStates(in: restored, worldID: worldID, chapterID: restored.chapters[0].id, offset: 0)[0]
        XCTAssertEqual(row.knowledgeLabel, "Knows about it")
        XCTAssertEqual(row.possession?.latest.event.action, .gets)
        XCTAssertEqual(restored.continuityItems?.count, 2)
    }
    @MainActor func testCursorPublishesWhileMovingAndWhenChapterChangesAtSameOffset() async throws {
        let editor = EditorController(), view = NSTextView()
        view.string = String(repeating: "x", count: 100)
        editor.textView = view; editor.chapterID = UUID()
        var publications = 0
        let subscription = editor.objectWillChange.sink { publications += 1 }
        for offset in 1...20 { view.setSelectedRange(NSRange(location: offset, length: 0)); editor.refresh() }
        XCTAssertEqual(editor.selectionRange.location, 20, "Recording actions use the current position immediately")
        // Wait for the observable result: a busy CI main actor can run the
        // 16 ms settle task later than a fixed sleep.
        func waitForPublication(after count: Int) async throws {
            let deadline = Date().addingTimeInterval(3)
            while publications <= count && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let initial = publications
        try await waitForPublication(after: initial)
        XCTAssertGreaterThan(publications, initial)
        let settled = publications
        editor.chapterID = UUID(); editor.refresh()
        try await waitForPublication(after: settled)
        XCTAssertGreaterThan(publications, settled)
        withExtendedLifetime(subscription) {}
    }
    func testObjectSnapshotCostWithLongHistory() throws {
        var project = story()
        project.characters = (0..<20).map { Character(name: "Character \($0)") }
        project.worldNotes = (0..<200).map { WorldNote(title: "Object \($0)", category: .object) }
        let items = project.worldNotes.map { ContinuityItem(name: $0.title, category: .knowledge, worldObjectID: $0.id) }
        project.continuityItems = items
        project.chapters = (0..<25).map { index in
            var chapter = Chapter(title: "Chapter \(index)", plainText: String(repeating: "A passage. ", count: 1000))
            chapter.continuityEvents = (0..<300).map { event in
                ContinuityEvent(itemID: items[event % items.count].id, characterID: project.characters[event % 20].id, action: .learns, start: event * 10)
            }
            return chapter
        }
        let start = CFAbsoluteTimeGetCurrent()
        for offset in stride(from: 500, to: 10000, by: 500) {
            let states = Continuity.objectStates(in: project, worldID: project.worldNotes[0].id, chapterID: project.chapters[24].id, offset: offset)
            XCTAssertEqual(states.count, 20)
            XCTAssertEqual(states[0].knowledgeLabel, "Knows about it")
        }
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 19
        print(String(format: "Object snapshot, 7,500 events / 200 objects / 20 characters: %.2f ms", milliseconds))
        XCTAssertLessThan(milliseconds, 50, "Cursor tracking should not introduce visible lag")
    }

    @MainActor func testAddingObjectTagPreservesWordsFormattingAndUndo() throws {
        let editor = EditorController(), view = ManuscriptTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; view.allowsUndo = true; window.makeFirstResponder(view)
        defer { window.contentView = nil }
        let chapterID = UUID(), reference = ProjectTagReference(kind: .world, objectID: UUID())
        let original = NSAttributedString(string: "Maya holds the key.", attributes: [.font: NSFont.boldSystemFont(ofSize: 17)])
        view.textStorage?.setAttributedString(original)
        editor.textView = view; editor.chapterID = chapterID
        let range = (view.string as NSString).range(of: "key")
        XCTAssertTrue(editor.tagPassage(reference, chapterID: chapterID, range: range, expectedText: view.string))
        XCTAssertEqual(view.string, original.string)
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)), reference)
        XCTAssertEqual(view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont, NSFont.boldSystemFont(ofSize: 17))
        XCTAssertNil(view.textStorage?.attribute(.link, at: NSMaxRange(range), effectiveRange: nil))
        XCTAssertFalse(editor.tagPassage(reference, chapterID: chapterID, range: range, expectedText: "stale"))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, original.string)
        XCTAssertNil(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil))
    }
}
