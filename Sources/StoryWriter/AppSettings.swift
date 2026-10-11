import SwiftUI
import AppKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", editor = "Editor", review = "Writing Review", storage = "Saving & Sync", updates = "Updates"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .general: return "gearshape"; case .appearance: return "paintpalette"; case .editor: return "textformat"; case .review: return "checkmark.bubble"; case .storage: return "externaldrive"; case .updates: return "arrow.down.circle" }
    }
    var subtitle: String {
        switch self {
        case .general: return "Choose how your workspace opens and what stays visible."
        case .appearance: return "Make the workspace and paper feel like your own."
        case .editor: return "Set your starting typography and typing assistance."
        case .review: return "Control local proofreading and name recognition."
        case .storage: return "Manage autosaving, recovery, backups, and sync."
        case .updates: return "Keep StoryWriter up to date."
        }
    }
    var resetKeys: [String] {
        switch self {
        case .general: return ["resumeWorkspace", "startInFocusMode", "showChapterOutline", "showStatusInFocus", "selectionQuickActions"]
        case .appearance: return ["appAppearance", "accentColor", "useTransparency", "paperTone", "paperTexture", "dimPaper", "readingWidth", "readingZoom", "paperMargins", "showPencilComments"]
        case .editor: return ["defaultFontName", "defaultFontSize", "defaultLineSpacing", "nativeSpellChecking", "nativeGrammarChecking", "automaticSpellingCorrection", "smartQuotes", "smartDashes", "detectWebLinks"]
        case .review: return []
        case .storage: return ["autosaveDelay", "revisionInterval", "backupInterval"]
        case .updates: return []
        }
    }
}

struct AppSettings: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var page: SettingsPage = .general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings").font(.title2.weight(.semibold)).padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 18)
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 13, weight: item == page ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(item == page ? Color.accentColor : .primary)
                            .background(item == page ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(item == page ? .isSelected : [])
                }
                Spacer()
                Text("Preferences stay on this Mac.").font(.caption).foregroundStyle(.secondary).padding(14)
            }.padding(.horizontal, 10).frame(width: 190).background(DesktopMaterial())
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.rawValue).font(.title2.weight(.semibold))
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                }.padding(24)
                Form {
                    switch page {
                    case .general: GeneralSettings()
                    case .appearance: AppearanceSettings()
                    case .editor: EditorSettings()
                    case .review: WritingReviewSettings()
                    case .storage: StorageSettings().environmentObject(store)
                    case .updates: UpdateSettings()
                    }
                }.formStyle(.grouped)
                if !page.resetKeys.isEmpty {
                    HStack {
                        Text("Changes apply automatically.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(page == .storage ? "Reset timing defaults" : "Reset \(page.rawValue.lowercased())") {
                            for key in page.resetKeys { UserDefaults.standard.removeObject(forKey: key) }
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 14)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(width: 820, height: 700)
    }
}

private struct GeneralSettings: View {
    @AppStorage("resumeWorkspace") private var resume = true
    @AppStorage("startInFocusMode") private var focus = false
    @AppStorage("showChapterOutline") private var outline = true
    @AppStorage("showStatusInFocus") private var status = true
    @AppStorage("selectionQuickActions") private var quickActions = true
    var body: some View {
        Section("On launch") {
            Toggle("Reopen the last project and workspace", isOn: $resume)
            Text("When off, StoryWriter opens the library with no project selected. Applies on the next launch.").settingsHint()
            Toggle("Start in focus mode", isOn: $focus)
            Text("Opens a selected story directly in Write with the sidebars hidden. Press ⇧⌘F to leave focus mode.").settingsHint()
        }
        Section("Workspace") {
            Toggle("Show the chapter outline", isOn: $outline)
            Toggle("Show save status and story progress in focus mode", isOn: $status)
            Text("Save failures, backup problems, and sync conflicts remain visible.").settingsHint()
            Toggle("Show quick actions when selecting a passage", isOn: $quickActions)
            Text("Formatting, comments, tags, and review stay available through menus and keyboard shortcuts.").settingsHint()
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("accentColor") private var accent = WriterAccent.sage.rawValue
    @AppStorage("useTransparency") private var transparency = true
    @AppStorage("paperTone") private var paper = PaperTone.warm.rawValue
    @AppStorage("paperTexture") private var texture = true
    @AppStorage("dimPaper") private var dim = false
    @AppStorage("readingWidth") private var width = ReadingWidth.medium.rawValue
    @AppStorage("readingZoom") private var zoom = 1.0
    @AppStorage("paperMargins") private var margins = PaperMargins.balanced.rawValue
    @AppStorage("showPencilComments") private var comments = true
    var body: some View {
        Section("Application") {
            Picker("Appearance", selection: $appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0.rawValue) } }.pickerStyle(.segmented)
            Picker("Accent color", selection: $accent) { ForEach(WriterAccent.allCases) { Text($0.rawValue).tag($0.rawValue) } }
            Toggle("Use translucent sidebars and glass controls", isOn: $transparency)
            Text("macOS Reduce Transparency takes priority over this setting.").settingsHint()
        }
        Section("Manuscript paper") {
            Picker("Paper color", selection: $paper) { ForEach(PaperTone.allCases) { Text($0.rawValue).tag($0.rawValue) } }.disabled(dim)
            Toggle("Dim paper for low-light writing", isOn: $dim)
            Toggle("Show paper grain", isOn: $texture)
            ZStack(alignment: .leading) {
                ManuscriptPaper()
                VStack(alignment: .leading, spacing: 7) {
                    Text("A place for your next sentence.").font(.custom("Georgia", size: 19))
                    Text("Paper preview · display only").font(.caption)
                }.foregroundStyle(dim ? Color(white: 0.87) : Color.black.opacity(0.8)).padding(20)
            }.frame(height: 94).clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Paper color, margins, and zoom affect your view. Exports keep the manuscript's own formatting.").settingsHint()
        }
        Section("Reading layout") {
            Picker("Reading width", selection: $width) { ForEach(ReadingWidth.allCases) { Text($0.rawValue).tag($0.rawValue) } }
            Picker("Display zoom", selection: $zoom) { ForEach([0.75, 0.9, 1.0, 1.1, 1.25, 1.5], id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) } }
            Picker("Paper margins", selection: $margins) { ForEach(PaperMargins.allCases) { Text($0.rawValue).tag($0.rawValue) } }
            Toggle("Show pencil comments beside passages", isOn: $comments)
        }
    }
}

private struct EditorSettings: View {
    @AppStorage("defaultFontName") private var font = "Georgia"
    @AppStorage("defaultFontSize") private var size = 18.0
    @AppStorage("defaultLineSpacing") private var spacing = 6.0
    private var typing = TypingPreferences()
    var body: some View {
        Section("Starting typography") {
            Picker("Font", selection: $font) {
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
            }
            Stepper("Font size: \(Int(size)) pt", value: $size, in: 10...32)
            Stepper("Extra line spacing: \(Int(spacing)) pt", value: $spacing, in: 0...16)
            Text("The next empty chapter and the Body text style use these defaults. Existing passages keep their fonts and spacing; change them with the formatting toolbar.").settingsHint()
            Text("The story begins with a single line.").font(Font(ApplicationPreferences().defaultFont)).padding(.vertical, 8)
        }
        Section("Mac typing assistance") {
            Toggle("Underline spelling mistakes", isOn: typing.$spelling)
            Toggle("Check grammar with macOS", isOn: typing.$grammar)
            Toggle("Correct spelling while typing", isOn: typing.$correction)
            Toggle("Use smart quotation marks", isOn: typing.$quotes)
            Toggle("Replace double hyphens with a dash", isOn: typing.$dashes)
            Toggle("Detect website links", isOn: typing.$links)
            Text("Applies to manuscript and planning fields. Local AI review is controlled separately in Writing Review.").settingsHint()
        }
    }
}

private struct WritingReviewSettings: View {
    @AppStorage("osaurusURL") private var baseURL = "http://127.0.0.1:1337/v1"
    @AppStorage("writingLanguage") private var language = "auto"
    @AppStorage("reviewDelay") private var delay = 2.0
    @AppStorage("discoverObjectNames") private var names = true
    @ObservedObject private var service = LocalGrammarService.shared
    var body: some View {
        Section("Language & review") {
            Picker("Spelling language", selection: $language) { Text("Detect English / German").tag("auto"); Text("English").tag("en"); Text("Deutsch").tag("de") }
            WritingBackendControls()
            Toggle("Check automatically after editing", isOn: $service.automatic)
            Stepper("Wait after typing: \(Int(delay)) seconds", value: $delay, in: 1...10).disabled(!service.automatic)
            Toggle("Suggest style improvements", isOn: $service.includeStyle)
            Text("Automatic checks review the changed paragraph. Proposed AI edits require your acceptance. Set a project's AI writing brief in its Story tab or project menu.").settingsHint()
        }
        Section("Character & world names") {
            Toggle("Suggest new characters and places while typing", isOn: $names)
            Text("Local name recognition adds purple marks and a new-names button. You can still tag existing characters and world entries with @ when this is off.").settingsHint()
        }
        if service.backend == .osaurus {
            Section("Osaurus connection") {
                TextField("Server address", text: $baseURL)
                Text("Start Osaurus's local server and select an installed model. StoryWriter connects only to localhost.").settingsHint()
                Button(service.connecting ? "Connecting…" : "Test connection") { Task { await service.connect() } }.disabled(service.connecting)
                if let message = service.message { Text(message).settingsHint() }
                if !service.models.isEmpty { Text("Connected · \(service.models.count) local model(s)").foregroundStyle(.green) }
                Link("Osaurus setup & documentation", destination: URL(string: "https://docs.osaurus.ai")!)
            }
        }
    }
}

private struct StorageSettings: View {
    @EnvironmentObject private var store: ProjectStore
    @AppStorage("autosaveDelay") private var delay = 0.7
    @AppStorage("revisionInterval") private var revisions = 300.0
    @AppStorage("backupInterval") private var backups = 300.0
    var body: some View {
        Section("Local library") {
            Text(store.root.path).font(.caption).textSelection(.enabled)
            Button("Show library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.root]) }
            Picker("Autosave after editing", selection: $delay) {
                Text("0.3 seconds").tag(0.3); Text("0.7 seconds (default)").tag(0.7); Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
            }
            Text("⌘S saves immediately. StoryWriter also saves before quitting.").settingsHint()
            Picker("Automatic revision interval", selection: $revisions) { timingOptions }
            Text("A recovery revision is kept on the next changed save after this interval. The latest 30 automatic revisions and all named revisions are retained.").settingsHint()
        }
        Section("Portable backups") {
            Picker("Minimum time between backups", selection: $backups) { timingOptions }
            Text("Applies to projects with a backup folder. Backups run after successful saves while the project changes; a first copy runs immediately after setup.").settingsHint()
            if let project = store.selectedProject {
                LabeledContent("Selected project", value: project.title)
                Text(store.backupStatus(project.id)).settingsHint()
                if let configuration = store.backupConfigurations[project.id] {
                    Text(configuration.folder).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Back up now") { if store.saveNow() { store.scheduleBackup(project.id, immediately: true) } }
                        Button("Change folder…") { store.chooseBackupFolder(project.id) }
                        Button("Turn off") { store.disableBackup(project.id) }
                    }
                } else { Button("Choose backup folder…") { store.chooseBackupFolder(project.id) } }
            } else { Text("Select a project in the library to configure its backup folder.").settingsHint() }
        }
        SyncSettings(sync: store.sync)
    }
    @ViewBuilder private var timingOptions: some View {
        Text("1 minute").tag(60.0); Text("5 minutes (default)").tag(300.0); Text("10 minutes").tag(600.0); Text("30 minutes").tag(1800.0)
    }
}

private extension View {
    func settingsHint() -> some View { font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}
