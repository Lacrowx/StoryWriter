import AppKit
import SwiftUI

extension ProjectStore {
    func namedCheckpoint(_ id: UUID, name: String) throws {
        guard saveNow() else { throw ProjectError.invalid("Save your project before adding a checkpoint.") }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ProjectError.invalid("Give this checkpoint a name.") }
        try checkpoint(id, name: cleaned)
    }
    func revisionProject(_ revision: Revision, projectID: UUID) throws -> StoryProject {
        let saved = try Self.decode(Data(contentsOf: revision.url))
        guard saved.id == projectID else { throw ProjectError.invalid("This revision belongs to another project.") }
        return saved
    }
    func recoverChapter(_ chapter: Chapter, projectID: UUID) throws {
        guard saveNow() else { throw ProjectError.invalid("Save your current writing before recovering a chapter.") }
        try checkpoint(projectID)
        update(projectID) { project in
            if let index = project.chapters.firstIndex(where: { $0.id == chapter.id }) { project.chapters[index] = chapter }
            else { project.chapters.append(chapter) }
        }
        _ = saveNow()
    }
    @discardableResult func recoverPassage(_ text: NSAttributedString, to chapterID: UUID, projectID: UUID) throws -> NSRange {
        guard var chapter = project(projectID)?.chapters.first(where: { $0.id == chapterID }), text.length > 0 else { throw ProjectError.invalid("Choose a current chapter and select text in the saved passage.") }
        guard saveNow() else { throw ProjectError.invalid("Save your current writing before recovering a passage.") }
        try checkpoint(projectID)
        let result = NSMutableAttributedString(attributedString: chapter.attributedText)
        if result.length > 0 { result.append(NSAttributedString(string: "\n\n", attributes: WritingStyle.attributes)) }
        let range = NSRange(location: result.length, length: text.length)
        result.append(text); try chapter.setText(result)
        update(projectID) { project in if let i = project.chapters.firstIndex(where: { $0.id == chapterID }) { project.chapters[i] = chapter } }
        _ = saveNow(); return range
    }
}

struct RevisionLine: Identifiable { var index: Int; var text: String; var change: Int; var id: Int { index } }
enum RevisionComparison {
    static func lines(old: String, new: String) -> [RevisionLine] {
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        let removed = Set(diff.removals.compactMap { change -> Int? in if case .remove(let i, _, _) = change { return i }; return nil })
        let inserted = Set(diff.insertions.compactMap { change -> Int? in if case .insert(let i, _, _) = change { return i }; return nil })
        var i = 0, j = 0, result: [RevisionLine] = []
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count && removed.contains(i) { result.append(RevisionLine(index: result.count, text: oldLines[i], change: -1)); i += 1 }
            else if j < newLines.count && inserted.contains(j) { result.append(RevisionLine(index: result.count, text: newLines[j], change: 1)); j += 1 }
            else if i < oldLines.count && j < newLines.count { result.append(RevisionLine(index: result.count, text: newLines[j], change: 0)); i += 1; j += 1 }
            else { break }
        }
        return result
    }
}

struct SavedPassagePreview: NSViewRepresentable {
    var text: NSAttributedString
    @ObservedObject var controller: EditorController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero); view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true; view.textContainerInset = NSSize(width: 14, height: 14)
        view.delegate = context.coordinator; view.textStorage?.setAttributedString(text)
        view.appearance = NSAppearance(named: .aqua); view.backgroundColor = ManuscriptPaper.color
        scroll.documentView = view; controller.textView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if !view.attributedString().isEqual(to: text) { view.textStorage?.setAttributedString(text); controller.refresh() }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var controller: EditorController
        init(_ controller: EditorController) { self.controller = controller }
        func textViewDidChangeSelection(_ notification: Notification) { controller.refresh() }
    }
}

struct RevisionHistorySheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    @State private var revisionID: String?
    @State private var saved: StoryProject?
    @State private var chapterID: UUID?
    @State private var recoverToID: UUID?
    @State private var checkpointName = ""
    @State private var refresh = UUID()
    @State private var confirmation: RecoveryAction?
    @State private var loadError: String?
    @StateObject private var preview = EditorController()
    private var revisions: [Revision] { store.revisions(projectID) }
    enum RecoveryAction: String, Identifiable { case project, chapter; var id: String { rawValue } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved revisions").font(.title2)
            Text("Compare earlier writing before recovering it. Automatic history keeps 30 saves; named checkpoints are retained. Recovery first saves a revision of your current project.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Name a checkpoint", text: $checkpointName).textFieldStyle(.roundedBorder)
                Button("Save checkpoint") { do { try store.namedCheckpoint(projectID, name: checkpointName); checkpointName = ""; refresh = UUID() } catch { loadError = error.localizedDescription } }.disabled(checkpointName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(alignment: .top, spacing: 16) {
                List(selection: $revisionID) {
                    ForEach(revisions) { revision in
                        VStack(alignment: .leading, spacing: 5) { Text(revision.name ?? "Automatic save").fontWeight(.medium); Text(revision.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 6).tag(revision.id)
                    }
                }.frame(width: 205)
                comparison
            }.frame(maxHeight: .infinity)
            if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Restore entire project…") { confirmation = .project }.disabled(saved == nil)
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 1040, height: 760)
            .onChange(of: revisionID) { _, _ in load(revisions) }
            .onChange(of: chapterID) { _, id in if let id, store.project(projectID)?.chapters.contains(where: { $0.id == id }) == true { recoverToID = id } }
            .onAppear { revisionID = revisions.first?.id }
            .id(refresh)
            .confirmationDialog(confirmation == .project ? "Restore this entire project revision?" : "Recover this chapter?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Recover saved writing") { recover(revisions) }
            } message: { Text("Your current writing is checkpointed first. Chapter recovery replaces only the selected chapter.") }
    }
    @ViewBuilder private var comparison: some View {
        if let saved, let current = store.project(projectID) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Saved chapter", selection: $chapterID) { Text("Choose chapter").tag(UUID?.none); ForEach(saved.chapters) { Text($0.title).tag(Optional($0.id)) } }
                if let chapter = saved.chapters.first(where: { $0.id == chapterID }) {
                    HStack { Text("Saved passage · select text to recover").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Recover this chapter…") { confirmation = .chapter } }
                    SavedPassagePreview(text: chapter.attributedText, controller: preview).frame(height: 205)
                    HStack {
                        Picker("Append passage to", selection: $recoverToID) { Text("Choose current chapter").tag(UUID?.none); ForEach(current.chapters) { Text($0.title).tag(Optional($0.id)) } }
                        Button("Recover selection") { recoverSelection(chapter) }.disabled(preview.selectionText.isEmpty || recoverToID == nil)
                    }
                    Text("Changes from this save to the current chapter").font(.caption).foregroundStyle(.secondary)
                    let now = current.chapters.first { $0.id == chapter.id }?.plainText ?? ""
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(RevisionComparison.lines(old: chapter.plainText, new: now)) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line.change == -1 ? "−" : line.change == 1 ? "+" : " ").monospaced()
                                    Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(size: 12)).padding(5).background(line.change == -1 ? Color.red.opacity(0.12) : line.change == 1 ? Color.green.opacity(0.12) : .clear)
                            }
                        }
                    }.background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                } else { Text("This revision has no chapters. Restore the project to recover its planning notes and references.").foregroundStyle(.secondary).padding() }
            }
        } else { Text("Choose a saved revision to compare your writing.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private func load(_ revisions: [Revision]) {
        do {
            guard let revision = revisions.first(where: { $0.id == revisionID }) else { saved = nil; return }
            saved = try store.revisionProject(revision, projectID: projectID); chapterID = saved?.chapters.first?.id; loadError = nil
        } catch { saved = nil; loadError = error.localizedDescription }
    }
    private func recover(_ revisions: [Revision]) {
        do {
            if confirmation == .project, let revision = revisions.first(where: { $0.id == revisionID }) { store.restore(revision, projectID: projectID); if store.errorMessage == nil { dismiss() } }
            else if let chapter = saved?.chapters.first(where: { $0.id == chapterID }) { try store.recoverChapter(chapter, projectID: projectID); dismiss(); navigate(StoryDestination(kind: .chapter, itemID: chapter.id)) }
        } catch { loadError = error.localizedDescription }
        confirmation = nil
    }
    private func recoverSelection(_ chapter: Chapter) {
        do {
            guard let destination = recoverToID, let view = preview.textView, NSMaxRange(view.selectedRange()) <= chapter.attributedText.length else { return }
            let text = chapter.attributedText.attributedSubstring(from: view.selectedRange())
            let range = try store.recoverPassage(text, to: destination, projectID: projectID)
            dismiss(); navigate(StoryDestination(kind: .chapter, itemID: destination, range: range, expectedText: store.project(projectID)?.chapters.first { $0.id == destination }?.plainText))
        } catch { loadError = error.localizedDescription }
    }
}
