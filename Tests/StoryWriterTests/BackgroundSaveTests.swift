import XCTest
import AppKit
@testable import StoryWriter

final class BackgroundSaveTests: XCTestCase {
    @MainActor func testTypingBurstsAutosaveTogetherAndManualSaveStaysImmediate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutosaveBatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "AutosaveBatch-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0.3, forKey: "autosaveDelay")
        let store = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        let id = store.create(title: "Original", kind: .story)
        for index in 0..<3 {
            store.updateWhileTyping(id) { $0.premise = "Burst \(index)" }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).premise, "")
        }
        let deadline = Date().addingTimeInterval(12)
        while store.hasUnsavedChanges, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).premise, "Burst 2")
        store.updateWhileTyping(id) { $0.premise = "Manual save" }
        XCTAssertTrue(store.saveNow())
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).premise, "Manual save")
    }

    @MainActor func testScheduledBackupWaitsForAutosaveInsteadOfFlushingTyping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupDebounce-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Original", kind: .story)
        defer { store.disableBackup(id); UserDefaults.standard.removeObject(forKey: store.backupDefaultsKey) }
        try store.configureBackup(id, folder: folder)
        await store.backupTasks[id]?.value
        store.backupConfigurations[id]?.lastSuccess = .distantPast
        store.updateWhileTyping(id) { $0.premise = "Still typing" }
        store.scheduleBackup(id)
        await store.backupTasks[id]?.value
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).premise, "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count, 1)
        XCTAssertTrue(store.saveNow())
        await store.backupTasks[id]?.value
        let copies = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(try copies.map { try ProjectStore.readPackage($0).premise }.contains("Still typing"))
    }

    @MainActor func testReopeningKeepsAutomaticRevisionInterval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RevisionInterval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Original", kind: .story)
        store.update(id) { $0.title = "First draft" }; XCTAssertTrue(store.saveNow())
        XCTAssertEqual(store.revisions(id).count, 1)
        let reopened = ProjectStore(root: root, createExample: false)
        reopened.update(id) { $0.title = "Second draft" }; XCTAssertTrue(reopened.saveNow())
        XCTAssertEqual(reopened.revisions(id).count, 1)
        XCTAssertEqual(try ProjectStore.readPackage(reopened.packageURL(id)).title, "Second draft")
    }

    @MainActor func testChangingBackupFolderDuringSaveKeepsNewBackupScheduled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFolder = root.appendingPathComponent("old"), newFolder = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Backup", kind: .story)
        defer { store.disableBackup(id); UserDefaults.standard.removeObject(forKey: store.backupDefaultsKey) }
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "Writer paused")
        store.persistence.queue.async { started.fulfill(); gate.wait() }
        defer { gate.signal() }
        await fulfillment(of: [started], timeout: 2)
        store.update(id) { $0.premise = "Pending backup contents" }
        try store.configureBackup(id, folder: oldFolder)
        try await Task.sleep(nanoseconds: 20_000_000)
        try store.configureBackup(id, folder: newFolder)
        let latest = try XCTUnwrap(store.backupTasks[id])
        gate.signal()
        await latest.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: oldFolder, includingPropertiesForKeys: nil).isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(at: newFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try ProjectStore.readPackage(try XCTUnwrap(copies.first)).premise, "Pending backup contents")
        XCTAssertNotNil(store.backupConfigurations[id]?.lastSuccess)
    }

    @MainActor func testOlderCompletionDoesNotMarkNewerEditsSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PendingSave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Original", kind: .story)
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "Writer paused")
        store.persistence.queue.async { started.fulfill(); gate.wait() }
        defer { gate.signal() }
        await fulfillment(of: [started], timeout: 2)
        store.update(id) { $0.title = "First edit" }
        let saving = Task { await store.saveInBackground() }
        try await Task.sleep(nanoseconds: 20_000_000)
        store.update(id) { $0.title = "Edit during save" }
        gate.signal()
        let olderSuccess = await saving.value
        XCTAssertTrue(olderSuccess)
        XCTAssertEqual(store.saveStatus, "Saving…")
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).title, "First edit")
        let latestSuccess = await store.saveInBackground()
        XCTAssertTrue(latestSuccess)
        XCTAssertEqual(store.saveStatus, "Saved on this Mac")
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).title, "Edit during save")
    }

    @MainActor func testEditsDuringBackgroundSaveRemainPendingAndManualSaveWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundSave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Original", kind: .story)
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "Writer is blocked outside the main actor")
        store.persistence.queue.async { started.fulfill(); gate.wait() }
        defer { gate.signal() }
        await fulfillment(of: [started], timeout: 2)
        store.update(id) { $0.title = "Older snapshot" }
        let saving = Task { await store.saveInBackground() }
        // The writer is deliberately blocked. The main actor must still run.
        try await Task.sleep(nanoseconds: 20_000_000)
        store.update(id) { $0.title = "Newest draft" }
        XCTAssertEqual(store.saveStatus, "Saving…")
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).title, "Original")
        gate.signal()
        XCTAssertTrue(store.saveNow()) // Waits for the old writer, then writes the new snapshot.
        let success = await saving.value
        XCTAssertTrue(success)
        XCTAssertEqual(store.saveStatus, "Saved on this Mac")
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).title, "Newest draft")
    }

    @MainActor func testBackgroundFailureKeepsChangesForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SaveFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Original", kind: .story)
        let manifest = store.packageURL(id).appendingPathComponent("project.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        store.update(id) { $0.title = "Unsaved changes" }
        let failed = await store.saveInBackground()
        XCTAssertFalse(failed)
        XCTAssertEqual(store.saveStatus, "Save failed — retry with ⌘S")
        XCTAssertNotNil(store.errorMessage)
        try FileManager.default.removeItem(at: manifest)
        let retried = await store.saveInBackground()
        XCTAssertTrue(retried)
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).title, "Unsaved changes")
    }

    @MainActor func testBackgroundSavePreservesPreviousRevisionAndRichText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SaveRevision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Original", kind: .story)
        let text = NSMutableAttributedString(string: "Grüße 👩🏽‍💻", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        let reference = ProjectTagReference(kind: .world, objectID: UUID())
        text.addAttribute(.link, value: reference.url, range: NSRange(location: 0, length: 5))
        store.update(id) { $0.chapters[0].setEditingText(text); $0.title = "Edited" }
        let success = await store.saveInBackground()
        XCTAssertTrue(success)
        let saved = try ProjectStore.readPackage(store.packageURL(id))
        XCTAssertEqual(saved.chapters[0].plainText, text.string)
        XCTAssertEqual(ProjectTagReference.from(saved.chapters[0].attributedText.attribute(.link, at: 0, effectiveRange: nil)), reference)
        let revision = try XCTUnwrap(store.revisions(id).first)
        XCTAssertEqual(try store.revisionProject(revision, projectID: id).title, "Original")
    }

    @MainActor func testNovelAutosaveMainActorLatency() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SaveBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Novel", kind: .story)
        func edit() {
            store.updateWhileTyping(id) { project in
                project.chapters = (0..<25).map { index in
                    var chapter = Chapter(title: "Chapter \(index)")
                    chapter.setEditingText(NSAttributedString(string: String(repeating: "Mara waited by the fountain, counting the bells.\n", count: 500), attributes: WritingStyle.attributes))
                    return chapter
                }
            }
        }
        edit()
        let start = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(store.saveNow())
        let synchronous = (CFAbsoluteTimeGetCurrent() - start) * 1000
        edit()
        var finished = false, longest = 0.0, samples = 0
        let saving = Task { let result = await store.saveInBackground(); finished = true; return result }
        while !finished {
            let tick = CFAbsoluteTimeGetCurrent()
            try await Task.sleep(nanoseconds: 1_000_000)
            longest = max(longest, (CFAbsoluteTimeGetCurrent() - tick) * 1000)
            samples += 1
        }
        let success = await saving.value
        XCTAssertTrue(success)
        XCTAssertGreaterThan(samples, 1, "Main actor must run during the save")
        print(String(format: "Novel save: explicit save blocked %.2f ms; background save main-actor longest tick %.2f ms (%d ticks)", synchronous, longest, samples))
        XCTAssertEqual(try ProjectStore.readPackage(store.packageURL(id)).chapters.count, 25)
    }
}
