import XCTest
import AppKit
@testable import StoryWriter

final class ObjectDiscoveryTests: XCTestCase {
    func testExistingNamesAliasesIgnoredNamesDuplicatesAndStaleRanges() {
        let text = "🌊 Mara met Elisa on Bellweather Island. Elisa waved to Saskia."
        let source = text as NSString
        let names = ["Mara", "Elisa", "Bellweather Island", "Elisa", "Saskia"]
        var offset = 0
        let candidates = names.map { name -> ObjectNameSuggestion in
            let range = source.range(of: name, options: [], range: NSRange(location: offset, length: source.length - offset)); offset = NSMaxRange(range)
            return ObjectNameSuggestion(name: name, range: range, kind: .character)
        }
        XCTAssertEqual(ObjectDiscovery.filter(candidates, text: text, objects: StoryProject.example().tagObjects, ignored: ["saskia"]).map(\.name), ["Elisa"])
        XCTAssertFalse(ObjectDiscovery.known("Elisa", objects: StoryProject.example().tagObjects, ignored: []), "Elisa must not be confused with Elias")
        XCTAssertTrue(ObjectDiscovery.known("Vale", objects: StoryProject.example().tagObjects, ignored: []))
        XCTAssertTrue(ObjectDiscovery.known("Mára", objects: StoryProject.example().tagObjects, ignored: []))
        XCTAssertTrue(ObjectDiscovery.filter(candidates, text: "Replaced text", objects: [], ignored: []).isEmpty)
    }

    func testNativeRecognitionInEnglishAndGerman() {
        for (language, text) in [("en", "Elisa walked into the room. Ben handed Elisa a letter."), ("de", "Elisa ging ins Zimmer. Ben gab Elisa einen Brief."), ("auto", "Elisa ging ins Zimmer. Ben gab Elisa einen Brief.")] {
            let names = ObjectDiscovery.names(in: text, language: language, objects: [], ignored: [])
            XCTAssertTrue(names.contains { $0.name == "Elisa" }, "\(language): recognized \(names.map(\.name))")
            XCTAssertTrue(names.allSatisfy { (text as NSString).substring(with: $0.range) == $0.name })
        }
    }

    @MainActor func testExplicitCreationAndIgnoredNamesSaveWithPortableProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Discovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Discovery test", kind: .story)
        let characterRef = try XCTUnwrap(store.createObject(named: " Elisa ", kind: .character, projectID: id))
        XCTAssertEqual(store.project(id)?.characters.first?.name, "Elisa")
        XCTAssertEqual(store.project(id)?.characters.first?.pronouns, "", "Discovery must not invent facts about the character")
        XCTAssertEqual(store.createObject(named: "elisa", kind: .character, projectID: id), characterRef)
        XCTAssertEqual(store.project(id)?.characters.count, 1)
        _ = store.createObject(named: "Ferry dock", kind: .location, projectID: id)
        _ = store.createObject(named: "Silver key", kind: .item, projectID: id)
        XCTAssertEqual(store.project(id)?.worldNotes.map(\.category), [.location, .object])
        store.ignoreObjectName("Saskia", projectID: id); store.ignoreObjectName("saskia", projectID: id)
        XCTAssertEqual(store.project(id)?.ignoredObjectNames, ["Saskia"])
        let url = root.appendingPathComponent("Discovery.storywriter"); try store.exportPackage(id, to: url)
        let imported = try ProjectStore.readPackage(url)
        XCTAssertEqual(imported.ignoredObjectNames, ["Saskia"])
        XCTAssertTrue(imported.tagObjects.contains { $0.reference == characterRef })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(imported)) as? [String: Any])
        old.removeValue(forKey: "ignoredObjectNames")
        XCTAssertNil(try ProjectStore.decode(JSONSerialization.data(withJSONObject: old)).ignoredObjectNames)
    }

    @MainActor func testManualUnknownNameCreationTagsTextAndIgnoreKeepsProse() {
        let view = ManuscriptTextView(frame: .zero); view.isRichText = true
        let session = ObjectTagSession(view: view); view.tagSession = session
        view.textStorage?.setAttributedString(NSAttributedString(string: "She met @Saskia", attributes: WritingStyle.attributes))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let reference = ProjectTagReference(kind: .character, objectID: UUID())
        var creations: [(String, NewObjectKind)] = []
        session.create = { name, kind in creations.append((name, kind)); return reference }
        session.refreshSuggestions(); XCTAssertEqual(session.newName, "Saskia")
        session.createNew(.character)
        XCTAssertEqual(creations.first?.0, "Saskia"); XCTAssertEqual(creations.count, 1)
        XCTAssertEqual(view.string, "She met Saskia")
        XCTAssertEqual(ProjectTagReference.from(view.textStorage?.attribute(.link, at: 8, effectiveRange: nil)), reference)
        view.textStorage?.setAttributedString(NSAttributedString(string: "@Ben", attributes: WritingStyle.attributes)); view.setSelectedRange(NSRange(location: 4, length: 0))
        var ignored: String?
        session.ignoreName = { ignored = $0 }; session.refreshSuggestions(); session.ignoreNewName()
        XCTAssertEqual(view.string, "Ben"); XCTAssertEqual(ignored, "Ben"); XCTAssertEqual(creations.count, 1)
    }

    @MainActor func testAutomaticDiscoveryDoesNotEditProseAndRejectsStaleCreation() async throws {
        let view = ManuscriptTextView(frame: .zero)
        view.textStorage?.setAttributedString(NSAttributedString(string: "Elisa walked into the room.", attributes: WritingStyle.attributes))
        let session = ObjectNameSession(view: view); view.objectNames = session
        session.scan()
        for _ in 0..<100 {
            if !session.suggestions.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let suggestion = try XCTUnwrap(session.suggestions.first { $0.name == "Elisa" })
        XCTAssertEqual(view.string, "Elisa walked into the room.")
        XCTAssertNil(view.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil), "Discovery marks must not enter saved text")
        var created = false
        session.create = { _, _ in created = true; return ProjectTagReference(kind: .character, objectID: UUID()) }
        view.string = "Replaced prose."
        session.createObject(suggestion, kind: .character)
        XCTAssertFalse(created, "Never create a profile from a stale suggestion")
        session.cancel()
    }
}
