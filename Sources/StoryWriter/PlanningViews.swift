import SwiftUI

struct CharactersView: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Environment(\.storyDestination) private var destination
    @Environment(\.pinResearch) private var pin
    @Environment(\.reviewFocus) private var reviewFocus
    @State private var selection: UUID?
    @State private var search = ""
    @State private var deleteID: UUID?

    var body: some View {
        if let project = store.project(projectID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack { WriterSearchField(title: "Find a character", text: $search); Button(action: add) { Image(systemName: "plus") }.buttonStyle(WriterIconButtonStyle()).help("Add character").accessibilityLabel("Add character") }.padding(16)
                    List(selection: $selection) {
                        ForEach(project.characters.filter { search.isEmpty || [$0.name, $0.role, $0.notes].joined(separator: " ").localizedCaseInsensitiveContains(search) }) { character in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(character.name.prefix(1)).uppercased()).font(.system(size: 17, weight: .medium, design: .serif)).frame(width: 34, height: 34).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 5) { Text(character.name).font(.system(size: 13, weight: .medium)); Text(character.role.isEmpty ? "Add a role" : character.role).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }.padding(.vertical, 8).tag(character.id)
                                .contextMenu { Button("Pin beside manuscript") { pin(.object(ProjectTagReference(kind: .character, objectID: character.id))) }; Button("Delete character…", role: .destructive) { deleteID = character.id }; Divider(); AppContextMenuItems() }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    Button("Add character", action: add).buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(18)
                }.frame(width: 235).background(DesktopMaterial())
                Divider()
                if let character = project.characters.first(where: { $0.id == selection }) {
                    CharacterDetails(projectID: projectID, character: store.itemBinding(projectID, \.characters, id: character.id, fallback: character)).environment(\.grammarNamespace, character.id.uuidString).id(character.id)
                } else { EmptyWorkspace(symbol: "person.crop.rectangle.stack", title: "Meet your characters", subtitle: "Give each person a purpose, a conflict, and a life beyond the page.", action: "Add character", perform: add) }
            }
            .onAppear { selection = destination?.kind == .character ? destination?.itemID : project.characters.first?.id }
            .onChange(of: selection) { _, _ in reviewFocus?.activate(nil) }
            .onChange(of: destination) { _, target in if target?.kind == .character { selection = target?.itemID } }
            .confirmationDialog("Delete this character?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) { Button("Delete character", role: .destructive) { if let deleteID { store.update(projectID) { $0.characters.removeAll { $0.id == deleteID } }; if selection == deleteID { selection = store.project(projectID)?.characters.first?.id } }; deleteID = nil } }
        }
    }
    private func add() { let character = Character(); store.update(projectID) { $0.characters.append(character) }; selection = character.id }
}

struct CharacterDetails: View {
    var projectID: UUID? = nil
    @Environment(\.storyDestination) private var destination
    @Binding var character: Character
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: character.name, subtitle: "The person behind the part they play.")
                VStack(spacing: 18) {
                    LabeledField("Name", text: $character.name)
                    HStack(alignment: .top, spacing: 18) { LabeledField("Role in the story", text: $character.role, placeholder: "Protagonist, rival, confidant…"); LabeledField("Pronouns", text: $character.pronouns) }
                    LabeledField("Aliases", text: Binding(get: { (character.aliases ?? []).joined(separator: ",") }, set: { character.aliases = $0.components(separatedBy: ",") }), placeholder: "First name, nickname, alternate spelling")
                }.cardSurface()
                NoteField("Appearance & mannerisms", hint: "The details a reader will remember.", text: $character.appearance, height: 85)
                NoteField("Personality & voice", hint: "How they think, speak, and act under pressure.", text: $character.personality, height: 100)
                NoteField("Wants & needs", hint: "What they pursue, and what they actually need.", text: $character.motivation, height: 100)
                NoteField("Conflict & secrets", hint: "What stands in their way? What do they hide?", text: $character.conflict, height: 100)
                NoteField("Character arc", hint: "Who they are at the beginning, and who they become.", text: $character.arc, height: 100)
                NoteField("Relationships", hint: "Connections, loyalties, tensions, and changing dynamics.", text: $character.relationships, height: 120)
                NoteField("Other notes", hint: "Backstory, continuity details, and ideas to revisit.", text: $character.notes, height: 120)
                if let projectID { BacklinksView(projectID: projectID, reference: ProjectTagReference(kind: .character, objectID: character.id)).cardSurface() }
            }.padding(28).frame(maxWidth: 900)
        }.frame(maxWidth: .infinity)
            .onAppear { if let destination { proxy.scrollTo(destination.field, anchor: .top) } }
            .onChange(of: destination) { _, target in if let target { proxy.scrollTo(target.field, anchor: .top) } }
        }
    }
}

struct WorldView: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Environment(\.storyDestination) private var destination
    @Environment(\.pinResearch) private var pin
    @Environment(\.reviewFocus) private var reviewFocus
    @State private var selection: UUID?
    @State private var search = ""
    @State private var category: WorldCategory?
    @State private var deleteID: UUID?
    var body: some View {
        if let project = store.project(projectID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack { WriterSearchField(title: "Find a world note", text: $search); Button(action: add) { Image(systemName: "plus") }.buttonStyle(WriterIconButtonStyle()).help("Add world note").accessibilityLabel("Add world note") }.padding(16)
                    Picker("Category", selection: $category) { Text("All categories").tag(Optional<WorldCategory>.none); ForEach(WorldCategory.allCases) { Text($0.rawValue).tag(Optional($0)) } }.labelsHidden().padding(.horizontal, 16).padding(.bottom, 12)
                    List(selection: $selection) {
                        ForEach(project.worldNotes.filter { (category == nil || $0.category == category) && (search.isEmpty || [$0.title, $0.summary, $0.details].joined(separator: " ").localizedCaseInsensitiveContains(search)) }) { note in
                            HStack(alignment: .top, spacing: 11) {
                                WriterSymbol(name: note.category.symbol)
                                VStack(alignment: .leading, spacing: 5) { Text(note.title).font(.system(size: 13, weight: .medium)); Text(note.category.rawValue).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 9).tag(note.id).contextMenu { Button("Pin beside manuscript") { pin(.object(ProjectTagReference(kind: .world, objectID: note.id))) }; Button("Delete note…", role: .destructive) { deleteID = note.id }; Divider(); AppContextMenuItems() }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    Button("Add world note", action: add).buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(18)
                }.frame(width: 235).background(DesktopMaterial())
                Divider()
                if let note = project.worldNotes.first(where: { $0.id == selection }) { WorldDetails(projectID: projectID, note: store.itemBinding(projectID, \.worldNotes, id: note.id, fallback: note)).environment(\.grammarNamespace, note.id.uuidString).id(note.id) }
                else { EmptyWorkspace(symbol: "globe.europe.africa", title: "A world worth getting lost in", subtitle: "Gather locations, history, cultures, objects, and the rules that hold it all together.", action: "Add world note", perform: add) }
            }.onAppear { selection = destination?.kind == .world ? destination?.itemID : project.worldNotes.first?.id }
            .onChange(of: selection) { _, _ in reviewFocus?.activate(nil) }
            .onChange(of: destination) { _, target in if target?.kind == .world { selection = target?.itemID } }
            .confirmationDialog("Delete this world note?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) { Button("Delete note", role: .destructive) { if let deleteID { store.update(projectID) { $0.worldNotes.removeAll { $0.id == deleteID } }; if selection == deleteID { selection = store.project(projectID)?.worldNotes.first?.id } }; deleteID = nil } }
        }
    }
    private func add() { let note = WorldNote(category: category ?? .location); store.update(projectID) { $0.worldNotes.append(note) }; selection = note.id }
}

struct WorldDetails: View {
    var projectID: UUID? = nil
    @Environment(\.storyDestination) private var destination
    @Binding var note: WorldNote
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: note.title, subtitle: "Build a setting that stays consistent from chapter to chapter.")
                VStack(alignment: .leading, spacing: 18) {
                    LabeledField("Title", text: $note.title)
                    HStack { Picker("Category", selection: $note.category) { ForEach(WorldCategory.allCases) { Text($0.rawValue).tag($0) } }; Spacer() }
                    LabeledField("Aliases", text: Binding(get: { (note.aliases ?? []).joined(separator: ",") }, set: { note.aliases = $0.components(separatedBy: ",") }), placeholder: "Other names used in the manuscript")
                }.cardSurface()
                NoteField("At a glance", hint: "A short description to find your bearings quickly.", text: $note.summary, height: 90)
                NoteField("Details & rules", hint: "Atmosphere, geography, history, limits, and the facts your story relies on.", text: $note.details, height: 280)
                NoteField("Connections & continuity", hint: "Related characters, chapters, places, and things to remember.", text: $note.connections, height: 160)
                if let projectID { BacklinksView(projectID: projectID, reference: ProjectTagReference(kind: .world, objectID: note.id)).cardSurface() }
            }.padding(28).frame(maxWidth: 900)
        }.frame(maxWidth: .infinity)
            .onAppear { if let destination { proxy.scrollTo(destination.field, anchor: .top) } }
            .onChange(of: destination) { _, target in if let target { proxy.scrollTo(target.field, anchor: .top) } }
        }
    }
}
