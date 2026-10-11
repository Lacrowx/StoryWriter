import SwiftUI
import AppKit

struct ContinuityRequest: Identifiable {
    var id = UUID()
    var chapterID: UUID
    var range: NSRange
    var expectedText: String
    var characterID: UUID?
    var category: ContinuityCategory = .knowledge
    var action: ContinuityAction = .learns
    var itemID: UUID?
    var parentID: UUID?
}

struct ContinuityLibraryRequest: Identifiable {
    var id = UUID()
    var itemID: UUID?
}

extension ProjectStore {
    @discardableResult func changeContinuity(_ projectID: UUID, _ change: (inout StoryProject) throws -> Void) -> Bool {
        guard var project = project(projectID) else { return false }
        do { try change(&project); update(projectID) { $0 = project }; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
}

struct ContinuityPanel: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    @State private var pinnedCharacterID: UUID?
    @State private var request: ContinuityRequest?
    @State private var library: ContinuityLibraryRequest?
    @State private var showFinished = false

    private func offset(_ chapter: Chapter) -> Int {
        editor.chapterID == chapter.id ? min(NSMaxRange(editor.selectionRange), chapter.plainText.utf16.count) : 0
    }
    private func character(_ project: StoryProject, _ chapter: Chapter) -> UUID? {
        if let pinnedCharacterID, project.characters.contains(where: { $0.id == pinnedCharacterID }) { return pinnedCharacterID }
        let viewpoint = Continuity.viewpoint(in: chapter, offset: offset(chapter))
        return project.characters.first { $0.id == viewpoint }?.id ?? project.characters.first?.id
    }
    var body: some View {
        Group {
            if let project = store.project(projectID), let chapter = project.chapters.first(where: { $0.id == chapterID }) {
                let personID = character(project, chapter)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("Characters").font(.headline)
                            Spacer()
                            Button { library = ContinuityLibraryRequest() } label: { Label("All items", systemImage: "list.bullet") }.font(.caption)
                        }
                        if project.characters.isEmpty {
                            Text("Add a character in Characters to start tracking what they know, carry, and need to do.").foregroundStyle(.secondary)
                        } else {
                            Picker("Character", selection: $pinnedCharacterID) {
                                Text("Follow viewpoint").tag(UUID?.none)
                                ForEach(project.characters) { Text($0.name).tag(Optional($0.id)) }
                            }
                            if let personID, let person = project.characters.first(where: { $0.id == personID }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.name).font(.title3)
                                    Text("At your cursor").font(.caption).foregroundStyle(.secondary)
                                    if pinnedCharacterID == nil && Continuity.viewpoint(in: chapter, offset: offset(chapter)) == nil {
                                        Text("No scene viewpoint set · showing the first character").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                let states = Continuity.states(in: project, characterID: personID, chapterID: chapter.id, offset: offset(chapter))
                                ForEach(ContinuityCategory.allCases) { category in
                                    snapshot(category, states: states, project: project, chapter: chapter, personID: personID)
                                }
                                Button { request = makeRequest(chapter, characterID: personID) } label: { Label("Track something", systemImage: "plus") }
                                    .disabled(editor.chapterID != chapter.id).help("Select a passage to attach its source, or record a change at the cursor.")
                                Toggle("Show finished and past items", isOn: $showFinished).font(.caption)
                                let pending = Continuity.history(in: project, characterID: personID).filter { $0.event.detached || ($0.event.planned && $0.chapterID == chapter.id) }
                                if !pending.isEmpty {
                                    Divider()
                                    Text("Plans & items to review").font(.headline)
                                    ForEach(pending) { entry in
                                        Button { library = ContinuityLibraryRequest(itemID: entry.event.itemID) } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(project.trackedContinuityItems.first { $0.id == entry.event.itemID }?.name ?? "Tracked item")
                                                Text(entry.event.detached ? "Source changed · needs review" : "Planned · not established yet").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }.padding(16)
                }
            } else { Text("Choose a chapter to see continuity at your cursor.").foregroundStyle(.secondary).padding() }
        }
        .sheet(item: $request) { ContinuityRecordSheet(projectID: projectID, request: $0) }
        .sheet(item: $library) { ContinuityLibrarySheet(projectID: projectID, initialItemID: $0.itemID, chapterID: chapterID, editor: editor) }
    }
    @ViewBuilder private func snapshot(_ category: ContinuityCategory, states: [ContinuityState], project: StoryProject, chapter: Chapter, personID: UUID) -> some View {
        let rows = states.filter { $0.item.category == category && (showFinished || $0.latest.event.action.active) }
        VStack(alignment: .leading, spacing: 8) {
            Text(category.label).font(.system(size: 13, weight: .semibold))
            if rows.isEmpty { Text(category == .knowledge ? "No knowledge recorded here" : "Nothing recorded here").font(.caption).foregroundStyle(.secondary) }
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    if category == .task { Image(systemName: row.latest.event.action == .completed ? "checkmark.circle" : "circle").foregroundStyle(.secondary) }
                    Button { library = ContinuityLibraryRequest(itemID: row.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.item.name).foregroundStyle(row.latest.event.action.active ? Color.primary : Color.secondary)
                            if let status = row.latest.event.action.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                            if let parent = project.trackedContinuityItems.first(where: { $0.id == row.item.parentID }) { Text(parent.name).font(.caption2).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).help("See who knows or has this item and its passage history")
                    Menu {
                        Button("View history") { library = ContinuityLibraryRequest(itemID: row.id) }
                        if category == .possession {
                            Menu("Give to…") {
                                ForEach(project.characters.filter { $0.id != personID }) { recipient in
                                    Button(recipient.name) { transfer(row.item, from: personID, to: recipient.id, chapter: chapter) }
                                }
                            }
                        }
                        ForEach(category.actions.filter { $0 != row.latest.event.action && $0 != .learns }) { action in
                            Button("\(action.label) here…") { request = makeRequest(chapter, characterID: personID, item: row.item, action: action) }
                        }
                        if category == .knowledge { Button("Add a new detail…") { var next = makeRequest(chapter, characterID: personID); next.parentID = row.id; request = next } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).tint(.primary).frame(width: 20).disabled(editor.chapterID != chapter.id)
                }.padding(.vertical, 3)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).cardSurface(inset: 12)
    }
    private func makeRequest(_ chapter: Chapter, characterID: UUID, item: ContinuityItem? = nil, action: ContinuityAction? = nil) -> ContinuityRequest {
        ContinuityRequest(chapterID: chapter.id, range: editor.selectionRange, expectedText: chapter.plainText, characterID: characterID, category: item?.category ?? .knowledge, action: action ?? item?.category.actions.first ?? .learns, itemID: item?.id)
    }
    private func transfer(_ item: ContinuityItem, from: UUID, to: UUID, chapter: Chapter) {
        let range = editor.selectionRange
        store.changeContinuity(projectID) { project in
            try project.recordContinuity(itemID: item.id, characterID: from, action: .loses, chapterID: chapter.id, range: range, expectedText: chapter.plainText)
            try project.recordContinuity(itemID: item.id, characterID: to, action: .gets, chapterID: chapter.id, range: range, expectedText: chapter.plainText)
        }
    }
}

struct ContinuityRecordSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    var request: ContinuityRequest
    @State private var characterID: UUID?
    @State private var category: ContinuityCategory = .knowledge
    @State private var action: ContinuityAction = .learns
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var timing = "here"
    @State private var note = ""
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Track a character change").font(.title2)
            if let project = store.project(projectID) {
                HStack {
                    Picker("Character", selection: $characterID) {
                        Text("Choose a character").tag(UUID?.none)
                        ForEach(project.characters) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Add to", selection: $category) { ForEach(ContinuityCategory.allCases) { Text($0.label).tag($0) } }.disabled(request.itemID != nil)
                }
                if let parent = project.trackedContinuityItems.first(where: { $0.id == request.parentID }) { Text("New detail of \(parent.name)").font(.caption).foregroundStyle(.secondary) }
                TextField("Find an existing item or name a new one", text: $query).textFieldStyle(.roundedBorder).disabled(request.itemID != nil)
                if request.itemID == nil {
                    let choices = project.continuityChoices(for: category, parentID: request.parentID)
                    let matches = Continuity.matches(choices, query: query, category: category)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(matches) { item in
                                Button { selectedID = item.id; creating = false; error = nil } label: {
                                    HStack {
                                        Image(systemName: selectedID == item.id && !creating ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name)
                                            if item.worldObjectID != nil { Text("World item").font(.caption).foregroundStyle(.secondary) }
                                            if !item.aliases.isEmpty { Text("Also called \(item.aliases.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                                            if let parent = project.trackedContinuityItems.first(where: { $0.id == item.parentID }) { Text("Detail of \(parent.name)").font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if !Continuity.normalized(query).isEmpty && Continuity.exactMatch(choices, name: query, category: category, parentID: request.parentID) == nil {
                                Button { creating = true; selectedID = nil; error = nil } label: {
                                    Label("Create separate \(category.noun.lowercased()): “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”", systemImage: creating ? "checkmark.circle.fill" : "plus.circle").multilineTextAlignment(.leading)
                                }.buttonStyle(.plain).padding(8)
                                if !matches.isEmpty { Text("Use an existing item when this is the same information in different words.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8) }
                            } else if !query.isEmpty {
                                Text("This name already belongs to an existing item.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                            }
                        }
                    }.frame(height: 150)
                }
                HStack {
                    Picker("Change", selection: $action) { ForEach(category.actions) { Text($0.label).tag($0) } }
                    Picker("When", selection: $timing) {
                        Text(request.range.length > 0 ? "After selected passage" : "At the cursor").tag("here")
                        Text("Before the story").tag("start")
                        Text("Planned for this chapter").tag("plan")
                    }
                }
                if request.range.length > 0, let range = Range(request.range, in: request.expectedText) {
                    Text(String(request.expectedText[range])).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                TextField("Optional source note or reminder", text: $note).textFieldStyle(.roundedBorder)
                if let selectedID, let characterID, timing == "here", action == .learns,
                   let state = Continuity.states(in: project, characterID: characterID, chapterID: request.chapterID, offset: NSMaxRange(request.range)).first(where: { $0.id == selectedID }), [.learns, .confirmed].contains(state.latest.event.action) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("This character already knows this. Record a reminder or add a new detail.").font(.callout).foregroundStyle(.secondary)
                        Button("Record a reminder instead") { action = .reminded }
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(timing == "start" ? "Save starting state" : timing == "plan" ? "Save plan" : "Save from here", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(characterID == nil || (selectedID == nil && !creating)) }
            }
        }.padding(24).frame(width: 570).writerSheet()
        .onAppear {
            let project = store.project(projectID)
            characterID = request.characterID ?? project?.characters.first?.id
            category = request.category; action = request.action; selectedID = request.itemID
            query = project?.trackedContinuityItems.first { $0.id == request.itemID }?.name ?? ""
        }
        .onChange(of: query) { _, value in
            if request.itemID == nil {
                selectedID = Continuity.exactMatch(store.project(projectID)?.continuityChoices(for: category, parentID: request.parentID) ?? [], name: value, category: category, parentID: request.parentID)?.id
                creating = false; error = nil
            }
        }
        .onChange(of: category) { _, value in
            if request.itemID == nil { action = value.actions[0]; selectedID = Continuity.exactMatch(store.project(projectID)?.continuityChoices(for: value, parentID: request.parentID) ?? [], name: query, category: value, parentID: request.parentID)?.id; creating = false; error = nil }
        }
    }
    private func save() {
        guard var project = store.project(projectID), let characterID else { return }
        do {
            let item: ContinuityItem
            if let selectedID, !creating { item = try project.useContinuityChoice(selectedID, category: category, parentID: request.parentID) }
            else if creating { item = try project.createContinuityItem(name: query, category: category, parentID: request.parentID) }
            else { return }
            try project.recordContinuity(itemID: item.id, characterID: characterID, action: action, chapterID: timing == "start" ? nil : request.chapterID, range: request.range, expectedText: request.expectedText, note: note, planned: timing == "plan")
            store.update(projectID) { $0 = project }; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ContinuityLibrarySheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    var initialItemID: UUID?
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    @State private var selectedID: UUID?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Tracked items").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if let project = store.project(projectID) {
                HSplitView {
                    VStack(alignment: .leading, spacing: 10) {
                        WriterSearchField(title: "Find information, items, tasks…", text: $query)
                        List(selection: $selectedID) {
                            ForEach(Continuity.matches(project.trackedContinuityItems, query: query)) { item in
                                VStack(alignment: .leading, spacing: 3) { Text(item.name); Text(item.category.noun).font(.caption).foregroundStyle(.secondary) }.tag(item.id)
                            }
                        }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    }.frame(minWidth: 200, idealWidth: 240, maxWidth: 280).padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                    if let item = project.trackedContinuityItems.first(where: { $0.id == selectedID }) {
                        ContinuityItemDetails(projectID: projectID, itemID: item.id, chapterID: chapterID, editor: editor, merged: { selectedID = $0 }, go: { target in dismiss(); navigate(target) }).id(item.id).frame(minWidth: 390)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle").font(.largeTitle)
                            Text(project.trackedContinuityItems.isEmpty ? "No tracked items yet" : "Select a tracked item").font(.headline)
                            Text(project.trackedContinuityItems.isEmpty ? "Select a passage and choose Track a character change, or use Track something beside your writing." : "See each character’s knowledge, possessions, and passage history.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.padding(24).frame(width: 800, height: 640).writerSheet().onAppear { selectedID = initialItemID }
    }
}

struct ContinuityItemDetails: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    var itemID: UUID
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    var merged: (UUID) -> Void
    var go: (StoryDestination) -> Void
    @State private var editing = false
    @State private var name = ""
    @State private var aliases = ""
    @State private var details = ""
    @State private var mergeTarget: UUID?
    @State private var error: String?

    var body: some View {
        if let project = store.project(projectID), let item = project.trackedContinuityItems.first(where: { $0.id == itemID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.title2); Text(item.category.noun).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit") { name = item.name; aliases = item.aliases.joined(separator: ", "); details = item.details; editing.toggle() }
                    }
                    if let parent = project.trackedContinuityItems.first(where: { $0.id == item.parentID }) { Text("Detail of \(parent.name)").font(.caption).foregroundStyle(.secondary) }
                    if editing {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        TextField("Other names, separated by commas", text: $aliases).textFieldStyle(.roundedBorder)
                        TextField("What this item means", text: $details, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                        Button("Save details", action: saveDetails)
                    } else {
                        if !item.aliases.isEmpty { Text("Also called \(item.aliases.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                        if !item.details.isEmpty { Text(item.details).font(.callout) }
                    }
                    let children = project.trackedContinuityItems.filter { $0.parentID == item.id }
                    if !children.isEmpty { Text("Details tracked separately").font(.headline); ForEach(children) { child in Button(child.name) { merged(child.id) } } }
                    Divider()
                    Text(item.category == .knowledge ? "Who learned this?" : "Character history").font(.headline)
                    let history = Continuity.history(in: project, itemID: item.id)
                    ForEach(project.characters) { person in
                        let events = history.filter { $0.event.characterID == person.id && !$0.event.detached && !$0.event.planned }
                        let first = events.first { item.category == .knowledge ? [.learns, .confirmed].contains($0.event.action) : $0.event.action.active }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(person.name).font(.system(size: 13, weight: .semibold))
                            if let first { source(first, project: project) }
                            else { Text(item.category == .knowledge ? "No recorded knowledge" : "No acquisition recorded").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Divider()
                    Text("All changes").font(.headline)
                    if history.isEmpty { Text("No changes recorded yet.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(history) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(project.characters.first { $0.id == entry.event.characterID }?.name ?? "Deleted character").fontWeight(.medium)
                                Text("· \(entry.event.action.label.lowercased())").foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    if entry.chapterID != nil { Button("Attach to current selection / cursor") { attach(entry) }.disabled(editor.chapterID != chapterID) }
                                    Button("Remove this change", role: .destructive) { remove(entry) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).tint(.primary).frame(width: 20)
                            }
                            if entry.event.planned { Text("Planned · not established yet").font(.caption).foregroundStyle(.secondary) }
                            if entry.event.detached { Text("Source changed · needs review").font(.caption).foregroundStyle(.orange) }
                            source(entry, project: project)
                            if !entry.event.quote.isEmpty { Text(entry.event.quote).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            if !entry.event.note.isEmpty { Text(entry.event.note).font(.callout) }
                        }.padding(.vertical, 5)
                    }
                    Divider()
                    Menu("Merge this item with…") {
                        ForEach(project.trackedContinuityItems.filter { $0.id != itemID && $0.category == item.category }) { target in Button(target.name) { mergeTarget = target.id } }
                    }.disabled(project.trackedContinuityItems.filter { $0.category == item.category }.count < 2)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(.leading, 14).padding(.trailing, 6)
            }
            .confirmationDialog("Merge “\(item.name)” with “\(project.trackedContinuityItems.first { $0.id == mergeTarget }?.name ?? "item")”? Both passage histories and alternate names will be kept.", isPresented: Binding(get: { mergeTarget != nil }, set: { if !$0 { mergeTarget = nil } })) {
                Button("Merge items") {
                    guard let target = mergeTarget else { return }
                    if store.changeContinuity(projectID, { try $0.mergeContinuityItem(itemID, into: target) }) { merged(target) }
                    mergeTarget = nil
                }
            }
        }
    }
    @ViewBuilder private func source(_ entry: LocatedContinuityEvent, project: StoryProject) -> some View {
        if let chapter = project.chapters.first(where: { $0.id == entry.chapterID }) {
            let scene = chapter.orderedScenes.last { $0.start <= entry.event.start }
            Button(chapter.title + (scene.map { " · \($0.title)" } ?? "")) { go(StoryDestination(kind: .chapter, itemID: chapter.id, range: entry.event.range, expectedText: chapter.plainText)) }
                .buttonStyle(.link).font(.caption).disabled(entry.event.detached || !Continuity.validatesAnchor(entry.event, in: chapter.plainText))
        } else { Text("Before the story").font(.caption).foregroundStyle(.secondary) }
    }
    private func saveDetails() {
        guard var project = store.project(projectID), let index = project.trackedContinuityItems.firstIndex(where: { $0.id == itemID }), let item = project.continuityItems?[index] else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Continuity.normalized(title).isEmpty else { error = "Give this item a name."; return }
        let names = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let others = project.trackedContinuityItems.filter { $0.id != itemID }
        if ([title] + names).contains(where: { Continuity.exactMatch(others, name: $0, category: item.category, parentID: item.parentID) != nil }) { error = "An item already uses this name. Merge the items if they mean the same thing."; return }
        if let worldID = item.worldObjectID, let worldIndex = project.worldNotes.firstIndex(where: { $0.id == worldID }) {
            project.worldNotes[worldIndex].title = title; project.worldNotes[worldIndex].aliases = names
        }
        project.continuityItems?[index].name = title; project.continuityItems?[index].aliases = names; project.continuityItems?[index].details = details
        store.update(projectID) { $0 = project }; editing = false; error = nil
    }
    private func remove(_ entry: LocatedContinuityEvent) {
        store.update(projectID) { project in
            if let c = project.chapters.firstIndex(where: { $0.id == entry.chapterID }) { project.chapters[c].continuityEvents?.removeAll { $0.id == entry.id } }
            else { project.initialContinuity?.removeAll { $0.id == entry.id } }
        }
    }
    private func attach(_ entry: LocatedContinuityEvent) {
        guard let chapterID, editor.chapterID == chapterID, var project = store.project(projectID), let c = project.chapters.firstIndex(where: { $0.id == chapterID }), editor.textView?.string == project.chapters[c].plainText else { return }
        do {
            var event = entry.event
            try Continuity.anchor(&event, range: editor.selectionRange, text: project.chapters[c].plainText)
            event.planned = false
            for i in project.chapters.indices { project.chapters[i].continuityEvents?.removeAll { $0.id == entry.id } }
            let recorded = try project.recordContinuity(itemID: event.itemID, characterID: event.characterID, action: event.action, chapterID: chapterID, range: event.range, expectedText: project.chapters[c].plainText, note: event.note)
            if let index = project.chapters[c].continuityEvents?.firstIndex(where: { $0.id == recorded.id }) { project.chapters[c].continuityEvents?[index].id = entry.id }
            store.update(projectID) { $0 = project }
        } catch { self.error = error.localizedDescription }
    }
}
