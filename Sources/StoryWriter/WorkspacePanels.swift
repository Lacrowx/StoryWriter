import SwiftUI
import AppKit

struct ProjectSearchSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    @State private var query = ""
    @State private var manuscriptOnly = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find a passage or project note").font(.title2)
            HStack { WriterSearchField(title: "Search this project", text: $query).focused($focused); Toggle("Manuscript only", isOn: $manuscriptOnly) }
            let results = store.project(projectID).map { StorySearch.results(in: $0, query: query, manuscriptOnly: manuscriptOnly) } ?? []
            Text(query.isEmpty ? "Search chapters, characters, world entries, and reference notes." : "\(results.count) matches").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(results) { result in
                        Button { dismiss(); navigate(result.destination) } label: { PassageResultRow(result: result, query: query).padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                    }
                    if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
                }
            }.overlay {
                if query.isEmpty { ContentUnavailableView("Search your project", systemImage: "doc.text.magnifyingglass", description: Text("Find a phrase, character, place, or reference note.")) }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 660, height: 600).writerSheet().onAppear { focused = true }
    }
}

enum WritingPanelTab: String, CaseIterable, Identifiable {
    case research = "Research", scenes = "Scenes", comments = "Comments", continuity = "Continuity"
    var id: String { rawValue }
}

struct WritingSidePanel: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    @Binding var tab: WritingPanelTab
    @Binding var pinned: PinnedResearch?
    var close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Beside your writing").font(.headline); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(WriterIconButtonStyle()).help("Close writing panel").accessibilityLabel("Close writing panel") }.padding(16)
            Picker("Writing panel", selection: $tab) { ForEach(WritingPanelTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().controlSize(.regular).padding(.horizontal, 16).padding(.bottom, 16)
            Divider()
            switch tab {
            case .research: ResearchPanel(projectID: projectID, pinned: $pinned, chapterID: chapterID, editor: editor)
            case .scenes: ScenePanel(projectID: projectID, chapterID: chapterID, editor: editor)
            case .comments: CommentQueue(projectID: projectID, editor: editor, initialChapterID: chapterID)
            case .continuity: ContinuityPanel(projectID: projectID, chapterID: chapterID, editor: editor)
            }
        }.frame(width: 360).background(DesktopMaterial())
    }
}

struct ResearchPanel: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Binding var pinned: PinnedResearch?
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let project = store.project(projectID) {
                Menu {
                    ForEach(project.tagObjects) { object in Button(object.title) { pinned = .object(object.reference) } }
                    if !project.sources.isEmpty { Divider(); ForEach(project.sources) { source in Button(source.title) { pinned = .source(source.id) } } }
                } label: { Label("Choose material to pin", systemImage: "pin") }.padding(14)
                Divider()
                if let pinned {
                    switch pinned {
                    case .object(let reference):
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                if reference.kind == .character, let character = project.characters.first(where: { $0.id == reference.objectID }) {
                                    let binding = store.itemBinding(projectID, \.characters, id: character.id, fallback: character)
                                    Text(character.name).font(.title2).fontDesign(.serif)
                                    Text(character.role).foregroundStyle(.secondary)
                                    NoteField("Appearance", hint: "Details to keep consistent", text: binding.appearance, height: 80)
                                    NoteField("Voice", hint: "How they speak and act", text: binding.personality, height: 90)
                                    NoteField("Wants & needs", hint: "What drives this scene", text: binding.motivation, height: 90)
                                    NoteField("Continuity notes", hint: "Keep useful facts close", text: binding.notes, height: 100)
                                    BacklinksView(projectID: projectID, reference: reference)
                                } else if let note = project.worldNotes.first(where: { $0.id == reference.objectID }) {
                                    let binding = store.itemBinding(projectID, \.worldNotes, id: note.id, fallback: note)
                                    Text(note.title).font(.title2).fontDesign(.serif)
                                    if note.category == .object { ObjectAwarenessView(projectID: projectID, worldID: note.id, chapterID: chapterID, editor: editor) }
                                    NoteField("At a glance", hint: note.category.rawValue, text: binding.summary, height: 80)
                                    NoteField("Details & rules", hint: "Facts your story relies on", text: binding.details, height: 200)
                                    NoteField("Connections", hint: "Continuity notes", text: binding.connections, height: 100)
                                    BacklinksView(projectID: projectID, reference: reference)
                                } else { Text("This object is no longer in the project.").foregroundStyle(.secondary) }
                            }.padding(16).environment(\.grammarNamespace, reference.objectID.uuidString)
                        }
                    case .source(let id):
                        if let source = project.sources.first(where: { $0.id == id }) { PinnedReference(projectID: projectID, source: store.itemBinding(projectID, \.sources, id: id, fallback: source)) }
                        else { Text("This reference is no longer in the project.").padding() }
                    }
                } else {
                    VStack(spacing: 12) { Image(systemName: "pin").font(.largeTitle); Text("Keep a character, place, or source beside your manuscript.").multilineTextAlignment(.center).foregroundStyle(.secondary) }.padding(24).frame(maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PinnedReference: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Binding var source: ReferenceSource
    @StateObject private var web = WebReferenceController()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source.title).font(.headline).padding(.horizontal)
            if let file = store.mediaURL(source, projectID: projectID) { FilePreview(url: file).frame(minHeight: 140, maxHeight: .infinity) }
            else if let link = source.webURL, let url = URL(string: link) { WebReferenceView(url: url, archiveURL: store.mediaURL(source, projectID: projectID, snapshot: true), controller: web).frame(minHeight: 180, maxHeight: .infinity) }
            NoteField("Your notes", hint: source.tags, text: $source.notes, height: source.relativePath == nil && source.webURL == nil ? 260 : 100).padding(.horizontal).environment(\.grammarNamespace, source.id.uuidString)
        }.padding(.vertical, 16)
    }
}

struct ScenePanel: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    @State private var editingScene: StoryScene?
    var body: some View {
        if let chapter = store.project(projectID)?.chapters.first(where: { $0.id == chapterID }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Split at cursor") { perform(chapter.id) { try $0.splitScene(at: editor.textView?.selectedRange().location ?? 0) } }.disabled(editor.chapterID != chapter.id)
                    Spacer()
                    if chapter.orderedScenes.isEmpty { Button("Add scene") { perform(chapter.id) { $0.ensureScene() } } }
                }.padding(12)
                Text("Split, move, or merge scenes without losing manuscript formatting.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(chapter.orderedScenes.enumerated()), id: \.element.id) { index, scene in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { navigate(StoryDestination(kind: .chapter, itemID: chapter.id, range: chapter.range(of: scene), expectedText: chapter.plainText)) } label: {
                                    VStack(alignment: .leading, spacing: 5) { Text(scene.title).font(.headline); Text(scene.synopsis.isEmpty ? "Add a scene synopsis" : scene.synopsis).font(.caption).foregroundStyle(.secondary).lineLimit(3) }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                HStack {
                                    Text(scene.status.rawValue).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { editingScene = scene } label: { Image(systemName: "slider.horizontal.3") }.help("Scene details")
                                    Menu {
                                        Button("Move earlier") { perform(chapter.id) { try $0.moveScene(scene.id, offset: -1) } }.disabled(index == 0)
                                        Button("Move later") { perform(chapter.id) { try $0.moveScene(scene.id, offset: 1) } }.disabled(index == chapter.orderedScenes.count - 1)
                                        Button("Merge with previous") { perform(chapter.id) { try $0.mergeScene(scene.id) } }.disabled(index == 0)
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).tint(.primary).frame(width: 20)
                                }
                            }.cardSurface()
                        }
                        if chapter.orderedScenes.isEmpty { Text("Place the cursor where the next scene begins, then choose Split at cursor.").foregroundStyle(.secondary).padding(20) }
                    }.padding(12)
                }
            }.sheet(item: $editingScene) { scene in SceneDetailsSheet(projectID: projectID, chapterID: chapter.id, sceneID: scene.id) }
        } else { Text("Choose a chapter to plan its scenes.").padding() }
    }
    private func perform(_ id: UUID, _ change: (inout Chapter) throws -> Void) {
        do {
            guard var chapter = store.project(projectID)?.chapters.first(where: { $0.id == id }) else { return }
            guard store.saveNow() else { return }; try store.checkpoint(projectID)
            try change(&chapter)
            store.update(projectID) { project in if let index = project.chapters.firstIndex(where: { $0.id == id }) { project.chapters[index] = chapter } }
        } catch { store.errorMessage = error.localizedDescription }
    }
}

struct SceneDetailsSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID, chapterID: UUID, sceneID: UUID
    func binding<Value>(_ key: WritableKeyPath<StoryScene, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { store.project(projectID)?.chapters.first { $0.id == chapterID }?.scenes?.first { $0.id == sceneID }?[keyPath: key] ?? fallback }, set: { value in store.update(projectID) { project in
            if let c = project.chapters.firstIndex(where: { $0.id == chapterID }), let s = project.chapters[c].scenes?.firstIndex(where: { $0.id == sceneID }) { project.chapters[c].scenes?[s][keyPath: key] = value }
        } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scene details").font(.title2)
            LabeledField("Scene title", text: binding(\.title, fallback: "Scene"))
            NoteField("Synopsis", hint: "What changes during this scene?", text: binding(\.synopsis, fallback: ""), height: 100)
            Picker("Status", selection: binding(\.status, fallback: .planned)) { ForEach(DraftStatus.allCases) { Text($0.rawValue).tag($0) } }
            if let project = store.project(projectID) {
                Picker("Viewpoint", selection: binding(\.viewpointID, fallback: nil)) { Text("Unspecified").tag(UUID?.none); ForEach(project.characters) { Text($0.name).tag(Optional($0.id)) } }
                Picker("Location", selection: binding(\.locationID, fallback: nil)) { Text("Unspecified").tag(UUID?.none); ForEach(project.worldNotes.filter { $0.category == .location }) { Text($0.title).tag(Optional($0.id)) } }
            }
            LabeledField("Story time", text: binding(\.storyTime, fallback: ""), placeholder: "Day 2 · morning, or an exact date")
            HStack { Text("Timeline order"); TextField("Optional number", text: Binding(get: { binding(\.timelineOrder, fallback: nil).wrappedValue.map(String.init) ?? "" }, set: { binding(\.timelineOrder, fallback: nil).wrappedValue = Int($0) })).textFieldStyle(.roundedBorder).frame(width: 140) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480).writerSheet().environment(\.grammarNamespace, sceneID.uuidString)
    }
}

struct CommentQueue: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    @ObservedObject var editor: EditorController
    var initialChapterID: UUID?
    @State private var filter: UUID?
    @State private var includeResolved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let project = store.project(projectID) {
                Picker("Chapter", selection: $filter) { Text("All chapters").tag(UUID?.none); ForEach(project.chapters) { Text($0.title).tag(Optional($0.id)) } }.padding(.horizontal, 12).padding(.top, 12)
                Toggle("Include resolved", isOn: $includeResolved).font(.caption).padding(.horizontal, 12)
                let chapters = project.chapters.filter { filter == nil || $0.id == filter }
                let count = chapters.reduce(0) { $0 + ($1.comments ?? []).filter { includeResolved || !$0.resolved }.count }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chapters) { chapter in
                            ForEach((chapter.comments ?? []).filter { includeResolved || !$0.resolved }) { comment in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(chapter.title).font(.caption).foregroundStyle(.secondary)
                                    Button { navigate(StoryDestination(kind: .chapter, itemID: chapter.id, range: comment.range, expectedText: chapter.plainText)) } label: { Text(comment.quote).font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).disabled(comment.detached)
                                    TextEditor(text: commentBinding(chapter.id, comment.id, \.note, fallback: comment.note)).frame(minHeight: 65, maxHeight: 100)
                                    if comment.detached {
                                        Text("The original passage changed. Select a new passage to reattach this note.").font(.caption2).foregroundStyle(.orange)
                                        Button("Attach to selection") { reattach(chapter, comment) }.disabled(editor.chapterID != chapter.id || editor.selectionText.isEmpty)
                                    }
                                    Toggle("Resolved", isOn: commentBinding(chapter.id, comment.id, \.resolved, fallback: comment.resolved)).font(.caption)
                                }.cardSurface()
                            }
                        }
                        if count == 0 { Text("No \(includeResolved ? "" : "unresolved ")comments. Select manuscript text and choose Add comment.").foregroundStyle(.secondary).padding(20) }
                    }.padding(12)
                }
            }
        }.onAppear { filter = initialChapterID }
    }
    private func commentBinding<Value>(_ chapterID: UUID, _ commentID: UUID, _ key: WritableKeyPath<PassageComment, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { store.project(projectID)?.chapters.first { $0.id == chapterID }?.comments?.first { $0.id == commentID }?[keyPath: key] ?? fallback }, set: { value in store.update(projectID) { project in if let c = project.chapters.firstIndex(where: { $0.id == chapterID }), let n = project.chapters[c].comments?.firstIndex(where: { $0.id == commentID }) { project.chapters[c].comments?[n][keyPath: key] = value } } })
    }
    private func reattach(_ chapter: Chapter, _ comment: PassageComment) {
        guard editor.chapterID == chapter.id, let view = editor.textView, view.string == chapter.plainText else { return }
        let range = view.selectedRange(); guard range.length > 0, NSMaxRange(range) <= chapter.plainText.utf16.count else { return }
        store.update(projectID) { project in if let c = project.chapters.firstIndex(where: { $0.id == chapter.id }), let n = project.chapters[c].comments?.firstIndex(where: { $0.id == comment.id }) {
            project.chapters[c].comments?[n].start = range.location; project.chapters[c].comments?[n].length = range.length
            project.chapters[c].comments?[n].quote = (chapter.plainText as NSString).substring(with: range); project.chapters[c].comments?[n].detached = false
        } }
    }
}

struct TimelineSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    @State private var editing: SceneTimelineItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Story timeline").font(.title2)
            Text("Chronological order is separate from chapter order. Give scenes a timeline number and story time to arrange events, including flashbacks.").font(.callout).foregroundStyle(.secondary)
            if let project = store.project(projectID) {
                let items = project.chapters.enumerated().flatMap { c, chapter in chapter.orderedScenes.enumerated().map { s, scene in SceneTimelineItem(chapter: chapter, scene: scene, chapterIndex: c, sceneIndex: s) } }.sorted { ($0.scene.timelineOrder ?? Int.max, $0.chapterIndex, $0.sceneIndex) < ($1.scene.timelineOrder ?? Int.max, $1.chapterIndex, $1.sceneIndex) }
                if items.isEmpty { Button("Create one scene per chapter") { store.update(projectID) { project in for i in project.chapters.indices { project.chapters[i].ensureScene() } } } }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 16) {
                                Text(item.scene.timelineOrder.map(String.init) ?? "—").font(.title3).monospacedDigit().frame(width: 40)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.scene.title).font(.headline)
                                    Text("Chapter \(item.chapterIndex + 1) · \(item.chapter.title)").font(.caption).foregroundStyle(.secondary)
                                    Text(item.scene.storyTime.isEmpty ? "No story time specified" : item.scene.storyTime).font(.caption).foregroundStyle(.secondary)
                                    if !item.scene.synopsis.isEmpty { Text(item.scene.synopsis).font(.callout) }
                                }
                                Spacer()
                                Button("Details") { editing = item }
                                Button("Go to scene") { dismiss(); navigate(StoryDestination(kind: .chapter, itemID: item.chapter.id, range: item.chapter.range(of: item.scene), expectedText: item.chapter.plainText)) }
                            }.cardSurface()
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 740, height: 600).writerSheet()
            .sheet(item: $editing) { item in SceneDetailsSheet(projectID: projectID, chapterID: item.chapter.id, sceneID: item.scene.id) }
    }
}
struct SceneTimelineItem: Identifiable { var chapter: Chapter; var scene: StoryScene; var chapterIndex: Int; var sceneIndex: Int; var id: UUID { scene.id } }
