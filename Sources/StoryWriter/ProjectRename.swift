import AppKit
import SwiftUI

/// One place where an outdated spelling of a renamed character or world entry appears.
struct RenameMention: Identifiable, Equatable {
    enum Place: Hashable { case text, synopsis, comment }
    var id = UUID()
    var chapterID: UUID
    var chapterTitle: String
    var place: Place
    var commentID: UUID?
    var range: NSRange
    var spelling: String
    var tagged: Bool
    var selected: Bool
    var context: String
}

struct RenameGroup: Identifiable, Equatable {
    var spelling: String
    var replacement: String
    var mentions: [RenameMention]
    var id: String { spelling }
}

struct RenamePlan: Equatable {
    var reference: ProjectTagReference
    var title: String
    var groups: [RenameGroup]
    /// Words that begin with an old spelling, such as "Coles"; listed for the writer to check.
    var manualChecks: [RenameMention]
    var taggedCount: Int { groups.reduce(0) { $0 + $1.mentions.filter(\.tagged).count } }
    var chapterCount: Int { Set(groups.flatMap { $0.mentions.filter(\.tagged).map(\.chapterID) }).count }
}

enum ProjectRename {
    /// Finds tagged mentions whose words no longer match any of the object's current names.
    static func plan(project: StoryProject, reference: ProjectTagReference) -> RenamePlan? {
        guard let object = project.tagObjects.first(where: { $0.reference == reference }) else { return nil }
        let current = Set(ObjectTags.nameChoices(object))
        var tagged: [RenameMention] = []
        var texts: [UUID: NSAttributedString] = [:]
        for chapter in project.chapters {
            let text = chapter.attributedText
            texts[chapter.id] = text
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard ProjectTagReference.from(value) == reference else { return }
                let spelling = (text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spelling.isEmpty, !current.contains(spelling) else { return }
                let trimmed = (text.string as NSString).range(of: spelling, options: [], range: range)
                tagged.append(mention(chapter, .text, range: trimmed, in: text.string, tagged: true))
            }
        }
        let unique: [String] = Array(Set(tagged.map(\.spelling)))
        let spellings = unique.sorted { (a: String, b: String) -> Bool in
            let lengthA = a.utf16.count, lengthB = b.utf16.count
            return lengthA == lengthB ? a < b : lengthA > lengthB
        }
        guard !spellings.isEmpty else { return nil }
        var manual: [RenameMention] = []
        let groups = spellings.map { spelling in
            var mentions = tagged.filter { $0.spelling == spelling }
            for chapter in project.chapters {
                let text = texts[chapter.id] ?? chapter.attributedText
                for range in wholeWords(spelling, in: text.string) where !linked(text, range) {
                    mentions.append(mention(chapter, .text, range: range, in: text.string, tagged: false))
                }
                for range in wholeWords(spelling, in: chapter.synopsis) {
                    mentions.append(mention(chapter, .synopsis, range: range, in: chapter.synopsis, tagged: false))
                }
                for comment in chapter.comments ?? [] {
                    for range in wholeWords(spelling, in: comment.note) {
                        var found = mention(chapter, .comment, range: range, in: comment.note, tagged: false)
                        found.commentID = comment.id
                        mentions.append(found)
                    }
                }
                for range in fusedWords(spelling, in: text.string) where !manual.contains(where: { $0.chapterID == chapter.id && $0.range == range }) {
                    manual.append(mention(chapter, .text, range: range, in: text.string, tagged: false))
                }
            }
            return RenameGroup(spelling: spelling, replacement: guess(spelling, title: object.title, spellings: spellings), mentions: mentions)
        }
        return RenamePlan(reference: reference, title: object.title, groups: groups, manualChecks: manual)
    }

    /// Applies the ticked mentions and returns how many were changed. Mentions whose
    /// text changed since planning are skipped, so a stale plan cannot damage prose.
    @discardableResult static func apply(_ plan: RenamePlan, to project: inout StoryProject) throws -> Int {
        var result = project, count = 0
        for index in result.chapters.indices {
            var chapter = result.chapters[index]
            let selected = plan.groups.flatMap { group in
                group.mentions.filter { $0.selected && $0.chapterID == chapter.id }.map { (mention: $0, replacement: group.replacement) }
            }.sorted { $0.mention.range.location > $1.mention.range.location }
            guard !selected.isEmpty else { continue }
            let text = NSMutableAttributedString(attributedString: chapter.attributedText)
            var textChanged = false
            for (mention, replacement) in selected where !replacement.isEmpty {
                switch mention.place {
                case .text:
                    guard NSMaxRange(mention.range) <= text.length, (text.string as NSString).substring(with: mention.range) == mention.spelling else { continue }
                    let renamed = NSMutableAttributedString(attributedString: GrammarText.replacement(text.attributedSubstring(from: mention.range), with: replacement))
                    renamed.addAttribute(.link, value: plan.reference.url, range: NSRange(location: 0, length: renamed.length))
                    text.replaceCharacters(in: mention.range, with: renamed)
                    // Shift scenes, comments, and continuity marks one edit at a time.
                    chapter.rebaseAnnotations(from: chapter.plainText, to: text.string)
                    chapter.plainText = text.string
                    textChanged = true
                case .synopsis:
                    guard let updated = replacing(mention, in: chapter.synopsis, with: replacement) else { continue }
                    chapter.synopsis = updated
                case .comment:
                    guard let commentIndex = chapter.comments?.firstIndex(where: { $0.id == mention.commentID }),
                          let updated = replacing(mention, in: chapter.comments![commentIndex].note, with: replacement) else { continue }
                    chapter.comments![commentIndex].note = updated
                }
                count += 1
            }
            if textChanged { try chapter.setText(text) }
            result.chapters[index] = chapter
        }
        project = result
        return count
    }

    private static func mention(_ chapter: Chapter, _ place: RenameMention.Place, range: NSRange, in text: String, tagged: Bool) -> RenameMention {
        let source = text as NSString
        let start = max(0, range.location - 32), end = min(source.length, NSMaxRange(range) + 32)
        let context = (start > 0 ? "…" : "") + source.substring(with: NSRange(location: start, length: end - start)).replacingOccurrences(of: "\n", with: " ") + (end < source.length ? "…" : "")
        return RenameMention(chapterID: chapter.id, chapterTitle: chapter.title, place: place, range: range, spelling: source.substring(with: range), tagged: tagged, selected: tagged, context: context)
    }

    private static func replacing(_ mention: RenameMention, in text: String, with replacement: String) -> String? {
        let source = text as NSString
        guard NSMaxRange(mention.range) <= source.length, source.substring(with: mention.range) == mention.spelling else { return nil }
        return source.replacingCharacters(in: mention.range, with: replacement)
    }

    private static func linked(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        var found = false
        text.enumerateAttribute(.link, in: range) { value, _, stop in if value != nil { found = true; stop.pointee = true } }
        return found
    }

    private static let wordEdge = "[\\p{L}\\p{M}\\p{N}_]"
    private static func wholeWords(_ spelling: String, in text: String) -> [NSRange] {
        matches("(?<!\(wordEdge))\(NSRegularExpression.escapedPattern(for: spelling))(?!\(wordEdge))", in: text)
    }
    private static func fusedWords(_ spelling: String, in text: String) -> [NSRange] {
        matches("(?<!\(wordEdge))\(NSRegularExpression.escapedPattern(for: spelling))[\\p{L}\\p{M}]+", in: text)
    }
    private static func matches(_ pattern: String, in text: String) -> [NSRange] {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// The new title for a full name; for a single word, the word of the new title in the
    /// same position as in an old full name ("Cole" in "Cole Marsh" becomes "Class").
    private static func guess(_ spelling: String, title: String, spellings: [String]) -> String {
        let titleWords = title.split(separator: " ").map(String.init)
        let words = spelling.split(separator: " ").map(String.init)
        guard words.count == 1, titleWords.count > 1 else { return title }
        for other in spellings {
            let otherWords = other.split(separator: " ").map(String.init)
            if otherWords.count == titleWords.count, let position = otherWords.firstIndex(of: spelling) { return titleWords[position] }
        }
        return titleWords[0]
    }
}

extension View {
    /// Offers to update the manuscript below a name field once the name changes.
    func renameMentions(projectID: UUID?, reference: ProjectTagReference, names: [String]) -> some View {
        modifier(RenameMentionsBanner(projectID: projectID, reference: reference, names: names))
    }
}

/// Offers to update the manuscript once a character or world entry has a new name.
struct RenameMentionsBanner: ViewModifier {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID?
    var reference: ProjectTagReference
    /// The current names; the manuscript is checked again a moment after they change.
    var names: [String]
    @State private var plan: RenamePlan?
    @State private var reviewing: RenamePlan?
    @State private var applied: (before: [Chapter], after: [Chapter], count: Int)?
    @State private var message: String?

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let applied {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Updated \(applied.count) mention\(applied.count == 1 ? "" : "s") in the manuscript.")
                    Spacer(minLength: 0)
                    Button("Undo") { undo() }
                }.font(.system(size: 12))
            } else if let plan, plan.taggedCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(AppTheme.accent)
                    Text("\(plan.taggedCount) tagged mention\(plan.taggedCount == 1 ? "" : "s") in \(plan.chapterCount) chapter\(plan.chapterCount == 1 ? "" : "s") still \(plan.taggedCount == 1 ? "says" : "say") \(plan.groups.map { "“\($0.spelling)”" }.joined(separator: ", ")).")
                    Spacer(minLength: 0)
                    Button("Review & update…") { reviewing = projectID.flatMap(store.project).flatMap { ProjectRename.plan(project: $0, reference: reference) } }
                }.font(.system(size: 12))
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .task(id: names) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let projectID, let project = store.project(projectID) else { return }
            let reference = reference
            let found = await Task.detached(priority: .utility) { ProjectRename.plan(project: project, reference: reference) }.value
            guard !Task.isCancelled else { return }
            plan = found
            if found != nil { applied = nil; message = nil }
        }
        .sheet(item: Binding(get: { reviewing.map { IdentifiedPlan(plan: $0) } }, set: { reviewing = $0?.plan })) { item in
            RenameMentionsSheet(plan: item.plan, cancel: { reviewing = nil }, update: { update($0) })
        }
    }

    private func update(_ chosen: RenamePlan) {
        reviewing = nil
        guard let projectID, let project = store.project(projectID) else { return }
        do {
            try store.namedCheckpoint(projectID, name: "Before renaming mentions to \(chosen.title)")
            var renamed = project
            let count = try ProjectRename.apply(chosen, to: &renamed)
            store.update(projectID) { $0.chapters = renamed.chapters }
            applied = (project.chapters, renamed.chapters, count); plan = nil; message = nil
        } catch { message = "The manuscript was not changed: \(error.localizedDescription)" }
    }

    private func undo() {
        guard let applied else { return }
        self.applied = nil
        guard let projectID, store.project(projectID)?.chapters == applied.after else {
            message = "Chapters changed after the update. Restore the “Before renaming” revision from History instead."
            return
        }
        store.update(projectID) { $0.chapters = applied.before }
        plan = store.project(projectID).flatMap { ProjectRename.plan(project: $0, reference: reference) }
    }
}

private struct IdentifiedPlan: Identifiable {
    var plan: RenamePlan
    var id: String { plan.reference.id }
}

struct RenameMentionsSheet: View {
    @State var plan: RenamePlan
    var cancel: () -> Void
    var update: (RenamePlan) -> Void
    private var selectedCount: Int { plan.groups.reduce(0) { $0 + $1.mentions.filter(\.selected).count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Update mentions of \(plan.title)").font(.headline)
                Text("Tagged mentions are ticked. Untagged mentions, chapter synopses, and comments are listed for you to choose. A revision is saved first.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            List {
                ForEach($plan.groups) { $group in
                    Section {
                        ForEach($group.mentions) { $mention in
                            Toggle(isOn: $mention.selected) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label(mention)).font(.caption).foregroundStyle(.secondary)
                                    Text(mention.context).lineLimit(2)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("“\(group.spelling)” →")
                            TextField("New spelling", text: $group.replacement).frame(width: 180)
                        }
                    }
                }
                if !plan.manualChecks.isEmpty {
                    Section("Check by hand") {
                        ForEach(plan.manualChecks) { mention in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(mention.chapterTitle) · “\(mention.spelling)”").font(.caption).foregroundStyle(.secondary)
                                Text(mention.context).lineLimit(2)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Update \(selectedCount) mention\(selectedCount == 1 ? "" : "s")") { update(plan) }
                    .keyboardShortcut(.defaultAction).disabled(selectedCount == 0)
            }.padding(16)
        }.frame(width: 560, height: 520).tint(AppTheme.accent)
    }

    private func label(_ mention: RenameMention) -> String {
        let place: String
        switch mention.place {
        case .text: place = mention.tagged ? "Tagged" : "Untagged"
        case .synopsis: place = "Synopsis"
        case .comment: place = "Comment"
        }
        return "\(mention.chapterTitle) · \(place)"
    }
}
