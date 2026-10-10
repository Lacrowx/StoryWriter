import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingProjects: [String] = []
    weak var store: ProjectStore? {
        didSet {
            guard let store else { return }
            for name in pendingProjects { store.importPackage(URL(fileURLWithPath: name)) }
            pendingProjects.removeAll()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.saveNow() else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Your latest changes have not been saved."
        alert.informativeText = "Keep StoryWriter open and try saving again, or quit and discard only the unsaved changes."
        alert.addButton(withTitle: "Keep Open"); alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for name in filenames where URL(fileURLWithPath: name).pathExtension == "storywriter" {
            if let store { store.importPackage(URL(fileURLWithPath: name)) }
            else { pendingProjects.append(name) }
        }
    }
}

@main
struct StoryWriterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ProjectStore()
    @StateObject private var updates = AppUpdates.shared
    var body: some Scene {
        Window("StoryWriter", id: "main") {
            LibraryView().environmentObject(store).tint(AppTheme.accent).accentColor(AppTheme.accent)
                .onAppear { delegate.store = store; updates.start() }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.checkForUpdates).disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Story…") { NotificationCenter.default.post(name: .newProject, object: ProjectKind.story) }.keyboardShortcut("n")
                Button("New Reference Collection…") { NotificationCenter.default.post(name: .newProject, object: ProjectKind.research) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { Panels.openProject(store) }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { _ = store.saveNow() }.keyboardShortcut("s")
                Button("Save Portable Copy…") { if let project = store.selectedProject { Panels.savePackage(project, store: store) } }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.selectedProject == nil)
                Button("Export Manuscript…") { NotificationCenter.default.post(name: .exportManuscript, object: nil) }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(store.selectedProject?.kind != .story)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Chapter…") {
                    let item = NSMenuItem(); item.tag = 1
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
                }.keyboardShortcut("f")
                Button("Bold") { NSApp.sendAction(#selector(ManuscriptTextView.toggleBoldface(_:)), to: nil, from: nil) }.keyboardShortcut("b")
                Button("Italic") { NSApp.sendAction(#selector(ManuscriptTextView.toggleItalics(_:)), to: nil, from: nil) }.keyboardShortcut("i")
                Button("Underline") { NSApp.sendAction(#selector(NSTextView.underline(_:)), to: nil, from: nil) }.keyboardShortcut("u")
            }
        }
        Settings { AppSettings() }
    }
}

enum AppTheme {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.52, green: 0.76, blue: 0.64, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.43, blue: 0.36, alpha: 1)
    })
}

extension Notification.Name {
    static let newProject = Notification.Name("StoryWriter.newProject")
    static let exportManuscript = Notification.Name("StoryWriter.exportManuscript")
}

@MainActor
enum Panels {
    static func openProject(_ store: ProjectStore) {
        let panel = NSOpenPanel(); panel.title = "Open a StoryWriter project"; panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "storywriter") ?? .directory]; panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { store.importPackage(url) }
    }
    static func savePackage(_ project: StoryProject, store: ProjectStore) {
        let panel = NSSavePanel(); panel.title = "Save a portable project copy"; panel.nameFieldStringValue = project.title.safeFilename + ".storywriter"
        panel.message = "Includes your writing, notes, reference files, and saved revisions. This copy is a snapshot; your library keeps autosaving on this Mac."
        panel.allowedContentTypes = [UTType(filenameExtension: "storywriter") ?? .package]; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.exportPackage(project.id, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    static func importSources(_ id: UUID, store: ProjectStore) {
        let panel = NSOpenPanel(); panel.title = "Add reference files"; panel.message = "Files are copied into your project and remain available when the originals move."
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { store.importFiles(panel.urls, projectID: id) }
    }
    static func importChapter(_ id: UUID, store: ProjectStore) {
        let panel = NSOpenPanel(); panel.title = "Import a chapter"
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd, .html, UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { store.importChapter(url, projectID: id) }
    }
}
