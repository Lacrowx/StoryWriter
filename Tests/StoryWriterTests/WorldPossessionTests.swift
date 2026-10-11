import XCTest
import AppKit
@testable import StoryWriter

final class WorldPossessionTests: XCTestCase {
    private func story() -> StoryProject {
        var project = StoryProject.new(title: "World possessions", kind: .story)
        project.characters = [Character(name: "Cole Skorp")]
        project.chapters[0].plainText = "Cole hat den Zettel. Außerdem hatte er seinen Stock dabei."
        project.worldNotes = [
            WorldNote(title: "Stock", category: .object, summary: "A walking staff", aliases: ["Wanderstab"]),
            WorldNote(title: "Zettel", category: .object),
            WorldNote(title: "Akademie Atorus", category: .location),
            WorldNote(title: "No weapons", category: .rules)
        ]
        return project
    }

    func testHasOffersWorldItemsWithoutAssigningOrPersistingThem() throws {
        let project = story()
        let choices = project.continuityChoices(for: .possession)
        XCTAssertEqual(Set(choices.map(\.name)), Set(["Stock", "Zettel"]))
        XCTAssertEqual(choices.map(\.worldObjectID), project.worldNotes.prefix(2).map { Optional($0.id) })
        XCTAssertEqual(Continuity.matches(choices, query: "Wanderstab").first?.name, "Stock")
        XCTAssertEqual(Continuity.matches(choices, query: "Außerdem hatte er seinen Stock dabei.").first?.name, "Stock")
        XCTAssertEqual(Set(project.continuityChoices(for: .knowledge).map(\.name)), Set(["Stock", "Zettel"]))
        XCTAssertTrue(project.continuityChoices(for: .possession, parentID: UUID()).isEmpty)
        XCTAssertNil(project.continuityItems)
        XCTAssertTrue(Continuity.states(in: project, characterID: project.characters[0].id, chapterID: project.chapters[0].id, offset: project.chapters[0].plainText.utf16.count).isEmpty)
    }

    func testExistingWorldItemIsReusableAndOwnershipStartsAfterThePassage() throws {
        var project = story()
        let world = project.worldNotes[0]
        let item = try project.useContinuityChoice(world.id, category: .possession)
        XCTAssertEqual(item.worldObjectID, world.id)
        XCTAssertNotEqual(item.id, world.id)
        let range = (project.chapters[0].plainText as NSString).range(of: "Außerdem hatte er seinen Stock dabei.")
        try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .gets, chapterID: project.chapters[0].id, range: range)
        XCTAssertTrue(Continuity.states(in: project, characterID: project.characters[0].id, chapterID: project.chapters[0].id, offset: NSMaxRange(range) - 1).isEmpty)
        XCTAssertEqual(Continuity.states(in: project, characterID: project.characters[0].id, chapterID: project.chapters[0].id, offset: NSMaxRange(range)).map(\.item.name), ["Stock"])
        let reused = try project.createContinuityItem(name: "Wanderstab", category: .possession)
        XCTAssertEqual(reused.id, item.id)
        XCTAssertEqual(project.continuityItems?.count, 1)
        XCTAssertEqual(project.chapters[0].continuityEvents?.count, 1)
    }

    func testManuallyAddedZettelKeepsItsIdentityAndHistoryWhenLinked() throws {
        var project = story()
        // Simulate the older picker, which stored the same object independently.
        let old = ContinuityItem(name: "Zettel", category: .possession, aliases: ["Notiz"], details: "A note he carries")
        project.continuityItems = [old]
        let event = try project.recordContinuity(itemID: old.id, characterID: project.characters[0].id, action: .gets, chapterID: nil)
        let choices = project.continuityChoices(for: .possession)
        XCTAssertEqual(choices.filter { $0.name == "Zettel" }.count, 1)
        XCTAssertEqual(choices.first { $0.name == "Zettel" }?.id, old.id)
        XCTAssertNil(project.continuityItems?.first?.worldObjectID, "Opening the picker does not migrate saved records")
        let linked = try project.useContinuityChoice(old.id, category: .possession)
        XCTAssertEqual(linked.worldObjectID, project.worldNotes[1].id)
        XCTAssertEqual(project.continuityItems?.count, 1)
        XCTAssertEqual(project.initialContinuity?.first?.id, event.id)
        XCTAssertEqual(project.initialContinuity?.first?.itemID, old.id)
        XCTAssertEqual(project.continuityItems?.first?.details, old.details)
        project.worldNotes[1].title = "Briefzettel"
        project.worldNotes[1].aliases = ["Nachricht"]
        let displayed = try XCTUnwrap(project.trackedContinuityItems.first)
        XCTAssertEqual(displayed.name, "Briefzettel")
        XCTAssertTrue(displayed.aliases.contains("Zettel"))
        XCTAssertTrue(displayed.aliases.contains("Notiz"))
        XCTAssertTrue(displayed.aliases.contains("Nachricht"))
        XCTAssertEqual(Continuity.states(in: project, characterID: project.characters[0].id, chapterID: project.chapters[0].id, offset: 0).first?.item.name, "Briefzettel")
    }

    func testAmbiguousSharedNamesDoNotSilentlyLinkSeparateWorldObjects() throws {
        var project = story()
        project.worldNotes = [WorldNote(title: "Stock", category: .object), WorldNote(title: "Stock", category: .object)]
        let old = ContinuityItem(name: "Stock", category: .possession)
        project.continuityItems = [old]
        let choices = project.continuityChoices(for: .possession)
        XCTAssertEqual(choices.count, 3)
        XCTAssertNil(choices.first { $0.id == old.id }?.worldObjectID)
        XCTAssertNil(Continuity.exactMatch(choices, name: "Stock", category: .possession))
        let selected = try project.useContinuityChoice(project.worldNotes[1].id, category: .possession)
        XCTAssertEqual(selected.worldObjectID, project.worldNotes[1].id)
        XCTAssertNil(project.continuityItems?.first { $0.id == old.id }?.worldObjectID)
    }

    func testDeletedWorldItemsLeaveRecordedHistoryIntactAndStaleChoicesFail() throws {
        var project = story()
        let worldID = project.worldNotes[0].id
        let item = try project.useContinuityChoice(worldID, category: .possession)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .gets, chapterID: nil)
        let unrecordedID = project.worldNotes[1].id
        project.worldNotes = []
        XCTAssertEqual(project.trackedContinuityItems.first?.name, "Stock")
        XCTAssertEqual(Continuity.history(in: project, itemID: item.id).count, 1)
        XCTAssertThrowsError(try project.useContinuityChoice(unrecordedID, category: .possession))
        XCTAssertThrowsError(try project.useContinuityChoice(item.id, category: .knowledge))
        XCTAssertEqual(project.continuityItems?.count, 1)
    }

    @MainActor func testWorldLinkSurvivesPortableCopyAndOlderRecordsDecode() throws {
        var project = story()
        let item = try project.useContinuityChoice(project.worldNotes[0].id, category: .possession)
        try project.recordContinuity(itemID: item.id, characterID: project.characters[0].id, action: .gets, chapterID: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorldPossessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        store.projects = [project]; store.selectedProjectID = project.id; store.update(project.id) { $0 = project }
        XCTAssertTrue(store.saveNow())
        let portable = root.appendingPathComponent("Linked.storywriter")
        try store.exportPackage(project.id, to: portable)
        let imported = ProjectStore(root: root.appendingPathComponent("imported"), createExample: false)
        imported.importPackage(portable)
        let restored = try XCTUnwrap(imported.selectedProject)
        XCTAssertEqual(restored.continuityItems?.first?.worldObjectID, item.worldObjectID)
        XCTAssertEqual(restored.continuityChoices(for: .possession).filter { $0.name == "Stock" }.count, 1)
        XCTAssertEqual(Continuity.history(in: restored, itemID: item.id).count, 1)
        let encoder = JSONEncoder()
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(item)) as? [String: Any])
        legacy.removeValue(forKey: "worldObjectID")
        let decoded = try JSONDecoder().decode(ContinuityItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.id, item.id)
        XCTAssertNil(decoded.worldObjectID)
    }
}
