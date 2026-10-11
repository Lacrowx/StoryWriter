import SwiftUI
import AppKit

struct ChapterGrammarReport: Identifiable {
    var id: UUID
    var title: String
    var snapshot: String
    var corrections: [LocatedCorrection]
    var context: WritingReviewContext? = nil
}

@MainActor
final class ManuscriptGrammarReview: ObservableObject {
    @Published var reports: [ChapterGrammarReport] = []
    @Published var checking = false
    @Published var finished = 0
    @Published var total = 0
    @Published var message: String?
    @Published var canUndo = false
    private var task: Task<Void, Never>?
    private var previousChapters: [Chapter] = []
    private var previousReports: [ChapterGrammarReport] = []
    private var appliedData: [UUID: ChapterText] = [:]
    var correctionCount: Int { reports.reduce(0) { $0 + $1.corrections.count } }

    func review(_ project: StoryProject) {
        task?.cancel(); reports = []; checking = true; finished = 0; total = project.chapters.count; message = nil
        task = Task { [weak self] in
            do {
                for chapter in project.chapters {
                    try Task.checkCancellation()
                    var corrections: [LocatedCorrection] = []
                    for (chunk, offset) in GrammarText.chunks(chapter.plainText, range: NSRange(location: 0, length: chapter.plainText.utf16.count), limit: LocalGrammarService.shared.chunkLimit) {
                        try Task.checkCancellation()
                        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let issues = try await LocalGrammarService.shared.review(chunk, context: project.reviewContext(chapter: chapter))
                        try Task.checkCancellation()
                        for correction in GrammarText.locate(issues, chunk: chunk, offset: offset) where !corrections.contains(where: { NSIntersectionRange($0.range, correction.range).length > 0 }) { corrections.append(correction) }
                    }
                    let report = ChapterGrammarReport(id: chapter.id, title: chapter.title, snapshot: chapter.plainText, corrections: corrections, context: project.reviewContext(chapter: chapter))
                    self?.reports.append(report); self?.finished += 1
                    LocalGrammarService.shared.publishResult(CachedGrammarResult(snapshot: chapter.plainText, corrections: corrections, reviewed: true, context: project.reviewContext(chapter: chapter)), key: project.reviewContext().storageKey("\(chapter.id.uuidString)/body"))
                }
                self?.checking = false
            } catch is CancellationError { return }
            catch { guard !Task.isCancelled else { return }; self?.checking = false; self?.message = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel(); checking = false }

    func accept(_ ids: Set<UUID>, projectID: UUID, store: ProjectStore) {
        guard !checking, let project = store.project(projectID) else { return }
        do {
            let selectedReports = reports.filter { $0.corrections.contains { ids.contains($0.id) } }
            guard !selectedReports.isEmpty else { return }
            var prepared: [Chapter] = []
            var originals: [Chapter] = []
            let oldReports = reports
            for report in selectedReports {
                guard var chapter = project.chapters.first(where: { $0.id == report.id }), chapter.plainText == report.snapshot else {
                    throw ProjectError.invalid("\(report.title) changed after it was reviewed. Review the manuscript again before accepting this group.")
                }
                guard report.context == nil || report.context == project.reviewContext(chapter: chapter) else {
                    throw ProjectError.invalid("The character records or writing context changed. Review the manuscript again before accepting this group.")
                }
                originals.append(chapter)
                let text = NSMutableAttributedString(attributedString: chapter.attributedText)
                for correction in report.corrections.filter({ ids.contains($0.id) }).sorted(by: { $0.range.location > $1.range.location }) {
                    guard NSMaxRange(correction.range) <= text.length, (text.string as NSString).substring(with: correction.range) == correction.issue.original else { throw ProjectError.invalid("A suggested passage has changed. Review it again.") }
                    text.replaceCharacters(in: correction.range, with: GrammarText.replacement(text.attributedSubstring(from: correction.range), with: correction.issue.replacement))
                }
                try chapter.setText(text); prepared.append(chapter)
            }
            guard store.saveNow() else { return }
            try store.checkpoint(projectID)
            store.update(projectID) { project in
                for chapter in prepared { if let index = project.chapters.firstIndex(where: { $0.id == chapter.id }) { project.chapters[index] = chapter } }
            }
            previousChapters = originals; previousReports = oldReports; appliedData = Dictionary(uniqueKeysWithValues: prepared.map { ($0.id, $0.richText) }); canUndo = true
            for chapter in prepared {
                guard let index = reports.firstIndex(where: { $0.id == chapter.id }) else { continue }
                let remaining = reports[index].corrections.filter { !ids.contains($0.id) }
                reports[index].corrections = GrammarText.rebase(remaining, old: reports[index].snapshot, new: chapter.plainText)
                reports[index].snapshot = chapter.plainText
                LocalGrammarService.shared.publishResult(CachedGrammarResult(snapshot: chapter.plainText, corrections: reports[index].corrections, reviewed: true, context: project.reviewContext(chapter: chapter)), key: project.reviewContext().storageKey("\(chapter.id.uuidString)/body"))
            }
            message = nil
        } catch { message = error.localizedDescription }
    }

    func undo(projectID: UUID, store: ProjectStore) {
        guard let project = store.project(projectID), canUndo else { return }
        guard previousChapters.allSatisfy({ original in project.chapters.first { $0.id == original.id }?.richText == appliedData[original.id] }) else { message = "The accepted text has been edited since. Use saved revisions to recover the earlier text."; return }
        store.update(projectID) { project in for chapter in previousChapters { if let index = project.chapters.firstIndex(where: { $0.id == chapter.id }) { project.chapters[index] = chapter } } }
        reports = previousReports; canUndo = false
        for report in reports { LocalGrammarService.shared.publishResult(CachedGrammarResult(snapshot: report.snapshot, corrections: report.corrections, reviewed: true, context: report.context ?? project.reviewContext(chapter: project.chapters.first { $0.id == report.id })), key: project.reviewContext().storageKey("\(report.id.uuidString)/body")) }
    }
}

struct ManuscriptReviewSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    @Binding var chapterID: UUID?
    @StateObject private var review = ManuscriptGrammarReview()
    @ObservedObject private var service = LocalGrammarService.shared
    @AppStorage("writingLanguage") private var language = "auto"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Review the entire manuscript", subtitle: "Suggestions are also marked in each chapter. Accept them individually, by chapter, or all together.")
            HStack {
                WritingBackendControls()
                Picker("Language", selection: $language) { Text("Automatic").tag("auto"); Text("English").tag("en"); Text("Deutsch").tag("de") }.frame(width: 180)
            }
            HStack {
                Button(review.checking ? "Reviewing…" : "Review manuscript") { if let project = store.project(projectID) { review.review(project) } }.buttonStyle(.borderedProminent).disabled(review.checking)
                if review.checking { ProgressView(value: Double(review.finished), total: Double(max(1, review.total))).frame(width: 150); Text("\(review.finished) / \(review.total) chapters").font(.caption); Button("Cancel") { review.cancel() } }
                Spacer()
                Text("\(review.correctionCount) suggestions").foregroundStyle(.secondary)
            }
            if let message = review.message ?? service.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(review.reports) { report in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(report.title).font(.headline)
                                Spacer()
                                Button("View in editor") { chapterID = report.id; dismiss() }
                                if !report.corrections.isEmpty { Button("Accept chapter") { review.accept(Set(report.corrections.map(\.id)), projectID: projectID, store: store) }.disabled(review.checking) }
                            }
                            if report.corrections.isEmpty { Text("No remaining suggestions").font(.caption).foregroundStyle(.secondary) }
                            ForEach(report.corrections) { correction in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(correction.issue.category.label).font(.caption.weight(.semibold)).foregroundStyle(correction.issue.category.color)
                                    Text(correction.issue.original).foregroundStyle(.secondary).strikethrough()
                                    Text(correction.issue.replacement).foregroundStyle(AppTheme.accent)
                                    HStack { Text(correction.issue.explanation).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Accept") { review.accept([correction.id], projectID: projectID, store: store) }.disabled(review.checking) }
                                }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }.cardSurface()
                    }
                }
            }.frame(minHeight: 300)
            HStack {
                if review.canUndo { Button("Undo last acceptance") { review.undo(projectID: projectID, store: store) } }
                Spacer()
                Button("Done") { review.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Accept all in manuscript") { review.accept(Set(review.reports.flatMap(\.corrections).map(\.id)), projectID: projectID, store: store) }.buttonStyle(.borderedProminent).disabled(review.checking || review.correctionCount == 0)
            }
            Text("A saved revision protects your manuscript before a group is applied.").font(.caption2).foregroundStyle(.secondary)
        }.padding(28).frame(width: 820, height: 720).writerSheet().task { await service.ensureConnection() }.onDisappear { review.cancel() }
    }
}
