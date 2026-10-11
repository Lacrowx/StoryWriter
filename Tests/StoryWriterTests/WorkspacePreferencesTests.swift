import XCTest
@testable import StoryWriter

final class WorkspacePreferencesTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "StoryWriter-workspace-tests-\(UUID().uuidString)"
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoryWriter-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testChapterAndSectionResumeAfterReorderingAndRecoverFromDeletion() throws {
        let root = try directory(), defaults = try defaults()
        let preferences = WorkspacePreferences(root: root, defaults: defaults)
        var project = StoryProject.new(title: "Resume", kind: .story)
        let second = Chapter(title: "Second")
        project.chapters.append(second)
        preferences.rememberChapter(second.id, in: project.id)
        preferences.rememberSection(.world, in: project.id)
        project.chapters.reverse()
        let reopened = WorkspacePreferences(root: root, defaults: defaults)
        XCTAssertEqual(reopened.chapterID(in: project), second.id)
        XCTAssertEqual(reopened.section(in: project.id), .world)
        project.chapters.removeAll { $0.id == second.id }
        XCTAssertEqual(reopened.chapterID(in: project), project.chapters.first?.id)
        project.chapters.removeAll()
        XCTAssertNil(reopened.chapterID(in: project))
    }

    func testNavigationIsIsolatedBetweenLibrariesAndProjects() throws {
        let defaults = try defaults(), root = try directory()
        let first = WorkspacePreferences(root: root.appendingPathComponent("one"), defaults: defaults)
        let second = WorkspacePreferences(root: root.appendingPathComponent("two"), defaults: defaults)
        let project = StoryProject.new(title: "Original", kind: .story)
        first.projectID = project.id
        first.rememberSection(.characters, in: project.id)
        first.rememberChapter(project.chapters[0].id, in: project.id)
        XCTAssertNil(second.projectID)
        XCTAssertEqual(second.section(in: project.id), .manuscript)
        var imported = project; imported.id = UUID(); imported.chapters.reverse()
        XCTAssertEqual(first.section(in: imported.id), .manuscript)
    }

    @MainActor func testLibraryReopensSelectedProjectAndFallsBackWhenArchived() throws {
        let root = try directory(), defaults = try defaults()
        let store = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        let first = store.create(title: "First", kind: .story)
        let second = store.create(title: "Second", kind: .story)
        store.selectedProjectID = first
        let reopened = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        XCTAssertEqual(reopened.selectedProjectID, first)
        reopened.update(first) { $0.archived = true }
        XCTAssertTrue(reopened.saveNow())
        let afterArchive = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        XCTAssertEqual(afterArchive.selectedProjectID, second)
    }

    @MainActor func testArchiveNavigationAndCreatingFromSearchKeepSelectionVisible() throws {
        let store = ProjectStore(root: try directory(), createExample: false, workspaceDefaults: try defaults())
        let archived = store.create(title: "Archived", kind: .story)
        store.update(archived) { $0.archived = true }
        let active = store.create(title: "Active", kind: .story)
        store.toggleArchivedProjects()
        XCTAssertEqual(store.selectedProjectID, archived)
        store.toggleArchivedProjects()
        XCTAssertEqual(store.selectedProjectID, active)
        store.toggleArchivedProjects(); store.search = "no match"
        let created = store.create(title: "New story", kind: .story)
        XCTAssertFalse(store.showArchived)
        XCTAssertTrue(store.search.isEmpty)
        XCTAssertEqual(store.selectedProjectID, created)
        XCTAssertTrue(store.visibleProjects.contains { $0.id == created })
        store.search = "  New story  "
        XCTAssertEqual(store.visibleProjects.map(\.id), [created])
        XCTAssertTrue(store.saveNow())
    }
}
