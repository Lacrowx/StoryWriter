import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.openSettings) private var openSettings
    @State private var newKind: ProjectKind?
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var focusMode = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "book.pages").font(.system(size: 24)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) { Text("StoryWriter").font(.system(size: 19, weight: .semibold, design: .serif)); Text("A home for your stories").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search library", text: $store.search).textFieldStyle(.plain)
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear library search").accessibilityLabel("Clear library search")
                    }
                }
                    .padding(.horizontal, 12).padding(.vertical, 10).writerGlass(radius: 14).padding(.horizontal, 16).padding(.bottom, 20)
                HStack {
                    Text(store.showArchived ? "ARCHIVED" : "YOUR LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("New story") { newKind = .story }
                        Button("New reference collection") { newKind = .research }
                        Divider(); Button("Open project…") { Panels.openProject(store) }
                    } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 20).help("Create or open a project")
                }.padding(.horizontal, 20).padding(.bottom, 6)
                List(selection: $store.selectedProjectID) {
                    ForEach(store.visibleProjects) { project in
                        ProjectRow(project: project).tag(project.id)
                            .contextMenu {
                                Button("Save portable copy…") { Panels.savePackage(project, store: store) }
                                Button(project.archived ? "Restore to library" : "Archive project") { store.update(project.id) { $0.archived.toggle() }; if project.id == store.selectedProjectID { store.selectedProjectID = store.visibleProjects.first?.id } }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.packageURL(project.id)]) }
                                Divider()
                                ContextCommandItems(commands: libraryCommands())
                            }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    .overlay {
                        if store.visibleProjects.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: store.search.isEmpty ? "books.vertical" : "magnifyingglass").font(.title2)
                                Text(store.search.isEmpty ? (store.showArchived ? "No archived projects" : "Your library is ready") : "No matching projects").font(.callout)
                                if !store.search.isEmpty { Button("Clear search") { store.search = "" }.buttonStyle(.link) }
                                else { Text(store.showArchived ? "Archived projects will appear here." : "Use + to create or open a project.").font(.caption).multilineTextAlignment(.center) }
                            }.foregroundStyle(.secondary).padding(18)
                        }
                    }
                HStack {
                    Button { store.toggleArchivedProjects() } label: { Label(store.showArchived ? "Back to library" : "Archived projects", systemImage: "archivebox") }.buttonStyle(.plain).font(.caption)
                    Spacer()
                }.foregroundStyle(.secondary).padding(18)
                SyncLibraryStatus(sync: store.sync).padding(.horizontal, 18).padding(.bottom, 14)
            }.background(DesktopMaterial()).appContextMenu().navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            if let project = store.selectedProject {
                ProjectWorkspace(projectID: project.id, focusMode: $focusMode).id(project.id)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "book.pages").font(.system(size: 54)).foregroundStyle(Color.accentColor)
                    Text(store.showArchived ? "Your archived projects" : "Your next story starts here").font(.system(size: 30, weight: .medium, design: .serif))
                    Text(store.showArchived ? "Choose a project to read it, or restore it from its library menu." : "Write a story, build a world, or collect the things that inspire you.").foregroundStyle(.secondary)
                    HStack { Button("Create a story") { newKind = .story }.buttonStyle(.borderedProminent); Button("Collect references") { newKind = .research } }
                    Button("Open a project…") { Panels.openProject(store) }.buttonStyle(.link)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).appContextMenu()
            }
        }
        .background(WriterBackdrop())
        .environment(\.appContextCommands, libraryCommands)
        .frame(minWidth: 980, minHeight: 660)
        .sheet(item: $newKind) { NewProjectSheet(kind: $0) }
        .sheet(item: Binding(get: { store.sync.reviewProjectID.flatMap { store.sync.reviews[$0] } }, set: { if $0 == nil { store.sync.reviewProjectID = nil } })) { review in
            SyncReviewSheet(sync: store.sync, review: review)
        }
        .alert("StoryWriter", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("OK") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { notification in newKind = notification.object as? ProjectKind ?? .story }
        .onChange(of: focusMode) { _, focused in visibility = focused ? .detailOnly : .all }
        .onChange(of: store.selectedProjectID) { _, _ in focusMode = false }
    }
    private func libraryCommands() -> [ContextCommand] {
        [.submenu("Library", [
            .button("New story…") { newKind = .story },
            .button("New reference collection…") { newKind = .research },
            .button("Open project…") { Panels.openProject(store) },
            .button(store.showArchived ? "Show library" : "Show archived projects") { store.toggleArchivedProjects() }
        ]), .button("Settings…") { openSettings() }]
    }
}

struct ProjectRow: View {
    var project: StoryProject
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: project.kind.symbol).font(.system(size: 17)).foregroundStyle(Color.accentColor).frame(width: 24).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(project.kind == .story ? "\(project.chapters.count) \(project.chapters.count == 1 ? "chapter" : "chapters") · \(project.wordCount.formatted()) words" : "\(project.sources.count) \(project.sources.count == 1 ? "reference" : "references")").font(.system(size: 11)).foregroundStyle(.secondary)
                if project.kind == .story && project.targetWords > 0 {
                    ProgressView(value: min(1, Double(project.wordCount) / Double(project.targetWords)))
                        .help("\(project.wordCount.formatted()) of \(project.targetWords.formatted()) words")
                        .accessibilityLabel("Word goal progress")
                }
            }
        }.padding(.vertical, 9)
    }
}

struct NewProjectSheet: View {
    var kind: ProjectKind
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: kind.symbol).font(.system(size: 32)).foregroundStyle(Color.accentColor)
            Text(kind == .story ? "A new story" : "A new reference collection").font(.system(size: 25, weight: .medium, design: .serif))
            Text(kind == .story ? "A place for your manuscript, characters, world, and research." : "Keep images, documents, web links, audio, and video together. You can collect sources without starting a story.").foregroundStyle(.secondary)
            TextField(kind == .story ? "Story title" : "Collection name", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(create)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Create", action: create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 450).onAppear { focused = true }
    }
    private func create() { _ = store.create(title: title, kind: kind); dismiss() }
}
