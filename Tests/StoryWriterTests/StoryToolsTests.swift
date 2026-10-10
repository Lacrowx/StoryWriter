import XCTest
import AppKit
@testable import StoryWriter

final class StoryToolsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoryTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor func testScenesPreserveFormattingTagsAndCommentsWhenReordered() throws {
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        let text = NSMutableAttributedString(string: "Ada waits.\n\nBen arrives.", attributes: WritingStyle.attributes)
        text.addAttribute(.link, value: reference.url, range: NSRange(location: 0, length: 3))
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 12, length: 3))
        var chapter = Chapter(title: "Meeting"); try chapter.setText(text)
        try chapter.splitScene(at: 12)
        try chapter.addComment(range: NSRange(location: 0, length: 3), note: "Ada's entrance")
        try chapter.addComment(range: NSRange(location: 12, length: 3), note: "Ben's entrance")
        let second = chapter.orderedScenes[1]
        try chapter.moveScene(second.id, offset: -1)
        XCTAssertEqual(chapter.plainText, "Ben arrives.\n\nAda waits.\n\n")
        XCTAssertEqual(chapter.orderedScenes.map(\.start), [0, 14])
        let comments = chapter.comments!
        XCTAssertEqual(comments[0].start, 14)
        XCTAssertEqual(comments[1].start, 0)
        XCTAssertEqual(ProjectTagReference.from(chapter.attributedText.attribute(.link, at: 14, effectiveRange: nil)), reference)
        let font = try XCTUnwrap(chapter.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        try chapter.mergeScene(chapter.orderedScenes[1].id)
        XCTAssertEqual(chapter.orderedScenes.count, 1)
        XCTAssertTrue(chapter.plainText.contains("Ada waits."))
    }
    @MainActor func testUnicodeAnchorsRebaseAndChangedQuotesDetach() throws {
        var chapter = Chapter(); try chapter.setText(NSAttributedString(string: "👩🏽‍💻 Ada waits.\n\nBen arrives."))
        let ben = (chapter.plainText as NSString).range(of: "Ben")
        try chapter.addComment(range: ben, note: "Check arrival")
        try chapter.splitScene(at: ben.location)
        let updated = "An opening. " + chapter.plainText
        try chapter.setText(NSAttributedString(string: updated))
        XCTAssertEqual(chapter.comments?.first?.start, ben.location + 12)
        XCTAssertEqual(chapter.scenes?.last?.start, ben.location + 12)
        XCTAssertFalse(chapter.comments!.first!.detached)
        try chapter.setText(NSAttributedString(string: updated.replacingOccurrences(of: "Ben", with: "Benjamin")))
        XCTAssertTrue(chapter.comments!.first!.detached)
        XCTAssertEqual(chapter.comments!.first!.note, "Check arrival")
        var emoji = Chapter(); try emoji.setText(NSAttributedString(string: "👩🏽‍💻 then Ada"))
        XCTAssertThrowsError(try emoji.splitScene(at: 1))
    }
    @MainActor func testCollapsedSceneBoundariesNeverDuplicateText() throws {
        var chapter = Chapter(); try chapter.setText(NSAttributedString(string: "A\n\nB\n\nC"))
        try chapter.splitScene(at: 3); try chapter.splitScene(at: 6)
        try chapter.setText(NSAttributedString(string: "A\n\nC"))
        let total = chapter.orderedScenes.reduce(0) { $0 + chapter.range(of: $1).length }
        XCTAssertEqual(total, chapter.plainText.utf16.count)
        let last = chapter.orderedScenes.last!
        try chapter.moveScene(last.id, offset: -1)
        XCTAssertEqual(chapter.plainText.filter { $0 == "A" }.count, 1)
        XCTAssertEqual(chapter.plainText.filter { $0 == "C" }.count, 1)
    }
    @MainActor func testSearchBacklinksAliasesAndWordBoundaries() throws {
        var project = StoryProject.new(title: "Search", kind: .story)
        let character = Character(name: "Mara Vale", aliases: ["Mara", "Cartographer"])
        project.characters = [character]
        let ref = ProjectTagReference(kind: .character, objectID: character.id)
        let text = NSMutableAttributedString(string: "Mara watched. Mara Vale left. Marabelle stayed. Cartographer returned.")
        text.addAttribute(.link, value: ref.url, range: NSRange(location: 14, length: 9))
        try project.chapters[0].setText(text)
        project.characters[0].notes = "A red notebook"
        project.worldNotes = [WorldNote(title: "Harbor", details: "A red door")]
        project.sources = [ReferenceSource(title: "Research", notes: "A red scarf")]
        let results = StorySearch.results(in: project, query: "red")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(Set(results.map { $0.destination.kind.rawValue }), ["character", "world", "reference"])
        let backlinks = StorySearch.backlinks(in: project, to: ref)
        XCTAssertEqual(backlinks.count, 3)
        XCTAssertEqual(backlinks.filter { $0.category == "Tagged" }.count, 1)
        XCTAssertTrue(ObjectTags.matches(project.tagObjects, query: "Cartographer").contains { $0.reference == ref })
        XCTAssertTrue(ObjectDiscovery.known("Cartographer", objects: project.tagObjects, ignored: []))
        for result in backlinks { XCTAssertTrue(NSMaxRange(result.destination.range!) <= text.length) }
    }
    @MainActor func testOldProjectAndNewMetadataPortableRoundTrip() throws {
        let root = try directory()
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Metadata", kind: .story)
        let old = try Data(contentsOf: store.packageURL(id).appendingPathComponent("project.json"))
        XCTAssertNil(try ProjectStore.decode(old).chapters[0].scenes)
        var chapter = store.project(id)!.chapters[0]
        try chapter.setText(NSAttributedString(string: "First.\n\nSecond.")); try chapter.splitScene(at: 8)
        chapter.scenes?[1].timelineOrder = -2; chapter.scenes?[1].storyTime = "Yesterday"
        try chapter.addComment(range: NSRange(location: 0, length: 6), note: "Revisit")
        store.update(id) { $0.chapters[0] = chapter; $0.characters = [Character(name: "Ada", aliases: ["A"])] }
        try store.namedCheckpoint(id, name: "Before ending")
        XCTAssertEqual(store.revisions(id).first?.name, "Before ending")
        let target = root.appendingPathComponent("copy.storywriter"); try store.exportPackage(id, to: target)
        let reopened = ProjectStore(root: root.appendingPathComponent("other"), createExample: false); reopened.importPackage(target)
        let copy = try XCTUnwrap(reopened.selectedProject)
        XCTAssertEqual(copy.chapters[0].scenes, chapter.scenes)
        XCTAssertEqual(copy.chapters[0].comments?.first?.note, chapter.comments?.first?.note)
        XCTAssertEqual(copy.chapters[0].comments?.first?.range, chapter.comments?.first?.range)
        XCTAssertEqual(copy.characters[0].aliases, ["A"])
    }
    @MainActor func testSelectiveRecoveryPreservesOtherChaptersAndFormatting() throws {
        let store = ProjectStore(root: try directory(), createExample: false)
        let id = store.create(title: "Recovery", kind: .story)
        var chapter = store.project(id)!.chapters[0]
        let original = NSAttributedString(string: "Original.", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        try chapter.setText(original)
        store.update(id) { $0.chapters[0] = chapter; $0.chapters.append(Chapter(title: "Other chapter")) }
        try store.namedCheckpoint(id, name: "Original")
        let revision = store.revisions(id).first!
        store.update(id) { $0.chapters[0].plainText = "Changed."; $0.chapters[0].richText = Data() }
        let saved = try store.revisionProject(revision, projectID: id)
        try store.recoverChapter(saved.chapters[0], projectID: id)
        XCTAssertEqual(store.project(id)!.chapters[1].title, "Other chapter")
        let otherID = store.project(id)!.chapters[1].id
        let range = try store.recoverPassage(original, to: otherID, projectID: id)
        XCTAssertEqual(range, NSRange(location: 0, length: 9))
        let font = try XCTUnwrap(store.project(id)!.chapters[1].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(store.revisions(id).contains { (try? store.revisionProject($0, projectID: id).chapters[0].plainText) == "Changed." })
    }
    @MainActor func testPortableBackupIsCompleteAndFailuresPreserveLibrary() async throws {
        let root = try directory(), library = root.appendingPathComponent("library"), backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PortableBackup.validate(folder: library.appendingPathComponent("nested"), library: library))
        XCTAssertThrowsError(try PortableBackup.validate(folder: root, library: library))
        let store = ProjectStore(root: library, createExample: false), id = store.create(title: "Backup", kind: .story)
        let file = root.appendingPathComponent("source.txt"); try "Reference".write(to: file, atomically: true, encoding: .utf8); store.importFiles([file], projectID: id)
        try store.configureBackup(id, folder: backups)
        let task = try XCTUnwrap(store.backupTasks[id]); await task.value
        XCTAssertNotNil(store.backupConfigurations[id]?.lastSuccess)
        let copies = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "storywriter" }
        XCTAssertEqual(copies.count, 1)
        let snapshot = try ProjectStore.readPackage(copies[0])
        XCTAssertEqual(snapshot.id, id)
        XCTAssertEqual(try String(contentsOf: copies[0].appendingPathComponent(snapshot.sources[0].relativePath!)), "Reference")
        XCTAssertThrowsError(try PortableBackup.copy(package: store.packageURL(id), to: root.appendingPathComponent("missing")))
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).title, "Backup")
        store.update(id) { $0.premise = "Latest saved version" }
        XCTAssertTrue(store.saveNow())
        XCTAssertNotNil(store.backupTasks[id])
        store.scheduleBackup(id, immediately: true)
        await store.backupTasks[id]?.value
        let latest = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.pathExtension == "storywriter" }
        XCTAssertEqual(latest.count, 2)
        XCTAssertTrue(try latest.map { try ProjectStore.readPackage($0).premise }.contains("Latest saved version"))
        store.disableBackup(id)
        UserDefaults.standard.removeObject(forKey: store.backupDefaultsKey)
    }
    @MainActor func testUniqueFirstNamesAreBacklinkedAndAmbiguousNamesAreNot() throws {
        var project = StoryProject.new(title: "Names", kind: .story)
        let mara = Character(name: "Mara Vale")
        project.characters = [mara]
        try project.chapters[0].setText(NSAttributedString(string: "Mara returned. Marabelle waited."))
        let reference = ProjectTagReference(kind: .character, objectID: mara.id)
        XCTAssertEqual(StorySearch.backlinks(in: project, to: reference).count, 1)
        project.characters.append(Character(name: "Mara Reed"))
        XCTAssertTrue(StorySearch.backlinks(in: project, to: reference).isEmpty)
    }
    func testRevisionComparisonShowsInsertedAndRemovedParagraphs() {
        let lines = RevisionComparison.lines(old: "Unchanged\nOld ending", new: "Unchanged\nNew ending")
        XCTAssertEqual(lines.filter { $0.change == -1 }.map(\.text), ["Old ending"])
        XCTAssertEqual(lines.filter { $0.change == 1 }.map(\.text), ["New ending"])
        XCTAssertEqual(lines.filter { $0.change == 0 }.map(\.text), ["Unchanged"])
    }
}
