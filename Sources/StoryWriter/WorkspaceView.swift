import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case manuscript = "Write", overview = "Story", characters = "Characters", world = "World", references = "References"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .manuscript: return "pencil.line"; case .overview: return "book.closed"; case .characters: return "person.2"; case .world: return "globe.europe.africa"; case .references: return "tray.full" }
    }
}

extension ProjectStore {
    func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<StoryProject, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.project(id)?[keyPath: keyPath] ?? fallback }, set: { value in self.update(id) { $0[keyPath: keyPath] = value } })
    }
    func itemBinding<Item: Identifiable>(_ projectID: UUID, _ keyPath: WritableKeyPath<StoryProject, [Item]>, id: UUID, fallback: Item) -> Binding<Item> where Item.ID == UUID {
        Binding(get: { self.project(projectID)?[keyPath: keyPath].first { $0.id == id } ?? fallback }, set: { value in self.update(projectID) { project in if let index = project[keyPath: keyPath].firstIndex(where: { $0.id == id }) { project[keyPath: keyPath][index] = value } } })
    }
}

struct ProjectWorkspace: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.appContextCommands) private var libraryCommands
    @Environment(\.openSettings) private var openSettings
    var projectID: UUID
    @Binding var focusMode: Bool
    @State private var section: WorkspaceSection = .manuscript
    @State private var chapterID: UUID?
    @State private var showProofreader = false
    @State private var showChapterNotes = false
    @State private var showExport = false
    @State private var showHistory = false
    @State private var showRename = false
    @State private var showManuscriptReview = false
    @State private var showWritingBrief = false
    @State private var copied = false
    @State private var taggedObject: ProjectTagReference?
    @StateObject private var editor = EditorController()
    @StateObject private var reviewFocus = ReviewFocus()
    @ObservedObject private var grammarService = LocalGrammarService.shared
    @State private var showSearch = false
    @State private var showTimeline = false
    @State private var showPanel = false
    @State private var panelTab: WritingPanelTab = .research
    @State private var pinned: PinnedResearch?
    @State private var destination: StoryDestination?
    @State private var continuityRequest: ContinuityRequest?
    @State private var restoredNavigation = false
    @AppStorage("readingWidth") private var readingWidth = ReadingWidth.medium.rawValue
    @AppStorage("readingZoom") private var readingZoom = 1.0
    @AppStorage("dimPaper") private var dimPaper = false
    @AppStorage("showPencilComments") private var showPencilComments = true

    var body: some View {
        if let project = store.project(projectID) {
            VStack(spacing: 0) {
                if !focusMode {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.title).font(.system(size: 23, weight: .medium, design: .serif)).lineLimit(1)
                            Text(project.kind == .story ? (project.genre.isEmpty ? "Make room for your imagination." : project.genre) : "Your ideas, gathered in one place.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }.buttonStyle(.plain).help("Search passages and project notes · ⇧⌘G")
                        if project.kind == .story {
                            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up").padding(.horizontal, 14).padding(.vertical, 9) }.buttonStyle(.plain).writerGlass(radius: 18)
                        }
                        Menu {
                            ContextCommandItems(commands: menuContext(project).project)
                        } label: { WriterMenuLabel(title: "Project", symbol: "folder") }
                            .menuStyle(.borderlessButton).fixedSize().help("Project details, revisions, backups, and portable copies")
                    }.padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 16)
                    if project.kind == .story {
                        HStack(spacing: 3) {
                            ForEach(WorkspaceSection.allCases) { tab in
                                Button { section = tab } label: {
                                    Label(tab.rawValue, systemImage: tab.symbol).font(.system(size: 12, weight: section == tab ? .semibold : .regular)).padding(.horizontal, 14).padding(.vertical, 9)
                                        .foregroundStyle(section == tab ? Color.accentColor : .primary.opacity(0.7))
                                        .background(section == tab ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }.padding(5).writerGlass(radius: 23)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24).padding(.bottom, 18)
                    }
                }
                if section != .manuscript || project.kind == .research {
                    if let session = reviewFocus.session {
                        HStack(spacing: 12) { Text("Review: \(session.documentLabel)").font(.caption).foregroundStyle(.secondary); InlineGrammarBar(session: session) }.padding(.horizontal, 24)
                    } else { Text("Select a field to review its writing.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 8) }
                }
                Group {
                    if project.kind == .research { ReferencesView(projectID: projectID) }
                    else {
                        switch section {
                        case .manuscript: manuscript(project)
                        case .overview: StoryOverview(projectID: projectID)
                        case .characters: CharactersView(projectID: projectID)
                        case .world: WorldView(projectID: projectID)
                        case .references: ReferencesView(projectID: projectID)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 7) {
                    Image(systemName: store.saveStatus.hasPrefix("Saved") ? "checkmark.circle" : "arrow.triangle.2.circlepath").foregroundStyle(store.saveStatus.hasPrefix("Save failed") ? .red : .secondary)
                    Text(store.saveStatus)
                    SyncWorkspaceStatus(sync: store.sync, projectID: projectID)
                    if let backup = store.backupConfigurations[projectID] { Text("·"); Image(systemName: backup.error == nil ? "externaldrive.badge.checkmark" : "exclamationmark.triangle").foregroundStyle(backup.error == nil ? Color.secondary : .orange).help(store.backupStatus(projectID)); Text(backup.error == nil ? (backup.lastSuccess.map { "Backed up " + $0.formatted(date: .omitted, time: .shortened) } ?? "First backup pending") : "Backup needs attention").help(store.backupStatus(projectID)) }
                    Spacer()
                    if project.kind == .story { WritingProgressButton(project: project) }
                    else { Text("\(project.sources.count) references") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
            }
            .background(WriterBackdrop())
            .appContextMenu()
            .focusedSceneValue(\.workspaceMenus, menuContext(project))
            .environment(\.appContextCommands, { workspaceCommands(project) })
            .environment(\.chapterContextCommands, chapterCommands)
            .environment(\.changePassageComment, changeComment)
            .environment(\.reviewFocus, reviewFocus)
            .environment(\.navigateStory, navigate)
            .environment(\.storyDestination, destination)
            .environment(\.pinResearch, { value in pinned = value; showPanel = true; panelTab = .research; section = .manuscript })
            .environment(\.grammarNamespace, projectID.uuidString)
            .environment(\.writingReviewContext, project.reviewContext())
            .environment(\.tagObjects, project.tagObjects)
            .environment(\.openObjectTag, { pinned = .object($0); showPanel = true; panelTab = .research })
            .environment(\.ignoredObjectNames, project.ignoredObjectNames ?? [])
            .environment(\.ignoreObjectName, { store.ignoreObjectName($0, projectID: projectID) })
            .environment(\.createProjectObject, { name, kind in
                let reference = store.createObject(named: name, kind: kind, projectID: projectID)
                if section == .manuscript, let reference { pinned = .object(reference); showPanel = true; panelTab = .research } else { taggedObject = reference }
                return reference
            })
            .sheet(isPresented: $showSearch) { ProjectSearchSheet(projectID: projectID).environment(\.navigateStory, navigate) }
            .sheet(isPresented: $showTimeline) { TimelineSheet(projectID: projectID).environment(\.navigateStory, navigate) }
            .sheet(item: $continuityRequest) { request in ContinuityRecordSheet(projectID: projectID, request: request) }
            .onChange(of: section) { _, value in
                reviewFocus.activate(nil)
                if restoredNavigation { store.workspacePreferences.rememberSection(value, in: projectID) }
            }
            .onChange(of: chapterID) { _, value in
                if restoredNavigation { store.workspacePreferences.rememberChapter(value, in: projectID) }
            }
            .onChange(of: panelTab) { _, _ in reviewFocus.activate(nil) }
            .sheet(isPresented: $showExport) { ExportSheet(projectID: projectID, chapterID: chapterID) }
            .sheet(isPresented: $showHistory) { RevisionHistorySheet(projectID: projectID).environment(\.navigateStory, navigate) }
            .sheet(isPresented: $showRename) { RenameProjectSheet(projectID: projectID, initialTitle: project.title) }
            .sheet(isPresented: $showManuscriptReview) { ManuscriptReviewSheet(projectID: projectID, chapterID: $chapterID) }
            .sheet(isPresented: $showWritingBrief) { WritingBriefSheet(projectID: projectID, initialBrief: project.aiWritingBrief) }
            .sheet(item: $taggedObject) { reference in ProjectObjectDetailsSheet(projectID: projectID, reference: reference).environment(\.writingReviewContext, project.reviewContext()) }
            .onReceive(NotificationCenter.default.publisher(for: .exportManuscript)) { _ in if project.kind == .story { showExport = true } }
            .onAppear {
                guard !restoredNavigation else { return }
                chapterID = store.workspacePreferences.chapterID(in: project)
                section = project.kind == .research ? .references : store.workspacePreferences.section(in: projectID)
                restoredNavigation = true
            }
            .onChange(of: project.chapters.map(\.id)) { _, ids in if !ids.contains(chapterID ?? UUID()) { chapterID = ids.first } }
            .onChange(of: project.aiWritingBrief) { _, _ in
                if section == .manuscript, LocalGrammarService.shared.automatic {
                    editor.grammar?.context = project.reviewContext(chapter: project.chapters.first { $0.id == chapterID })
                    editor.grammar?.review(.document)
                }
            }
            .onExitCommand { focusMode = false }
        }
    }

    private func menuContext(_ project: StoryProject) -> WorkspaceMenus {
        let commands = workspaceCommands(project)
        func group(_ title: String) -> [ContextCommand] { commands.first { $0.title == title }?.children ?? [] }
        return WorkspaceMenus(project: group("Project"), writing: group("Writing tools"),
                              navigation: group("Go to"), display: group("Display"),
                              isStory: project.kind == .story, focusMode: focusMode,
                              search: { showSearch = true },
                              toggleFocus: { section = .manuscript; focusMode.toggle() })
    }

    private func sidebarCommands() -> [ContextCommand] {
        var commands = WritingPanelTab.allCases.map { tab in
            ContextCommand.button(tab == .comments ? "Revision comments" : tab.rawValue,
                                  checked: showPanel && !showProofreader && panelTab == tab,
                                  symbol: tab == .research ? "pin" : tab == .scenes ? "list.bullet.rectangle" : tab == .comments ? "text.bubble" : "person.crop.rectangle") {
                section = .manuscript; openPanel(tab)
            }
        }
        commands += [.separator, .button("Hide writing sidebar", enabled: showPanel) { showPanel = false }]
        return commands
    }

    private func reviewCommands() -> [ContextCommand] {
        let session = editor.grammar
        let currentChapter = section == .manuscript && editor.chapterID == chapterID && session?.view === editor.textView
        var commands: [ContextCommand] = [
            .button("Review panel", enabled: chapterID != nil, checked: showProofreader, symbol: "text.badge.checkmark") {
                section = .manuscript; showPanel = false; showProofreader.toggle()
            }, .separator
        ]
        for scope in GrammarScope.allCases {
            commands.append(.button(scope == .document ? "Review current chapter" : "Review " + scope.rawValue.lowercased(),
                                    enabled: currentChapter && !(session?.view?.string.isEmpty ?? true) && (scope != .selection || editor.selectionRange.length > 0)) {
                session?.review(scope, selection: editor.selectionRange)
            })
        }
        commands += [.button("Review entire manuscript…", symbol: "book.closed") { section = .manuscript; showManuscriptReview = true }, .separator,
                     .button("Automatic review", checked: grammarService.automatic) { grammarService.automatic.toggle() },
                     .button("Include style suggestions", checked: grammarService.includeStyle) { grammarService.includeStyle.toggle() },
                     .button("Review settings…", symbol: "gearshape") { openSettings() }]
        return commands
    }

    private func workspaceCommands(_ project: StoryProject) -> [ContextCommand] {
        var commands: [ContextCommand] = []
        if project.kind == .story {
            commands.append(.submenu("Go to", WorkspaceSection.allCases.map { target in
                .button(target.rawValue, checked: section == target, symbol: target.symbol) { focusMode = false; section = target }
            }))
            commands.append(.submenu("Writing tools", [
                .button("New chapter", symbol: "doc.badge.plus") { section = .manuscript; addChapter() },
                .button("Import chapter…", symbol: "square.and.arrow.down") { Panels.importChapter(projectID, store: store); section = .manuscript }, .separator,
                .submenu("Writing sidebar", sidebarCommands(), symbol: "sidebar.right"),
                .button("Chapter notes", enabled: chapterID != nil, checked: showChapterNotes, symbol: "note.text") { section = .manuscript; showChapterNotes.toggle() },
                .button("Story timeline…", symbol: "calendar") { showTimeline = true }, .separator,
                .submenu("Review writing", reviewCommands(), symbol: "text.badge.checkmark")
            ]))
            commands.append(.button(focusMode ? "Exit focus mode" : "Enter focus mode", checked: focusMode) { section = .manuscript; focusMode.toggle() })
            commands.append(.submenu("Display", [
                .submenu("Reading width", ReadingWidth.allCases.map { width in
                    .button(width.rawValue, checked: readingWidth == width.rawValue) { readingWidth = width.rawValue }
                }),
                .submenu("Display zoom", [0.75, 0.9, 1.0, 1.1, 1.25, 1.5].map { zoom in
                    .button("\(Int(zoom * 100))%", checked: abs(readingZoom - zoom) < 0.001) { readingZoom = zoom }
                }), .separator,
                .button("Dim paper", checked: dimPaper) { dimPaper.toggle() },
                .button("Pencil comments on page", checked: showPencilComments) { showPencilComments.toggle() }
            ]))
        }
        commands.append(.button("Search project…", symbol: "magnifyingglass") { showSearch = true })
        var projectCommands: [ContextCommand] = [
            .button("Rename project…", symbol: "pencil") { showRename = true },
            .button("AI writing brief…", symbol: "text.alignleft") { showWritingBrief = true }
        ]
        if !(project.ignoredObjectNames ?? []).isEmpty {
            projectCommands.append(.button("Suggest ignored names again") { store.update(projectID) { $0.ignoredObjectNames = nil } })
        }
        projectCommands += [.separator,
            .button("Save now", symbol: "checkmark.circle") { _ = store.saveNow() },
            .button("Save portable copy…", symbol: "externaldrive") { if let current = store.project(projectID) { Panels.savePackage(current, store: store) } },
            .button("Add reference files…", symbol: "tray.and.arrow.down") { Panels.importSources(projectID, store: store) }
        ]
        if project.kind == .story { projectCommands.append(.button("Export manuscript…", symbol: "square.and.arrow.up") { showExport = true }) }
        projectCommands += [.separator, .submenu("Saved revisions", [
            .button("Browse saved revisions…", symbol: "clock.arrow.circlepath") { if store.saveNow() { showHistory = true } },
            .button("Create checkpoint", symbol: "bookmark") { do { if store.saveNow() { try store.checkpoint(projectID) } } catch { store.errorMessage = error.localizedDescription } }
        ], symbol: "clock.arrow.circlepath")]
        var backups: [ContextCommand] = [.button("Choose backup folder…") { store.chooseBackupFolder(projectID) }]
        if store.backupConfigurations[projectID] != nil {
            backups += [.button(store.backupStatus(projectID), enabled: false) {}, .separator,
                        .button("Back up now") { store.scheduleBackup(projectID, immediately: true) },
                        .button("Turn off automatic backups") { store.disableBackup(projectID) }]
        }
        projectCommands += [.submenu("Automatic backups", backups, symbol: "externaldrive.badge.checkmark"),
                            .submenu("Sync across Macs", [
                                .button("Choose sync folder…") { store.sync.chooseFolder() },
                                .button("Sync now", enabled: store.sync.folder != nil) { Task { await store.sync.checkNow() } },
                                .button("Review conflicting changes…", enabled: store.sync.reviews[projectID] != nil) { store.sync.reviewProjectID = projectID }
                            ], symbol: "icloud"),
                            .button("Show project in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([store.packageURL(projectID)]) }, .separator,
                            .button(project.archived ? "Restore to library" : "Archive project", symbol: "archivebox") {
                                store.update(projectID) { $0.archived.toggle() }; store.selectedProjectID = store.visibleProjects.first?.id
                            }]
        commands.append(.submenu("Project", projectCommands))
        commands += [.separator] + libraryCommands()
        return commands
    }

    private func chapterCommands(_ id: UUID, _ range: NSRange, _ expectedText: String) -> [ContextCommand] {
        guard let chapter = store.project(projectID)?.chapters.first(where: { $0.id == id }), chapter.plainText == expectedText else { return [] }
        return [
            .button("Add comment to selection", enabled: range.length > 0) { addComment(chapterID: id, range: range, expectedText: expectedText) },
            .submenu("Track a character change", continuityCommands(chapter: chapter, range: range, expectedText: expectedText)),
            .button("Split scene here", enabled: range.location > 0 && range.location < expectedText.utf16.count) {
                guard var current = store.project(projectID)?.chapters.first(where: { $0.id == id }), current.plainText == expectedText else { return }
                do {
                    guard store.saveNow() else { return }; try store.checkpoint(projectID)
                    try current.splitScene(at: range.location)
                    store.update(projectID) { project in if let index = project.chapters.firstIndex(where: { $0.id == id }) { project.chapters[index] = current } }
                    showPanel = true; panelTab = .scenes
                } catch { store.errorMessage = error.localizedDescription }
            },
            .submenu("Chapter status", DraftStatus.allCases.map { status in
                .button(status.rawValue, checked: chapter.status == status) { store.update(projectID) { project in if let index = project.chapters.firstIndex(where: { $0.id == id }) { project.chapters[index].status = status } } }
            }),
            .button("Copy formatted chapter for website") {
                guard let current = store.project(projectID)?.chapters.first(where: { $0.id == id }) else { return }
                do { try ExportService.copyForWebsite(current) } catch { store.errorMessage = error.localizedDescription }
            }, .separator
        ]
    }

    private func continuityCommands(chapter: Chapter, range: NSRange, expectedText: String) -> [ContextCommand] {
        guard let project = store.project(projectID) else { return [] }
        let viewpoint = Continuity.viewpoint(in: chapter, offset: range.location)
        let person = project.characters.first { $0.id == viewpoint } ?? project.characters.first
        guard let person else { return [.button("Add a character in Characters first", enabled: false) {}] }
        return [(.knowledge, ContinuityAction.learns, "learns this"), (.possession, .gets, "gets this"), (.task, .assigned, "needs to do this"), (.rule, .applies, "must follow this")].map { category, action, phrase in
            .button("\(person.name) \(phrase)…") {
                continuityRequest = ContinuityRequest(chapterID: chapter.id, range: range, expectedText: expectedText, characterID: person.id, category: category, action: action)
                showProofreader = false; showPanel = true; panelTab = .continuity
            }
        } + [.separator, .button("Choose another character…") {
            continuityRequest = ContinuityRequest(chapterID: chapter.id, range: range, expectedText: expectedText)
            showProofreader = false; showPanel = true; panelTab = .continuity
        }]
    }

    private func addComment(chapterID: UUID, range: NSRange, expectedText: String) {
        guard var chapter = store.project(projectID)?.chapters.first(where: { $0.id == chapterID }), chapter.plainText == expectedText else { return }
        do {
            try chapter.addComment(range: range, note: "")
            guard let last = chapter.comments?.indices.last else { return }
            chapter.comments?[last].ink = CommentInk.allCases[last % CommentInk.allCases.count]
            let id = chapter.comments?[last].id
            store.update(projectID) { project in if let c = project.chapters.firstIndex(where: { $0.id == chapterID }) { project.chapters[c] = chapter } }
            showPencilComments = true; editor.pendingCommentFocus = id
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func changeComment(_ chapterID: UUID, _ commentID: UUID, _ change: PencilCommentChange) {
        store.update(projectID) { project in
            guard let c = project.chapters.firstIndex(where: { $0.id == chapterID }), let n = project.chapters[c].comments?.firstIndex(where: { $0.id == commentID }) else { return }
            switch change {
            case .note(let text): project.chapters[c].comments?[n].note = text
            case .resolved(let resolved): project.chapters[c].comments?[n].resolved = resolved
            case .ink(let ink): project.chapters[c].comments?[n].ink = ink
            }
        }
    }

    @ViewBuilder private func manuscript(_ project: StoryProject) -> some View {
        GeometryReader { workspaceGeometry in
        HStack(spacing: 0) {
            if !focusMode && !showProofreader && (!showPanel || workspaceGeometry.size.width >= 1090) {
                ChapterOutline(projectID: projectID, selection: $chapterID, onNavigate: navigate).frame(width: 215)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.06)))
                    .padding(.leading, 12).padding(.bottom, 8)
            }
            if let chapter = project.chapters.first(where: { $0.id == chapterID }) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        WritingTextArea(text: store.itemBinding(projectID, \.chapters, id: chapter.id, fallback: chapter).title, height: 28, label: "chapter title", fontSize: 17, compact: true, chrome: true).environment(\.grammarNamespace, chapter.id.uuidString)
                        Spacer(minLength: 0)
                        ViewThatFits(in: .horizontal) {
                            chapterToolbar(chapter, compact: false)
                            chapterToolbar(chapter, compact: true)
                        }
                    }.buttonStyle(.plain).padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 10)
                    if showChapterNotes {
                        HStack(alignment: .top, spacing: 16) {
                            WritingTextArea(text: store.itemBinding(projectID, \.chapters, id: chapter.id, fallback: chapter).synopsis, height: 50, label: "synopsis", compact: true).environment(\.grammarNamespace, chapter.id.uuidString)
                            Picker("Status", selection: store.itemBinding(projectID, \.chapters, id: chapter.id, fallback: chapter).status) { ForEach(DraftStatus.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 120)
                        }.padding(.horizontal, 24).padding(.bottom, 16)
                    }
                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                FormattingBar(editor: editor, compact: geometry.size.width < 720)
                                Menu {
                                    ContextCommandItems(commands: menuContext(project).display)
                                } label: { WriterMenuLabel(title: "Display", symbol: "text.magnifyingglass") }.menuStyle(.borderlessButton).fixedSize().padding(.trailing, 16).help("Reading width, display zoom, and paper color")
                            }.frame(minWidth: max(680, geometry.size.width))
                        }
                    }.frame(height: 44).writerGlass(radius: 20)
                        .padding(.horizontal, 20).padding(.bottom, 14)
                    GeometryReader { geometry in
                    EditorWithLanguage(chapter: store.itemBinding(projectID, \.chapters, id: chapter.id, fallback: chapter), controller: editor, onError: { store.errorMessage = $0 })
                        .environment(\.writingReviewContext, project.reviewContext(chapter: chapter)).id(chapter.id)
                        .frame(width: min(geometry.size.width, (ReadingWidth(rawValue: readingWidth) ?? .medium).points), height: geometry.size.height)
                        .background(ManuscriptPaper())
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(dimPaper ? 0.12 : 0.7), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 9)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }.padding(.horizontal, 20).padding(.bottom, 14)
                    VStack(spacing: 0) {
                        if let session = editor.objectNames { ObjectNameBar(session: session) }
                        if let session = reviewFocus.session { HStack { Text(session.documentLabel).font(.caption).foregroundStyle(.secondary); InlineGrammarBar(session: session) }.padding(.leading, 12) }
                        else if let session = editor.grammar { InlineGrammarBar(session: session) }
                    }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                    HStack {
                        Text("\(chapter.wordCount.formatted()) words")
                        if editor.selectionWords > 0 { Text("· \(editor.selectionWords) selected") }
                        Spacer()
                        Menu {
                            ForEach(DraftStatus.allCases) { status in
                                Button {
                                    store.update(projectID) { if let index = $0.chapters.firstIndex(where: { $0.id == chapter.id }) { $0.chapters[index].status = status } }
                                } label: { Label(status.rawValue, systemImage: chapter.status == status ? "checkmark" : status.symbol) }
                            }
                        } label: { Label(chapter.status.rawValue, systemImage: chapter.status.symbol).foregroundStyle(chapter.status.color) }
                            .menuStyle(.borderlessButton).fixedSize().help("Change chapter status")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 10)
                }.frame(maxWidth: .infinity)
                if showProofreader { Divider(); ProofreadingPanel(editor: editor, chapter: chapter) }
                else if showPanel { Divider(); WritingSidePanel(projectID: projectID, chapterID: chapterID, editor: editor, tab: $panelTab, pinned: $pinned) { showPanel = false } }
            } else {
                EmptyWorkspace(symbol: "doc.badge.plus", title: "Make space for the first chapter", subtitle: "Plan a chapter, then let the writing begin.", action: "Add chapter") { addChapter() }
            }
        }
        }
    }
    private func chapterToolbar(_ chapter: Chapter, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu { ContextCommandItems(commands: chapterMenu(chapter)) } label: {
                WriterMenuLabel(title: "Chapter", symbol: "doc.text", active: showChapterNotes, compact: compact)
            }.help("Chapter notes, status, comments, and copy for website")
            Menu { ContextCommandItems(commands: sidebarCommands()) } label: {
                WriterMenuLabel(title: "Sidebar", symbol: "sidebar.right", active: showPanel, compact: compact)
            }.help("Research, scenes, comments, and character continuity")
            Menu { ContextCommandItems(commands: reviewCommands()) } label: {
                WriterMenuLabel(title: "Review", symbol: "text.badge.checkmark", active: showProofreader, compact: compact)
            }.help("Review the chapter or manuscript, and configure automatic review")
            Divider().frame(height: 18)
            Button { focusMode.toggle() } label: {
                WriterMenuLabel(title: focusMode ? "Exit focus" : "Focus",
                                symbol: focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                active: focusMode, compact: compact)
            }.help("Focus mode · ⇧⌘F")
        }.menuStyle(.borderlessButton).buttonStyle(.plain).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 7).writerGlass(radius: 16)
    }

    private func chapterMenu(_ chapter: Chapter) -> [ContextCommand] {
        [
            .button("Chapter notes", checked: showChapterNotes, symbol: "note.text") { showChapterNotes.toggle() },
            .submenu("Draft status", DraftStatus.allCases.map { status in
                .button(status.rawValue, checked: chapter.status == status, symbol: status.symbol) {
                    store.update(projectID) { if let index = $0.chapters.firstIndex(where: { $0.id == chapter.id }) { $0.chapters[index].status = status } }
                }
            }, symbol: chapter.status.symbol), .separator,
            .button("Add comment to selection", enabled: editor.selectionRange.length > 0 && editor.chapterID == chapter.id, symbol: "text.bubble") {
                if let view = editor.textView { addComment(chapterID: chapter.id, range: view.selectedRange(), expectedText: view.string) }
            },
            .button(copied ? "Copied for website" : "Copy formatted chapter for website", symbol: copied ? "checkmark" : "doc.on.clipboard") {
                guard let current = store.project(projectID)?.chapters.first(where: { $0.id == chapter.id }) else { return }
                do {
                    try ExportService.copyForWebsite(current); copied = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                } catch { store.errorMessage = error.localizedDescription }
            }
        ]
    }

    private func navigate(_ target: StoryDestination) {
        destination = target
        focusMode = false
        switch target.kind {
        case .chapter: section = .manuscript; chapterID = target.itemID; if target.field == "synopsis" { showChapterNotes = true }
        case .character: section = .characters
        case .world: section = .world
        case .reference: section = .references
        }
    }
    private func openPanel(_ tab: WritingPanelTab) {
        showProofreader = false; showPanel = true; panelTab = tab
    }
    private func addChapter() { let chapter = Chapter(title: "Chapter \((store.project(projectID)?.chapters.count ?? 0) + 1)"); store.update(projectID) { $0.chapters.append(chapter) }; chapterID = chapter.id }
}

struct EditorWithLanguage: View {
    @Binding var chapter: Chapter
    @ObservedObject var controller: EditorController
    var onError: (String) -> Void
    @AppStorage("writingLanguage") private var language = "auto"
    var body: some View { RichTextEditor(chapter: $chapter, controller: controller, language: language, onError: onError) }
}

struct ChapterOutline: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Binding var selection: UUID?
    var onNavigate: (StoryDestination) -> Void = { _ in }
    @State private var deleteID: UUID?
    @State private var search = ""
    @State private var statusFilter: DraftStatus?
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CHAPTERS").font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Menu { Button("Add chapter", action: add); Button("Import chapter…") { Panels.importChapter(projectID, store: store) } } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 20).help("Add or import a chapter")
            }.padding(18)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in manuscript", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear manuscript search").accessibilityLabel("Clear manuscript search")
                }
            }.font(.caption).padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12).padding(.bottom, 10)
            if let project = store.project(projectID) {
                Menu {
                    Button { statusFilter = nil } label: { Label("All chapters", systemImage: statusFilter == nil ? "checkmark" : "line.3.horizontal.decrease") }
                    Divider()
                    ForEach(DraftStatus.allCases) { status in
                        Button { statusFilter = status } label: {
                            Label("\(status.rawValue) (\(project.chapters.filter { $0.status == status }.count))", systemImage: statusFilter == status ? "checkmark" : status.symbol)
                        }
                    }
                } label: {
                    HStack {
                        Label(statusFilter?.rawValue ?? "All chapters", systemImage: statusFilter?.symbol ?? "line.3.horizontal.decrease")
                        Spacer()
                        Text(project.chapters.filter { statusFilter == nil || $0.status == statusFilter }.count.formatted()).foregroundStyle(.secondary)
                    }.font(.caption)
                }.menuStyle(.borderlessButton).padding(.horizontal, 18).padding(.bottom, 10).help("Filter chapters by drafting status")
                if !query.isEmpty {
                    let results = StorySearch.results(in: project, query: query, manuscriptOnly: true).filter { result in
                        statusFilter == nil || project.chapters.first(where: { $0.id == result.destination.itemID })?.status == statusFilter
                    }
                    Text("\(results.count) \(results.count == 1 ? "match" : "matches")").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
                    if results.isEmpty { noMatches }
                    else {
                        ScrollView { LazyVStack(alignment: .leading) { ForEach(results) { result in Button { onNavigate(result.destination) } label: { PassageResultRow(result: result, query: query) }.buttonStyle(.plain).padding(.horizontal, 16); Divider() } } }
                    }
                } else {
                let chapters = Array(project.chapters.enumerated()).filter { statusFilter == nil || $0.element.status == statusFilter }
                if chapters.isEmpty { noMatches }
                else {
                List(selection: $selection) {
                    ForEach(chapters, id: \.element.id) { index, chapter in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(String(format: "%02d", index + 1)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor); Spacer(); Label(chapter.status.rawValue, systemImage: chapter.status.symbol).font(.system(size: 9, weight: .medium)).foregroundStyle(chapter.status.color) }
                            Text(chapter.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            if !chapter.synopsis.isEmpty { Text(chapter.synopsis).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                            Text("\(chapter.wordCount.formatted()) words").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 8).tag(chapter.id)
                            .contextMenu {
                                ForEach(DraftStatus.allCases) { status in Button("Mark \(status.rawValue.lowercased())") { store.update(projectID) { if let i = $0.chapters.firstIndex(where: { $0.id == chapter.id }) { $0.chapters[i].status = status } } } }
                                Divider()
                                Button("Move up") { move(chapter.id, offset: -1) }.disabled(index == 0)
                                Button("Move down") { move(chapter.id, offset: 1) }.disabled(index == project.chapters.count - 1)
                                Button("Duplicate chapter") { var copy = chapter; copy.id = UUID(); copy.title += " (copy)"; if var scenes = copy.scenes { for i in scenes.indices { scenes[i].id = UUID() }; copy.scenes = scenes }; if var comments = copy.comments { for i in comments.indices { comments[i].id = UUID() }; copy.comments = comments }; if var events = copy.continuityEvents { for i in events.indices { events[i].id = UUID() }; copy.continuityEvents = events }; store.update(projectID) { $0.chapters.insert(copy, at: index + 1) }; selection = copy.id }
                                Divider(); Button("Delete chapter…", role: .destructive) { deleteID = chapter.id }
                                Divider(); AppContextMenuItems()
                            }.moveDisabled(statusFilter != nil)
                    }.onMove { offsets, destination in
                        guard statusFilter == nil else { return }
                        store.update(projectID) { $0.chapters.move(fromOffsets: offsets, toOffset: destination) }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                }
                }
            }
            Button(action: add) { Label("Add chapter", systemImage: "plus") }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(18)
        }.background(DesktopMaterial())
        .confirmationDialog("Delete this chapter? Saved revisions can recover earlier writing.", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) { Button("Delete chapter", role: .destructive) { if let deleteID { store.update(projectID) { $0.chapters.removeAll { $0.id == deleteID } } }; deleteID = nil } }
    }
    private var noMatches: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(.secondary)
            Text(query.isEmpty && statusFilter == nil ? "No chapters yet" : "No matching chapters").font(.callout)
            Text(query.isEmpty ? "Add a chapter or choose another status." : "Try another phrase or chapter status.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !query.isEmpty || statusFilter != nil {
                Button("Show all chapters") { search = ""; statusFilter = nil }.buttonStyle(.link).font(.caption)
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func add() { search = ""; statusFilter = nil; let chapter = Chapter(title: "Chapter \((store.project(projectID)?.chapters.count ?? 0) + 1)"); store.update(projectID) { $0.chapters.append(chapter) }; selection = chapter.id }
    private func move(_ id: UUID, offset: Int) { store.update(projectID) { project in guard let index = project.chapters.firstIndex(where: { $0.id == id }), project.chapters.indices.contains(index + offset) else { return }; project.chapters.swapAt(index, index + offset) } }
}

struct StoryOverview: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    var body: some View {
        if let project = store.project(projectID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SectionHeading(title: "The story at a glance", subtitle: "Keep the heart of your story close to the writing.")
                    HStack(spacing: 16) {
                        MetricCard(value: project.wordCount.formatted(), label: "Words written", symbol: "text.word.spacing")
                        MetricCard(value: "\(project.chapters.count)", label: "Chapters", symbol: "doc.text")
                        MetricCard(value: "\(project.characters.count)", label: "Characters", symbol: "person.2")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Writing goal").font(.headline); Spacer(); Text(project.targetWords > 0 ? "\(project.wordCount.formatted()) of \(project.targetWords.formatted()) words" : "No word goal").foregroundStyle(.secondary).font(.caption) }
                        if project.targetWords > 0 { ProgressView(value: min(1, Double(project.wordCount) / Double(project.targetWords))) }
                        HStack {
                            Text("Target").foregroundStyle(.secondary)
                            TextField("Words", value: Binding(get: { project.targetWords }, set: { value in store.update(projectID) { $0.targetWords = max(0, value) } }), format: .number).frame(width: 100).textFieldStyle(.roundedBorder)
                            Text("words · 0 for no goal").foregroundStyle(.secondary)
                        }.font(.caption)
                    }.cardSurface()
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) { LabeledField("Title", text: bind(\.title, project)); LabeledField("Genre", text: bind(\.genre, project), placeholder: "Mystery, fantasy, romance…") }.frame(maxWidth: .infinity)
                        VStack(spacing: 18) { LabeledField("Author / pen name", text: bind(\.author, project)); LabeledField("Audience", text: bind(\.audience, project), placeholder: "Who are you writing for?") }.frame(maxWidth: .infinity)
                    }.cardSurface()
                    NoteField("Premise", hint: "The central idea, in a sentence or two.", text: bind(\.premise, project), height: 85)
                    NoteField("Synopsis", hint: "The whole story, including the ending.", text: bind(\.synopsis, project), height: 160)
                    NoteField("Themes & tone", hint: "The questions and feelings running through your story.", text: bind(\.themes, project), height: 85)
                    NoteField("AI writing brief", hint: "Tell the local model what you are writing and how it should sound: tone, point of view, tense, pacing, dialogue, and wording to avoid. Reviews include this brief and story, character and world summaries. Up to 3,000 brief characters are used with Osaurus, or 1,500 with Apple's model.", text: bind(\.aiWritingBrief, project), height: 180)
                    NoteField("Publishing notes", hint: "Platforms, content notices, chapter schedule, blurb, and tags.", text: bind(\.publishingNotes, project), height: 120)
                }.padding(30).frame(maxWidth: 940)
            }.frame(maxWidth: .infinity)
        }
    }
    private func bind(_ keyPath: WritableKeyPath<StoryProject, String>, _ project: StoryProject) -> Binding<String> { store.binding(projectID, keyPath, fallback: project[keyPath: keyPath]) }
}

struct ExportSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    var chapterID: UUID?
    @State private var format: ExportFormat = .docx
    @State private var scope = "story"
    @State private var exporting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Ready to share", systemImage: "square.and.arrow.up").font(.system(size: 25, weight: .medium, design: .serif))
            Text("Export a clean manuscript. Planning notes and references stay in your project.").foregroundStyle(.secondary)
            Picker("Include", selection: $scope) { Text("Whole story").tag("story"); Text("Current chapter").tag("chapter") }.pickerStyle(.segmented).disabled(chapterID == nil)
            Picker("Format", selection: $format) { ForEach(ExportFormat.allCases) { Text("\($0.rawValue) (.\($0.fileExtension))").tag($0) } }
            Text(format.explanation).font(.callout).foregroundStyle(.secondary).frame(height: 45, alignment: .top)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(exporting ? "Exporting…" : "Export…", action: export).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(exporting) }
        }.padding(30).frame(width: 490)
    }
    private func export() {
        guard let project = store.project(projectID) else { return }
        let chapters = scope == "chapter" ? project.chapters.filter { $0.id == chapterID } : project.chapters
        let name = scope == "chapter" ? chapters.first?.title ?? project.title : project.title
        let panel = NSSavePanel(); panel.nameFieldStringValue = name.safeFilename + "." + format.fileExtension; panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        do { try ExportService.export(project: project, chapters: chapters, format: format, to: url); dismiss(); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { store.errorMessage = error.localizedDescription }
        exporting = false
    }
}

struct SectionHeading: View {
    var title: String
    var subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 26, weight: .medium, design: .serif)); Text(subtitle).font(.callout).foregroundStyle(.secondary) } }
}
struct MetricCard: View {
    var value: String
    var label: String
    var symbol: String
    var body: some View { VStack(alignment: .leading, spacing: 12) { Image(systemName: symbol).foregroundStyle(Color.accentColor); Text(value).font(.system(size: 26, weight: .medium, design: .serif)); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).cardSurface() }
}
struct LabeledField: View {
    var title: String
    @Binding var text: String
    var placeholder: String
    init(_ title: String, text: Binding<String>, placeholder: String = "") { self.title = title; self._text = text; self.placeholder = placeholder }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            WritingTextArea(text: $text, height: 30, label: title.lowercased(), compact: true)
                .overlay(alignment: .topLeading) { if text.isEmpty && !placeholder.isEmpty { Text(placeholder).font(.system(size: 14)).foregroundStyle(.tertiary).padding(.leading, 12).padding(.top, 8).allowsHitTesting(false) } }
        }.frame(maxWidth: .infinity, alignment: .leading).id(title.lowercased())
    }
}
struct NoteField: View {
    var title: String
    var hint: String
    @Binding var text: String
    var height: CGFloat = 120
    init(_ title: String, hint: String, text: Binding<String>, height: CGFloat = 120) { self.title = title; self.hint = hint; self._text = text; self.height = height }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(hint).font(.caption).foregroundStyle(.secondary)
            WritingTextArea(text: $text, height: height, label: title.lowercased())
        }.frame(maxWidth: .infinity, alignment: .leading).id(title.lowercased())
    }
}
struct EmptyWorkspace: View {
    var symbol: String, title: String, subtitle: String, action: String
    var perform: () -> Void
    var body: some View { VStack(spacing: 15) { Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(Color.accentColor); Text(title).font(.system(size: 23, weight: .medium, design: .serif)); Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center); Button(action, action: perform).buttonStyle(.borderedProminent) }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
extension View {
    func cardSurface() -> some View { padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06))) }
}

