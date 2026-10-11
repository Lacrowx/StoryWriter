import SwiftUI
import AppKit

struct AddStoryObjectRequest: Identifiable {
    var id = UUID()
    var chapterID: UUID
    var range: NSRange
    var expectedText: String
}

struct CursorPositionLabel: View {
    var chapter: Chapter
    @ObservedObject var editor: EditorController
    var body: some View {
        let offset = editor.chapterID == chapter.id ? min(NSMaxRange(editor.selectionRange), chapter.plainText.utf16.count) : 0
        let scene = chapter.orderedScenes.last { $0.start <= offset }
        VStack(alignment: .leading, spacing: 3) {
            Text(scene.map { chapter.title + " · " + $0.title } ?? chapter.title).lineLimit(2)
            Text(editor.selectionRange.length > 0 ? "After selection · position \(offset)" : "Cursor · position \(offset)")
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct AddStoryObjectSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    var request: AddStoryObjectRequest
    @ObservedObject var editor: EditorController
    var added: (UUID) -> Void = { _ in }
    @State private var name = ""
    @State private var summary = ""
    @State private var tagSelection = true
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an object").font(.title2)
            Text("Keep this object in World and record who knows about it or carries it beside your writing.").font(.callout).foregroundStyle(.secondary)
            TextField("Object name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            TextField("Short description (optional)", text: $summary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text("Existing mentions of this name are linked across all chapters. Shared names and existing links are left as they are.").font(.caption).foregroundStyle(.secondary)
            if request.range.length > 0 {
                Toggle("Link this selection even if it differs from the name", isOn: $tagSelection)
            }
            Text("Adding or mentioning an object does not give any character knowledge or possession. Record those changes explicitly.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add object", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(Continuity.normalized(name).isEmpty)
            }
        }.padding(24).frame(width: 480).writerSheet()
        .onAppear {
            if let range = Range(request.range, in: request.expectedText) { name = String(request.expectedText[range]).trimmingCharacters(in: .whitespacesAndNewlines) }
            focused = true
        }
    }
    private func save() {
        guard var project = store.project(projectID) else { return }
        do {
            if tagSelection && request.range.length > 0 {
                guard editor.chapterID == request.chapterID, editor.textView?.string == request.expectedText,
                      project.chapters.first(where: { $0.id == request.chapterID })?.plainText == request.expectedText else {
                    throw ProjectError.invalid("The passage changed. Select the object’s name again, or turn off linking to add the object alone.")
                }
            }
            let object = try project.addStoryObject(name: name, summary: summary)
            store.update(projectID) { $0 = project }
            if let updated = store.project(projectID) { editor.linkExistingMentions(ProjectTagReference(kind: .world, objectID: object.id), in: updated) }
            if tagSelection && request.range.length > 0 {
                _ = editor.tagPassage(ProjectTagReference(kind: .world, objectID: object.id), chapterID: request.chapterID, range: request.range, expectedText: request.expectedText)
            }
            added(object.id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ObjectAwarenessView: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    var worldID: UUID
    var chapterID: UUID?
    @ObservedObject var editor: EditorController
    @State private var request: ContinuityRequest?
    @State private var history: ContinuityLibraryRequest?

    var body: some View {
        if let project = store.project(projectID), let chapter = project.chapters.first(where: { $0.id == chapterID }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Who knows about this?").font(.headline)
                CursorPositionLabel(chapter: chapter, editor: editor)
                let offset = editor.chapterID == chapter.id ? min(NSMaxRange(editor.selectionRange), chapter.plainText.utf16.count) : 0
                let rows = Continuity.objectStates(in: project, worldID: worldID, chapterID: chapter.id, offset: offset)
                if rows.isEmpty { Text("Add characters to record their knowledge and possessions.").font(.caption).foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.character.name).fontWeight(.medium)
                            Text(row.knowledgeLabel).font(.caption).foregroundStyle(.secondary)
                            if let possession = row.possession { Text(possession.latest.event.action == .gets ? "Has it" : "No longer has it").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            ForEach(ContinuityCategory.knowledge.actions) { action in
                                Button("\(action.label)…") { record(action, characterID: row.id, chapter: chapter) }
                            }
                            Divider()
                            Button("Gets this object…") { record(.gets, characterID: row.id, chapter: chapter) }
                            Button("Loses this object…") { record(.loses, characterID: row.id, chapter: chapter) }
                            if let item = row.knowledge?.item ?? row.possession?.item {
                                Divider()
                                Button("View passage history") { history = ContinuityLibraryRequest(itemID: item.id) }
                            }
                        } label: { Image(systemName: "plus.circle") }.menuStyle(.borderlessButton).frame(width: 22)
                            .disabled(editor.chapterID != chapter.id).help("Record a character change from your selection or cursor")
                    }
                }
                Text("Knowledge and possession are recorded separately. No record means the story has not established it here.").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).cardSurface(inset: 12)
                .sheet(item: $request) { ContinuityRecordSheet(projectID: projectID, request: $0) }
                .sheet(item: $history) { ContinuityLibrarySheet(projectID: projectID, initialItemID: $0.itemID, chapterID: chapterID, editor: editor) }
        }
    }
    private func record(_ action: ContinuityAction, characterID: UUID, chapter: Chapter) {
        request = ContinuityRequest(chapterID: chapter.id, range: editor.selectionRange, expectedText: chapter.plainText, characterID: characterID, category: action.category, action: action, worldObjectID: worldID)
    }
}
