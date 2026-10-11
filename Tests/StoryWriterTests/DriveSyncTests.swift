import XCTest
import AppKit
@testable import StoryWriter

final class DriveSyncTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoryWriterSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func story(_ text: String = "Mara sees a red boat.\n\nElias opens the gate.") throws -> StoryProject {
        var story = StoryProject.new(title: "Island", kind: .story)
        try story.chapters[0].setText(NSAttributedString(string: text, attributes: WritingStyle.attributes))
        return story
    }
    private func edit(_ project: inout StoryProject, from: String, to: String) throws {
        let text = NSMutableAttributedString(attributedString: project.chapters[0].attributedText)
        let range = (text.string as NSString).range(of: from)
        XCTAssertNotEqual(range.location, NSNotFound)
        text.replaceCharacters(in: range, with: to)
        try project.chapters[0].setText(text)
    }
    private func checked(_ result: ProjectMergeResult) throws -> StoryProject {
        try ProjectStore.decode(DriveSyncTransport.encode(result.project))
    }
    @MainActor private func pair() async throws -> (ProjectStore, ProjectStore, UUID, URL) {
        let root = try directory(), folder = root.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = ProjectStore(root: root.appendingPathComponent("a"), createExample: false)
        let b = ProjectStore(root: root.appendingPathComponent("b"), createExample: false)
        let id = a.create(title: "Island", kind: .story)
        var project = try story(); project.id = id
        a.update(id) { $0 = project }; XCTAssertTrue(a.saveNow())
        try a.sync.configure(folder: folder, start: false); await a.sync.checkNow()
        try b.sync.configure(folder: folder, start: false); await b.sync.checkNow()
        XCTAssertEqual(b.project(id)?.chapters[0].plainText, project.chapters[0].plainText, b.sync.status)
        XCTAssertEqual(b.projects.count, 1)
        _ = try XCTUnwrap(b.project(id), "First Mac: \(a.sync.status); second Mac: \(b.sync.status)")
        return (a, b, id, folder)
    }

    func testDifferentFieldsAndChaptersMerge() throws {
        var base = try story(); base.characters = [Character(name: "Mara")]
        base.chapters.append(Chapter(title: "Two"))
        var l = base, r = base
        l.characters[0].motivation = "Find the map"; r.characters[0].notes = "Left handed"
        l.chapters[0].synopsis = "Return"; r.chapters[1].title = "The map"
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty)
        let merged = try checked(result)
        XCTAssertEqual(merged.characters[0].motivation, "Find the map")
        XCTAssertEqual(merged.characters[0].notes, "Left handed")
        XCTAssertEqual(merged.chapters[0].synopsis, "Return")
        XCTAssertEqual(merged.chapters[1].title, "The map")
    }
    func testSeparateEditsWithinChapterAndEmojiMerge() throws {
        let base = try story("👩🏽‍💻 Mara sees a red boat.\n\nElias opens the gate.")
        var l = base, r = base
        try edit(&l, from: "red", to: "blue"); try edit(&r, from: "gate", to: "door")
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try checked(result).chapters[0].plainText, "👩🏽‍💻 Mara sees a blue boat.\n\nElias opens the door.")
    }
    func testFormattingAndTagsSurviveDisjointTextMerge() throws {
        var base = try story()
        let tagged = NSMutableAttributedString(attributedString: base.chapters[0].attributedText)
        tagged.addAttribute(.link, value: URL(string: "storywriter://tag/character/\(UUID().uuidString)")!, range: NSRange(location: 0, length: 4))
        try base.chapters[0].setText(tagged)
        var l = base, r = base
        let bold = NSMutableAttributedString(attributedString: l.chapters[0].attributedText)
        bold.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: 4))
        try l.chapters[0].setText(bold); try edit(&r, from: "gate", to: "door")
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty)
        let chapter = try checked(result).chapters[0], font = chapter.attributedText.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertNotNil(chapter.attributedText.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertTrue(chapter.plainText.hasSuffix("door."))
    }
    func testEmbeddedAttachmentsDoNotCreateFalseConflicts() throws {
        var base = try story()
        let wrapper = FileWrapper(regularFileWithContents: Data("Embedded reference".utf8)); wrapper.preferredFilename = "reference.txt"
        let text = NSMutableAttributedString(attributedString: base.chapters[0].attributedText)
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        try base.chapters[0].setText(text)
        var l = base, r = base
        try edit(&l, from: "red", to: "blue"); try edit(&r, from: "gate", to: "door")
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty, "\(result.conflicts.map(\.title))")
        let chapter = try checked(result).chapters[0]
        let attachment = try XCTUnwrap(chapter.attributedText.attribute(.attachment, at: chapter.attributedText.length - 1, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.fileWrapper?.regularFileContents, Data("Embedded reference".utf8))
        XCTAssertTrue(chapter.plainText.contains("blue")); XCTAssertTrue(chapter.plainText.contains("door"))
    }
    @MainActor func testThreeLibrariesMergeConcurrentBranches() async throws {
        let (a, b, id, folder) = try await pair()
        let c = ProjectStore(root: folder.deletingLastPathComponent().appendingPathComponent("c"), createExample: false)
        try c.sync.configure(folder: folder, start: false); await c.sync.checkNow()
        a.update(id) { $0.author = "A" }; b.update(id) { $0.genre = "B" }; c.update(id) { $0.premise = "C" }
        await a.sync.checkNow(); await b.sync.checkNow(); await c.sync.checkNow()
        await a.sync.checkNow(); await b.sync.checkNow()
        for store in [a, b, c] {
            XCTAssertEqual(store.project(id)?.author, "A", store.sync.status)
            XCTAssertEqual(store.project(id)?.genre, "B", store.sync.status)
            XCTAssertEqual(store.project(id)?.premise, "C", store.sync.status)
            XCTAssertTrue(store.sync.reviews.isEmpty, store.sync.status)
        }
    }
    @MainActor func testEditsDuringSyncArePreservedAndEventuallyCombined() async throws {
        let (a, b, id, _) = try await pair()
        a.update(id) { $0.author = "From A" }; await a.sync.checkNow()
        let syncing = Task { await b.sync.checkNow() }
        for i in 0..<12 { await Task.yield(); b.update(id) { $0.premise = "Latest \(i)" } }
        await syncing.value
        await b.sync.checkNow(); await a.sync.checkNow()
        XCTAssertEqual(b.project(id)?.premise, "Latest 11", b.sync.status)
        XCTAssertEqual(b.project(id)?.author, "From A", b.sync.status)
        XCTAssertEqual(a.project(id)?.premise, "Latest 11", a.sync.status)
    }
    func testOverlapsRequireChoiceAndRetainIndependentChanges() throws {
        let base = try story()
        var l = base, r = base
        try edit(&l, from: "red", to: "blue"); try edit(&r, from: "red", to: "black")
        r.genre = "Mystery"; l.author = "Writer"
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts[0].chapterID, base.chapters[0].id)
        let resolved = try ProjectMerge.merge(base: base, local: l, incoming: r, choices: [result.conflicts[0].id: .incoming])
        XCTAssertTrue(resolved.project.chapters[0].plainText.contains("black"))
        XCTAssertEqual(resolved.project.author, "Writer"); XCTAssertEqual(resolved.project.genre, "Mystery")
        _ = try checked(resolved)
    }
    func testSameInsertionIsDeduplicatedAndDifferentInsertionConflicts() throws {
        let b = NSAttributedString(string: "Mara waits.", attributes: WritingStyle.attributes)
        let l = NSAttributedString(string: "Mara waits here.", attributes: WritingStyle.attributes)
        let r = NSAttributedString(string: "Mara waits there.", attributes: WritingStyle.attributes)
        XCTAssertEqual(RichTextMerge.merge(base: b, local: l, incoming: l)?.string, l.string)
        XCTAssertNil(RichTextMerge.merge(base: b, local: l, incoming: r))
    }
    func testDiffReconstructsUnicodeInsertionsDeletionsAndReplacements() throws {
        var seed: UInt64 = 12345
        func next(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(count)) }
        let alphabet = ["a", "b", " ", "\n", "👩🏽‍💻", "ü"]
        for _ in 0..<150 {
            let a = (0..<next(40)).map { _ in alphabet[next(alphabet.count)] }.joined()
            let b = (0..<next(40)).map { _ in alphabet[next(alphabet.count)] }.joined()
            let original = NSAttributedString(string: a, attributes: WritingStyle.attributes)
            let revised = NSAttributedString(string: b, attributes: WritingStyle.attributes)
            let edits = try XCTUnwrap(RichTextMerge.edits(from: original, to: revised))
            let result = NSMutableAttributedString(attributedString: original)
            for edit in edits.reversed() { result.replaceCharacters(in: edit.old, with: edit.replacement) }
            XCTAssertEqual(result.string, b)
        }
    }
    func testExtensiveConcurrentRewritesFallBackToReview() throws {
        let base = NSAttributedString(string: String(repeating: "a", count: 1500), attributes: WritingStyle.attributes)
        let local = NSAttributedString(string: String(repeating: "b", count: 1500), attributes: WritingStyle.attributes)
        let incoming = NSAttributedString(string: String(repeating: "c", count: 1500), attributes: WritingStyle.attributes)
        XCTAssertNil(RichTextMerge.merge(base: base, local: local, incoming: incoming))
    }
    func testResolvingAnOverlapStillKeepsIndependentPassageEdits() throws {
        let base = try story("First red boat.\n\nSecond gate.\n\nThird flag.")
        var l = base, r = base
        try edit(&l, from: "red", to: "blue"); try edit(&l, from: "gate", to: "door")
        try edit(&r, from: "red", to: "black"); try edit(&r, from: "flag", to: "lamp")
        let pending = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertEqual(pending.conflicts.count, 1)
        let chosen = try ProjectMerge.merge(base: base, local: l, incoming: r, choices: [pending.conflicts[0].id: .incoming])
        XCTAssertEqual(try checked(chosen).chapters[0].plainText, "First black boat.\n\nSecond door.\n\nThird lamp.")
    }
    func testAnnotationsRebaseAcrossBothBranches() throws {
        var base = try story("Before.\n\nMara learns the secret.\n\nAfter.")
        base.characters = [Character(name: "Mara")]
        let item = ContinuityItem(name: "Secret", category: .knowledge)
        base.continuityItems = [item]
        let quote = "Mara learns the secret."
        let range = (base.chapters[0].plainText as NSString).range(of: quote)
        base.chapters[0].continuityEvents = [ContinuityEvent(itemID: item.id, characterID: base.characters[0].id, action: .learns, start: range.location, length: range.length, quote: quote)]
        try base.chapters[0].addComment(range: range, note: "Check this")
        base.chapters[0].scenes = [StoryScene(start: 0), StoryScene(title: "Secret", start: range.location)]
        var l = base, r = base
        try edit(&l, from: "Before.", to: "Much earlier.")
        try edit(&r, from: "After.", to: "Later that night.")
        r.chapters[0].comments?[0].note = "Keep this"
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty, "\(result.conflicts.map(\.title))")
        let chapter = try checked(result).chapters[0]
        XCTAssertEqual(chapter.plainText, "Much earlier.\n\nMara learns the secret.\n\nLater that night.")
        XCTAssertFalse(chapter.continuityEvents![0].detached)
        XCTAssertTrue(Continuity.validatesAnchor(chapter.continuityEvents![0], in: chapter.plainText))
        XCTAssertEqual(chapter.comments![0].start, chapter.continuityEvents![0].start)
        XCTAssertFalse(chapter.comments![0].detached)
        XCTAssertEqual(chapter.comments![0].note, "Keep this")
        XCTAssertEqual(chapter.scenes![1].start, chapter.continuityEvents![0].start)
    }
    func testChangedPassageDetachesAnchorRatherThanInventingContinuity() throws {
        var base = try story()
        let range = (base.chapters[0].plainText as NSString).range(of: "red")
        try base.chapters[0].addComment(range: range, note: "Color")
        var l = base, r = base
        try edit(&l, from: "red", to: "blue"); r.chapters[0].comments?[0].note = "Recheck color"
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty)
        let chapter = try checked(result).chapters[0]
        XCTAssertTrue(chapter.comments![0].detached)
        XCTAssertEqual(chapter.comments![0].note, "Recheck color")
    }
    func testConcurrentAdditionsAndCompatibleReorders() throws {
        var base = try story()
        base.chapters = ["A", "B", "C", "D"].map { Chapter(title: $0) }
        var l = base, r = base
        l.chapters.swapAt(0, 1); r.chapters.swapAt(2, 3)
        l.characters.append(Character(name: "Ada")); r.characters.append(Character(name: "Elias"))
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.project.chapters.map(\.title), ["B", "A", "D", "C"])
        XCTAssertEqual(Set(result.project.characters.map(\.name)), ["Ada", "Elias"])
        _ = try checked(result)
    }
    func testConflictingReorderAndDeleteVersusEditNeedReview() throws {
        var base = try story(); base.chapters = ["A", "B", "C"].map { Chapter(title: $0) }
        var l = base, r = base
        l.chapters.swapAt(0, 1); r.chapters.swapAt(1, 2)
        let order = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(order.conflicts.contains { $0.id.hasSuffix("/order") })
        l = base; r = base; l.chapters.removeFirst(); r.chapters[0].synopsis = "Changed"
        let deletion = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertEqual(deletion.conflicts.count, 1)
        XCTAssertEqual(deletion.project.chapters.count, 2)
        let resolved = try ProjectMerge.merge(base: base, local: l, incoming: r, choices: [deletion.conflicts[0].id: .incoming])
        XCTAssertEqual(resolved.project.chapters.count, 3)
        XCTAssertEqual(resolved.project.chapters[0].synopsis, "Changed")
    }
    func testDependentRecordDeletionProducesValidReviewFallback() throws {
        var base = try story()
        let item = ContinuityItem(name: "Secret", category: .knowledge)
        base.continuityItems = [item]; base.characters = [Character(name: "Mara")]
        var l = base, r = base
        l.continuityItems = []
        r.initialContinuity = [ContinuityEvent(itemID: item.id, characterID: base.characters[0].id, action: .learns, planned: true)]
        let result = try ProjectMerge.merge(base: base, local: l, incoming: r)
        XCTAssertTrue(result.conflicts.contains { $0.id == "Story/dependent records" })
        _ = try checked(result)
    }

    @MainActor func testTwoLibrariesFastForwardAndRestartWithoutDuplicateStories() async throws {
        let (a, b, id, _) = try await pair()
        a.update(id) { $0.author = "Mara" }; await a.sync.checkNow(); await b.sync.checkNow()
        XCTAssertEqual(b.project(id)?.author, "Mara", b.sync.status)
        let reopened = ProjectStore(root: b.root, createExample: false)
        await reopened.sync.checkNow()
        XCTAssertEqual(reopened.projects.count, 1)
        XCTAssertEqual(reopened.project(id)?.author, "Mara")
        XCTAssertTrue(reopened.sync.reviews.isEmpty, reopened.sync.status)
        XCTAssertFalse(b.revisions(id).isEmpty)
    }
    @MainActor func testOfflineBranchesMergeWithinSameChapterAndConverge() async throws {
        let (a, b, id, _) = try await pair()
        var l = a.project(id)!, r = b.project(id)!
        try edit(&l, from: "red", to: "blue"); try edit(&r, from: "gate", to: "door")
        a.update(id) { $0 = l }; b.update(id) { $0 = r }
        await a.sync.checkNow(); await b.sync.checkNow(); await a.sync.checkNow()
        let expected = "Mara sees a blue boat.\n\nElias opens the door."
        XCTAssertEqual(a.project(id)?.chapters[0].plainText, expected, a.sync.status)
        XCTAssertEqual(b.project(id)?.chapters[0].plainText, expected, b.sync.status)
        XCTAssertTrue(a.sync.reviews.isEmpty); XCTAssertTrue(b.sync.reviews.isEmpty)
        let count = try FileManager.default.contentsOfDirectory(at: a.sync.folder!.appendingPathComponent("Versions"), includingPropertiesForKeys: nil).count
        await a.sync.checkNow(); await b.sync.checkNow()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: a.sync.folder!.appendingPathComponent("Versions"), includingPropertiesForKeys: nil).count, count, "No repeated merge commits")
    }
    @MainActor func testConflictingBranchesResolveAndKeepBothPreservesIncoming() async throws {
        let (a, b, id, _) = try await pair()
        var l = a.project(id)!, r = b.project(id)!
        try edit(&l, from: "red", to: "blue"); try edit(&r, from: "red", to: "black")
        l.author = "Writer"; r.genre = "Mystery"
        a.update(id) { $0 = l }; b.update(id) { $0 = r }
        await a.sync.checkNow(); await b.sync.checkNow()
        let review = try XCTUnwrap(b.sync.reviews[id], b.sync.status)
        XCTAssertTrue(b.project(id)!.chapters[0].plainText.contains("black"))
        let accepted = await b.sync.resolve(review, choices: [:], keepBoth: true)
        XCTAssertTrue(accepted, b.sync.status)
        XCTAssertEqual(b.projects.count, 2)
        XCTAssertTrue(b.projects.contains { $0.id != id && $0.chapters[0].plainText.contains("blue") })
        XCTAssertEqual(b.project(id)?.author, "Writer"); XCTAssertEqual(b.project(id)?.genre, "Mystery")
        await a.sync.checkNow(); await b.sync.checkNow(); await a.sync.checkNow()
        XCTAssertTrue(a.sync.reviews.isEmpty, a.sync.status)
        XCTAssertEqual(a.projects.count, 2)
    }
    @MainActor func testStaleConflictCannotOverwriteNewLocalWriting() async throws {
        let (a, b, id, _) = try await pair()
        a.update(id) { $0.title = "A" }; b.update(id) { $0.title = "B" }
        await a.sync.checkNow(); await b.sync.checkNow()
        let old = try XCTUnwrap(b.sync.reviews[id], b.sync.status)
        b.update(id) { $0.author = "New edit" }
        let accepted = await b.sync.resolve(old, choices: Dictionary(uniqueKeysWithValues: old.conflicts.map { ($0.id, .incoming) }))
        XCTAssertFalse(accepted)
        XCTAssertEqual(b.project(id)?.author, "New edit")
        let refreshed = try XCTUnwrap(b.sync.reviews[id])
        XCTAssertNotEqual(old.id, refreshed.id)
    }
    @MainActor func testMediaDeduplicatesAndSurvivesIncomingMerge() async throws {
        let (a, b, id, folder) = try await pair()
        let file = folder.deletingLastPathComponent().appendingPathComponent("research.txt")
        try "Research".write(to: file, atomically: true, encoding: .utf8)
        a.importFiles([file], projectID: id); await a.sync.checkNow(); await b.sync.checkNow()
        XCTAssertFalse(a.sync.status.hasPrefix("Sync needs attention"), a.sync.status)
        let source = try XCTUnwrap(b.project(id)?.sources.first, b.sync.status)
        XCTAssertEqual(try String(contentsOf: b.mediaURL(source, projectID: id)!), "Research")
        a.update(id) { $0.author = "A" }; await a.sync.checkNow()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Assets"), includingPropertiesForKeys: nil).count, 1)
    }
    func testIncompleteVersionsWaitForAssetsAndParents() throws {
        let root = try directory(), folder = root.appendingPathComponent("drive"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let parent = DriveRevision(parents: [], deviceID: UUID(), deviceName: "Mac", project: try story(), assets: [:])
        let data = Data("Reference".utf8), digest = DriveSyncTransport.hash(data)
        var child = DriveRevision(parents: [parent.id], deviceID: UUID(), deviceName: "Mac", project: parent.project, assets: ["Media/ref.txt": digest])
        child.project.author = "Changed"
        try DriveSyncTransport.write(DriveSyncTransport.encode(child), to: DriveSyncTransport.revisionURL(child.id, in: folder), inside: folder)
        var scan = try DriveSyncTransport.scan(folder: folder, cache: cache)
        XCTAssertTrue(scan.waiting); XCTAssertTrue(scan.revisions.isEmpty)
        try DriveSyncTransport.write(data, to: DriveSyncTransport.assetURL(digest, in: folder), inside: folder)
        scan = try DriveSyncTransport.scan(folder: folder, cache: cache)
        XCTAssertTrue(scan.waiting); XCTAssertTrue(scan.revisions.isEmpty)
        try DriveSyncTransport.write(DriveSyncTransport.encode(parent), to: DriveSyncTransport.revisionURL(parent.id, in: folder), inside: folder)
        scan = try DriveSyncTransport.scan(folder: folder, cache: cache)
        XCTAssertFalse(scan.waiting); XCTAssertEqual(scan.revisions.count, 2)
    }
    func testCyclicOrForeignHistoryAndCorruptAssetsAreRejected() throws {
        let root = try directory(), folder = root.appendingPathComponent("drive"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var a = DriveRevision(parents: [], deviceID: UUID(), deviceName: "Mac", project: try story(), assets: [:])
        var b = DriveRevision(parents: [a.id], deviceID: UUID(), deviceName: "Mac", project: a.project, assets: [:])
        a.parents = [b.id]
        let write: (DriveRevision) throws -> Void = { revision in try DriveSyncTransport.encode(revision).write(to: DriveSyncTransport.revisionURL(revision.id, in: folder), options: .atomic) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Versions"), withIntermediateDirectories: true)
        try write(a); try write(b)
        XCTAssertThrowsError(try DriveSyncTransport.scan(folder: folder, cache: cache))
        a.parents = []; b.project.id = UUID()
        try write(a); try write(b)
        XCTAssertThrowsError(try DriveSyncTransport.scan(folder: folder, cache: cache))
        b.project.id = a.project.id
        let correct = Data("correct".utf8), hash = DriveSyncTransport.hash(correct)
        b.assets = ["Media/ref.txt": hash]
        try write(b)
        try DriveSyncTransport.write(Data("corrupt".utf8), to: DriveSyncTransport.assetURL(hash, in: folder), inside: folder)
        XCTAssertThrowsError(try DriveSyncTransport.scan(folder: folder, cache: cache))
    }
    func testUnsafeMediaAndImmutableVersionOverwriteAreRejected() throws {
        let root = try directory()
        let invalid = DriveRevision(parents: [], deviceID: UUID(), deviceName: "Mac", project: try story(), assets: ["Media/../../escape": String(repeating: "a", count: 64)])
        XCTAssertThrowsError(try DriveSyncTransport.decodeRevision(DriveSyncTransport.encode(invalid)))
        let file = root.appendingPathComponent("Versions/test.json")
        try DriveSyncTransport.write(Data("first".utf8), to: file, inside: root)
        XCTAssertThrowsError(try DriveSyncTransport.write(Data("second".utf8), to: file, inside: root))
        XCTAssertEqual(try Data(contentsOf: file), Data("first".utf8))
        let outside = try directory()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Assets"), withDestinationURL: outside)
        XCTAssertThrowsError(try DriveSyncTransport.write(Data(), to: root.appendingPathComponent("Assets/file"), inside: root))
    }
    func testNewFilesUnderPrivateTmpUseConsistentParentPaths() throws {
        let root = URL(fileURLWithPath: "/private/tmp/StoryWriterSyncPath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("New/Versions/test.json")
        try DriveSyncTransport.write(Data("version".utf8), to: file, inside: root)
        XCTAssertEqual(try DriveSyncTransport.read(file), Data("version".utf8))
    }
    @MainActor func testDisconnectedOrUnavailableDriveKeepsLocalAutosave() async throws {
        let (a, _, id, folder) = try await pair()
        try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("offline"))
        a.update(id) { $0.title = "Offline draft" }; await a.sync.checkNow()
        XCTAssertEqual(try ProjectStore.readPackage(a.packageURL(id)).title, "Offline draft")
        XCTAssertTrue(a.sync.status.hasPrefix("Sync needs attention"), a.sync.status)
        a.sync.disconnect()
        XCTAssertNil(a.sync.folder)
        XCTAssertEqual(a.project(id)?.title, "Offline draft")
    }
    @MainActor func testInterruptedInstallationIsIgnoredOnLibraryReopen() async throws {
        let root = try directory()
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Working draft", kind: .story)
        let staging = root.appendingPathComponent(".sync-install-\(UUID().uuidString).storywriter")
        try FileManager.default.copyItem(at: store.packageURL(id), to: staging)
        let reopened = ProjectStore(root: root, createExample: false)
        XCTAssertEqual(reopened.projects.map(\.id), [id])
        XCTAssertNil(reopened.errorMessage)
    }
}
