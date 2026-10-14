import XCTest
import AppKit
@testable import StoryWriter

final class ApplicationPreferencesTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "StoryWriter-settings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testUnsetPreferencesKeepCurrentBehavior() throws {
        let preferences = ApplicationPreferences(defaults: try defaults())
        XCTAssertTrue(preferences.resumesWorkspace)
        XCTAssertTrue(preferences.discoversNames)
        XCTAssertTrue(preferences.selectionActions)
        XCTAssertEqual(preferences.autosaveDelay, 2)
        XCTAssertEqual(preferences.revisionInterval, 300)
        XCTAssertEqual(preferences.backupInterval, 300)
        XCTAssertEqual(preferences.reviewDelay, 2)
        XCTAssertEqual(preferences.paperMargins, .balanced)
    }

    func testTimingsClampCorruptAndOutOfRangeValues() throws {
        let defaults = try defaults(), preferences = ApplicationPreferences(defaults: defaults)
        defaults.set(-100.0, forKey: "autosaveDelay")
        defaults.set(100000.0, forKey: "revisionInterval")
        defaults.set("invalid", forKey: "backupInterval")
        defaults.set(Double.infinity, forKey: "reviewDelay")
        XCTAssertEqual(preferences.autosaveDelay, 0.3)
        XCTAssertEqual(preferences.revisionInterval, 1800)
        XCTAssertEqual(preferences.backupInterval, 300)
        XCTAssertEqual(preferences.reviewDelay, 2)
        defaults.set(-1.0, forKey: "defaultFontSize")
        XCTAssertEqual(preferences.defaultFont.pointSize, 10)
    }

    func testPreferencesPersistAndRemovingKeysRestoresDefaults() throws {
        let defaults = try defaults()
        defaults.set(false, forKey: "resumeWorkspace")
        defaults.set(5.0, forKey: "autosaveDelay")
        defaults.set(PaperMargins.generous.rawValue, forKey: "paperMargins")
        let reopened = ApplicationPreferences(defaults: defaults)
        XCTAssertFalse(reopened.resumesWorkspace)
        XCTAssertEqual(reopened.autosaveDelay, 5)
        XCTAssertEqual(reopened.paperMargins, .generous)
        defaults.removeObject(forKey: "autosaveDelay")
        XCTAssertEqual(reopened.autosaveDelay, 2)
    }

    func testStartingTypographyUsesChosenFontAndSpacing() throws {
        let defaults = try defaults()
        defaults.set("Menlo", forKey: "defaultFontName")
        defaults.set(22.0, forKey: "defaultFontSize")
        defaults.set(12.0, forKey: "defaultLineSpacing")
        let attrs = WritingStyle.attributes(preferences: ApplicationPreferences(defaults: defaults))
        let font = try XCTUnwrap(attrs[.font] as? NSFont)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 22)
        XCTAssertEqual((attrs[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing, 12)
        defaults.set("Missing font family", forKey: "defaultFontName")
        XCTAssertEqual(ApplicationPreferences(defaults: defaults).defaultFont.pointSize, 22)
    }

    func testPaperMarginsScaleWithinUsableBounds() {
        XCTAssertEqual(PaperMargins.compact.horizontal(for: 1000), 20)
        XCTAssertEqual(PaperMargins.balanced.horizontal(for: 400), 28)
        XCTAssertEqual(PaperMargins.balanced.horizontal(for: 2000), 64)
        XCTAssertEqual(PaperMargins.generous.horizontal(for: 400), 44)
        XCTAssertEqual(PaperMargins.generous.horizontal(for: 2000), 100)
    }

    @MainActor func testDisablingResumeOpensLibraryWithoutDeletingRememberedNavigation() throws {
        let defaults = try defaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        let id = store.create(title: "Remember me", kind: .story)
        var project = try XCTUnwrap(store.project(id))
        project.chapters.append(Chapter(title: "Second"))
        store.update(id) { $0 = project }
        XCTAssertTrue(store.saveNow())
        store.workspacePreferences.rememberChapter(project.chapters[1].id, in: id)
        store.workspacePreferences.rememberSection(.world, in: id)
        defaults.set(false, forKey: "resumeWorkspace")
        let reopened = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        XCTAssertNil(reopened.selectedProjectID)
        XCTAssertEqual(reopened.workspacePreferences.chapterID(in: project), project.chapters[0].id)
        XCTAssertEqual(reopened.workspacePreferences.section(in: id), .manuscript)
        defaults.set(true, forKey: "resumeWorkspace")
        XCTAssertEqual(reopened.workspacePreferences.chapterID(in: project), project.chapters[1].id)
        XCTAssertEqual(reopened.workspacePreferences.section(in: id), .world)
        let resumed = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        XCTAssertEqual(resumed.selectedProjectID, id)
    }

    func testDisplayAndTypographyChangesPreserveSavedAndLegacyText() throws {
        let keys = ["defaultFontName", "defaultFontSize", "defaultLineSpacing", "dimPaper", "paperTone"]
        let defaults = UserDefaults.standard
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        var chapter = Chapter(title: "Existing")
        let original = NSAttributedString(string: "Keep these words.", attributes: WritingStyle.legacyAttributes)
        try chapter.setText(original)
        let savedData = chapter.richText
        defaults.set("Menlo", forKey: "defaultFontName")
        defaults.set(24.0, forKey: "defaultFontSize")
        defaults.set(14.0, forKey: "defaultLineSpacing")
        defaults.set(true, forKey: "dimPaper")
        defaults.set(PaperTone.sepia.rawValue, forKey: "paperTone")
        XCTAssertEqual(chapter.richText, savedData)
        XCTAssertEqual(chapter.attributedText.string, original.string)
        XCTAssertEqual((chapter.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual((chapter.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing, 6)
        let legacy = Chapter(plainText: "Older unformatted writing")
        XCTAssertEqual((legacy.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual((WritingStyle.attributes[.font] as? NSFont)?.pointSize, 24)
    }
}
