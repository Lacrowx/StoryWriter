import XCTest
import AppKit
@testable import StoryWriter

final class ContinuityTests: XCTestCase {
    private func story(_ text: String = "Maya reads the letter. Then Theo arrives.") -> StoryProject {
        var project = StoryProject.new(title: "Continuity", kind: .story)
        project.characters = [Character(name: "Maya"), Character(name: "Theo")]
        project.chapters[0].plainText = text
        return project
    }
    private func encoded(_ project: StoryProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(project)
    }
    private func states(_ project: StoryProject, _ offset: Int) -> [ContinuityState] { states(project, 0, offset) }
    private func states(_ project: StoryProject, _ person: Int, _ offset: Int) -> [ContinuityState] {
        Continuity.states(in: project, characterID: project.characters[person].id, chapterID: project.chapters[0].id, offset: offset)
    }

    func testSharedIdentityAliasesAndSimilarWordings() throws {
        var project = story()
        let family = try project.createContinuityItem(name: "Family history", category: .knowledge, aliases: ["past family history"])
        let same = try project.createContinuityItem(name: "  PAST family history! ", category: .knowledge)
        XCTAssertEqual(same.id, family.id)
        XCTAssertEqual(project.continuityItems?.count, 1)
        XCTAssertEqual(Continuity.matches(project.continuityItems!, query: "the past family history").first?.id, family.id)
        let town = try project.createContinuityItem(name: "Town history", category: .knowledge)
        XCTAssertEqual(Continuity.matches(project.continuityItems!, query: "history").count, 2)
        XCTAssertNil(Continuity.exactMatch(project.continuityItems!, name: "history", category: .knowledge))
        XCTAssertNotEqual(family.id, town.id)
    }
    func testKnowledgeStartsAfterItsPassageAndIsCharacterSpecific() throws {
        var project = story()
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge)
        let event = try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 0, length: 22))
        XCTAssertTrue(states(project, 21).isEmpty)
        XCTAssertEqual(states(project, 22).first?.id, item.id)
        XCTAssertTrue(states(project, 1, 40).isEmpty)
        XCTAssertEqual(event.quote, "Maya reads the letter.")
        XCTAssertEqual(Continuity.history(in: project, itemID: item.id).first?.chapterID, project.chapters[0].id)
    }
    func testRepeatedLearningIsRejectedButReminderAndRelearningAreAllowed() throws {
        var project = story()
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge)
        let c = project.chapters[0].id, person = project.characters[0].id
        let first = try project.recordContinuity(itemID: item.id, characterID: person, action: .learns, chapterID: c, range: NSRange(location: 22, length: 0))
        XCTAssertThrowsError(try project.recordContinuity(itemID: item.id, characterID: person, action: .learns, chapterID: c, range: NSRange(location: 23, length: 0)))
        try project.recordContinuity(itemID: item.id, characterID: person, action: .reminded, chapterID: c, range: NSRange(location: 24, length: 0))
        XCTAssertEqual(states(project, 25).first?.latest.id, first.id)
        try project.recordContinuity(itemID: item.id, characterID: person, action: .forgets, chapterID: c, range: NSRange(location: 26, length: 0))
        try project.recordContinuity(itemID: item.id, characterID: person, action: .learns, chapterID: c, range: NSRange(location: 27, length: 0))
        XCTAssertEqual(states(project, 28).first?.latest.event.action, .learns)
    }
    func testStartingConditionsCarryForwardAndPlansDontBecomeKnowledge() throws {
        var project = story()
        let initial = try project.createContinuityItem(name: "Sender identity", category: .knowledge)
        let planned = try project.createContinuityItem(name: "Family secret", category: .knowledge)
        try project.recordContinuity(itemID: initial.id, characterID: project.characters[0].id, action: .learns, chapterID: nil)
        try project.recordContinuity(itemID: planned.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 22, length: 0), planned: true)
        XCTAssertEqual(states(project, 0).map(\.id), [initial.id])
        XCTAssertEqual(states(project, 40).map(\.id), [initial.id])
        project.chapters.append(Chapter(title: "Later", plainText: "A new day."))
        XCTAssertEqual(Continuity.states(in: project, characterID: project.characters[0].id, chapterID: project.chapters[1].id, offset: 0).map(\.id), [initial.id])
    }
    func testFlashbackUsesSceneTimelineRatherThanReadingOrder() throws {
        var project = story("Future scene.\n\nPast scene.")
        project.chapters[0].scenes = [StoryScene(title: "Future", start: 0, timelineOrder: 20), StoryScene(title: "Past", start: 15, timelineOrder: 10)]
        let future = try project.createContinuityItem(name: "Future revelation", category: .knowledge)
        let past = try project.createContinuityItem(name: "Old memory", category: .knowledge)
        try project.recordContinuity(itemID: future.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 12, length: 0))
        try project.recordContinuity(itemID: past.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 20, length: 0))
        XCTAssertEqual(states(project, 24).map(\.id), [past.id])
        XCTAssertEqual(Set(states(project, 12).map(\.id)), Set([past.id, future.id]))
    }
    func testTransferTasksBeliefsAndRulesHaveIndependentStates() throws {
        var project = story()
        let key = try project.createContinuityItem(name: "Brass key", category: .possession)
        let task = try project.createContinuityItem(name: "Deliver letter", category: .task)
        let rule = try project.createContinuityItem(name: "Keep sender secret", category: .rule)
        let belief = try project.createContinuityItem(name: "Bridge is safe", category: .knowledge)
        let person = project.characters[0].id, other = project.characters[1].id, c = project.chapters[0].id
        for (item, action) in [(key, ContinuityAction.gets), (task, .assigned), (rule, .applies), (belief, .believes)] {
            try project.recordContinuity(itemID: item.id, characterID: person, action: action, chapterID: nil)
        }
        try project.recordContinuity(itemID: key.id, characterID: person, action: .loses, chapterID: c, range: NSRange(location: 25, length: 0))
        try project.recordContinuity(itemID: key.id, characterID: other, action: .gets, chapterID: c, range: NSRange(location: 25, length: 0))
        try project.recordContinuity(itemID: task.id, characterID: person, action: .completed, chapterID: c, range: NSRange(location: 25, length: 0))
        try project.recordContinuity(itemID: rule.id, characterID: person, action: .broken, chapterID: c, range: NSRange(location: 25, length: 0))
        XCTAssertEqual(states(project, 24).filter { $0.latest.event.action.active }.count, 4)
        XCTAssertEqual(states(project, 26).filter { $0.latest.event.action.active }.count, 2)
        XCTAssertEqual(states(project, 1, 26).map(\.id), [key.id])
        XCTAssertEqual(states(project, 26).first { $0.id == belief.id }?.latest.event.action, .believes)
        XCTAssertTrue(ContinuityAction.broken.active)
    }
    @MainActor func testPassageEditsShiftAnchorsAndChangedSourcesRequireReview() throws {
        var project = story("😀 Maya reads the letter.")
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 3, length: 4))
        try project.chapters[0].setText(NSAttributedString(string: "New. 😀 Maya reads the letter."))
        XCTAssertEqual(project.chapters[0].continuityEvents?.first?.start, 8)
        XCTAssertFalse(project.chapters[0].continuityEvents!.first!.detached)
        try project.chapters[0].setText(NSAttributedString(string: "New. 😀 Nora reads the letter."))
        XCTAssertTrue(project.chapters[0].continuityEvents!.first!.detached)
        XCTAssertTrue(states(project, project.chapters[0].plainText.utf16.count).isEmpty)
    }
    @MainActor func testEventsFollowSceneMovesAndCrossingAnchorsAreDetached() throws {
        var project = story("Ada waits.\n\nBen reads.")
        try project.chapters[0].setText(NSAttributedString(string: project.chapters[0].plainText))
        try project.chapters[0].splitScene(at: 12)
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge)
        let event = try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 12, length: 10))
        let endItem = try project.createContinuityItem(name: "End discovery", category: .knowledge)
        try project.recordContinuity(itemID: endItem.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 22, length: 0))
        try project.chapters[0].moveScene(project.chapters[0].orderedScenes[1].id, offset: -1)
        let moved = project.chapters[0].continuityEvents!.first { $0.id == event.id }!
        XCTAssertEqual(moved.start, 0)
        XCTAssertEqual(moved.quote, "Ben reads.")
        XCTAssertTrue(Continuity.validatesAnchor(moved, in: project.chapters[0].plainText))
        XCTAssertEqual(project.chapters[0].continuityEvents![1].start, 10)
    }
    func testMergePreservesAllCharactersAliasesPassagesAndDetails() throws {
        var project = story()
        let source = try project.createContinuityItem(name: "Past family history", category: .knowledge)
        let target = try project.createContinuityItem(name: "Family history", category: .knowledge)
        let child = try project.createContinuityItem(name: "Grandfather founded the business", category: .knowledge, parentID: source.id)
        try project.recordContinuity(itemID: source.id, characterID: project.characters[0].id, action: .learns, chapterID: nil)
        let event = try project.recordContinuity(itemID: target.id, characterID: project.characters[1].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 22, length: 0))
        try project.mergeContinuityItem(source.id, into: target.id)
        XCTAssertEqual(project.continuityItems?.count, 2)
        XCTAssertEqual(project.continuityItems?.first { $0.id == target.id }?.aliases, [source.name])
        XCTAssertEqual(project.continuityItems?.first { $0.id == child.id }?.parentID, target.id)
        XCTAssertEqual(Continuity.history(in: project, itemID: target.id).count, 2)
        XCTAssertEqual(project.chapters[0].continuityEvents?.first?.id, event.id)
        XCTAssertEqual(states(project, 40).map(\.id), [target.id])
        XCTAssertThrowsError(try project.mergeContinuityItem(target.id, into: child.id))
    }
    func testTopicKnowledgeDoesNotImplyEveryDetailAndNamesCanChange() throws {
        var project = story()
        let topic = try project.createContinuityItem(name: "Family history", category: .knowledge)
        let detail = try project.createContinuityItem(name: "Concealed adoption", category: .knowledge, parentID: topic.id)
        try project.recordContinuity(itemID: topic.id, characterID: project.characters[0].id, action: .learns, chapterID: nil)
        project.continuityItems?[0].name = "Hart family history"
        XCTAssertEqual(states(project, 0).first?.item.name, "Hart family history")
        XCTAssertFalse(states(project, 40).contains { $0.id == detail.id })
    }
    func testOldProjectsDecodeAndMalformedAnchorsAreRejected() throws {
        var project = story()
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: nil)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[1].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 22, length: 0))
        let decoded = try ProjectStore.decode(encoded(project))
        XCTAssertEqual(decoded.continuityItems, project.continuityItems)
        XCTAssertEqual(decoded.initialContinuity, project.initialContinuity)
        XCTAssertEqual(decoded.chapters, project.chapters)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(project)) as? [String: Any])
        legacy.removeValue(forKey: "continuityItems"); legacy.removeValue(forKey: "initialContinuity")
        var chapters = legacy["chapters"] as! [[String: Any]]; chapters[0].removeValue(forKey: "continuityEvents"); legacy["chapters"] = chapters
        XCTAssertNil(try ProjectStore.decode(JSONSerialization.data(withJSONObject: legacy)).continuityItems)
        project.chapters[0].continuityEvents?[0].start = Int.max
        project.chapters[0].continuityEvents?[0].length = 10
        XCTAssertThrowsError(try ProjectStore.decode(encoded(project)))
        XCTAssertThrowsError(try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .gets, chapterID: nil))
    }
    @MainActor func testSaveReopenAndPortableImportPreserveSharedLearningHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuityTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        var project = story()
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge, aliases: ["past family history"])
        try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: nil)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[1].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 22, length: 0))
        store.projects = [project]; store.update(project.id) { $0 = project }; XCTAssertTrue(store.saveNow())
        let reopened = ProjectStore(root: store.root, createExample: false)
        XCTAssertEqual(reopened.project(project.id)?.continuityItems, project.continuityItems)
        let portable = root.appendingPathComponent("copy.storywriter"); try store.exportPackage(project.id, to: portable)
        reopened.importPackage(portable)
        let imported = try XCTUnwrap(reopened.selectedProject)
        XCTAssertNotEqual(imported.id, project.id)
        XCTAssertEqual(Continuity.history(in: imported, itemID: item.id).map(\.event), Continuity.history(in: project, itemID: item.id).map(\.event))
    }
    @MainActor func testChapterRecoveryIncludesMissingSharedItemsAndTheirTopics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuityRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        var saved = story()
        let topic = try saved.createContinuityItem(name: "Family history", category: .knowledge)
        let detail = try saved.createContinuityItem(name: "Grandfather founded business", category: .knowledge, parentID: topic.id)
        try saved.recordContinuity(itemID: detail.id, characterID: saved.characters[0].id, action: .learns, chapterID: saved.chapters[0].id, range: NSRange(location: 22, length: 0))
        var current = saved; current.continuityItems = nil; current.chapters[0].continuityEvents = nil
        store.projects = [current]; store.update(current.id) { $0 = current }; XCTAssertTrue(store.saveNow())
        try store.recoverChapter(saved.chapters[0], projectID: saved.id, continuitySource: saved)
        let reopened = try ProjectStore.readPackage(store.packageURL(saved.id))
        XCTAssertEqual(Set(reopened.continuityItems!.map(\.id)), Set([topic.id, detail.id]))
        XCTAssertEqual(reopened.chapters[0].continuityEvents, saved.chapters[0].continuityEvents)
    }
    func testPointAnchorsAndUTF16SelectionsRemainSafe() throws {
        var project = story("😀 letter")
        let item = try project.createContinuityItem(name: "Family history", category: .knowledge)
        XCTAssertThrowsError(try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 1, length: 0)))
        let event = try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .learns, chapterID: project.chapters[0].id, range: NSRange(location: 3, length: 0))
        let shifted = Continuity.rebase([event], old: "😀 letter", new: "New. 😀 letter")[0]
        XCTAssertEqual(shifted.start, 8)
        XCTAssertFalse(shifted.detached)
        let atPoint = Continuity.rebase([event], old: "😀 letter", new: "😀 new letter")[0]
        XCTAssertEqual(atPoint.start, 3)
        XCTAssertFalse(atPoint.detached)
        XCTAssertThrowsError(try project.recordContinuity(itemID: item.id, characterID: project.characters[1].id, action: .learns, chapterID: project.chapters[0].id, expectedText: "Old passage"))
    }
}
