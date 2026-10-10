import AppKit
import SwiftUI

struct StoryScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Scene"
    var start = 0
    var synopsis = ""
    var viewpointID: UUID?
    var locationID: UUID?
    var status: DraftStatus = .planned
    var timelineOrder: Int?
    var storyTime = ""
}

struct PassageComment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Int
    var length: Int
    var quote: String
    var note: String
    var ink: CommentInk?
    var resolved = false
    var detached = false
    var createdAt = Date()
    var range: NSRange { NSRange(location: start, length: length) }
}

/// A minimal changed interval, measured in UTF-16, with boundaries on whole characters.
struct PassageEdit {
    var range: NSRange
    var replacementLength: Int
    var delta: Int { replacementLength - range.length }
    init(old: String, new: String) {
        let a = Array(old), b = Array(new)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let offset = a.prefix(prefix).reduce(0) { $0 + String($1).utf16.count }
        range = NSRange(location: offset, length: a[prefix..<(a.count - suffix)].reduce(0) { $0 + String($1).utf16.count })
        replacementLength = b[prefix..<(b.count - suffix)].reduce(0) { $0 + String($1).utf16.count }
    }
    func boundary(_ position: Int) -> Int {
        if position <= range.location { return position }
        if position >= NSMaxRange(range) { return position + delta }
        return range.location + replacementLength
    }
}

extension Chapter {
    var orderedScenes: [StoryScene] { (scenes ?? []).enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element) }
    func range(of scene: StoryScene) -> NSRange {
        let entries = orderedScenes
        let index = entries.firstIndex { $0.id == scene.id }
        let end = index.flatMap { entries.indices.contains($0 + 1) ? entries[$0 + 1].start : nil } ?? plainText.utf16.count
        return NSRange(location: scene.start, length: max(0, end - scene.start))
    }
    mutating func rebaseAnnotations(from old: String, to new: String) {
        guard old != new else { return }
        let edit = PassageEdit(old: old, new: new)
        if let events = continuityEvents { continuityEvents = Continuity.rebase(events, old: old, new: new) }
        if var entries = scenes {
            for i in entries.indices { entries[i].start = min(new.utf16.count, edit.boundary(entries[i].start)) }
            if !entries.isEmpty { entries[0].start = 0 }
            scenes = entries
        }
        if var entries = comments {
            for i in entries.indices where !entries[i].detached {
                let anchor = entries[i].range
                if edit.range.length == 0 {
                    let inserted = (new as NSString).substring(with: NSRange(location: edit.range.location, length: edit.replacementLength))
                    if edit.range.location == NSMaxRange(anchor), inserted.first?.isLetter == true, entries[i].quote.last?.isLetter == true { entries[i].detached = true }
                    else if edit.range.location == anchor.location, inserted.last?.isLetter == true, entries[i].quote.first?.isLetter == true { entries[i].detached = true }
                    else if edit.range.location <= anchor.location { entries[i].start += edit.delta }
                    else if edit.range.location < NSMaxRange(anchor) { entries[i].detached = true }
                } else if NSMaxRange(edit.range) <= anchor.location { entries[i].start += edit.delta }
                else if NSIntersectionRange(anchor, edit.range).length > 0 { entries[i].detached = true }
                if !entries[i].detached, NSMaxRange(entries[i].range) <= new.utf16.count {
                    entries[i].quote = (new as NSString).substring(with: entries[i].range)
                }
            }
            comments = entries
        }
    }
    mutating func ensureScene() {
        if scenes?.isEmpty != false { scenes = [StoryScene(title: title, status: status)] }
    }
    mutating func splitScene(at offset: Int) throws {
        let text = plainText as NSString
        guard offset > 0, offset < text.length,
              text.rangeOfComposedCharacterSequence(at: offset).location == offset else {
            throw ProjectError.invalid("Place the cursor inside the chapter, between characters, to split a scene.")
        }
        ensureScene()
        guard !(scenes ?? []).contains(where: { $0.start == offset }) else { throw ProjectError.invalid("A scene already starts here.") }
        let number = (scenes?.count ?? 0) + 1
        scenes?.append(StoryScene(title: "Scene \(number)", start: offset, status: status))
        scenes?.sort { $0.start < $1.start }
    }
    mutating func mergeScene(_ id: UUID) throws {
        guard let index = scenes?.firstIndex(where: { $0.id == id }), index > 0 else { throw ProjectError.invalid("Choose a scene after the first to merge it with the previous scene.") }
        scenes?.remove(at: index)
    }
    mutating func moveScene(_ id: UUID, offset: Int) throws {
        var entries = orderedScenes
        guard let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        let source = attributedText
        let ranges = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, range(of: $0)) })
        entries.swapAt(index, index + offset)
        let result = NSMutableAttributedString(string: "")
        let originalComments = comments ?? []
        var mappedComments = originalComments
        let originalEvents = continuityEvents ?? []
        var mappedEvents = originalEvents
        for i in entries.indices {
            let previous = ranges[entries[i].id]!
            let piece = source.attributedSubstring(from: previous)
            if result.length > 0, piece.length > 0 {
                let trailing = result.string.reversed().prefix(while: { $0 == "\n" }).count
                let leading = piece.string.prefix(while: { $0 == "\n" }).count
                if trailing + leading < 2 { result.append(NSAttributedString(string: String(repeating: "\n", count: 2 - trailing - leading), attributes: WritingStyle.attributes)) }
            }
            let start = result.length
            entries[i].start = start
            result.append(piece)
            for j in mappedComments.indices where !originalComments[j].detached && NSLocationInRange(originalComments[j].start, previous) {
                if NSMaxRange(originalComments[j].range) <= NSMaxRange(previous) { mappedComments[j].start = start + originalComments[j].start - previous.location }
                else { mappedComments[j].detached = true }
            }
            for j in mappedEvents.indices where !originalEvents[j].detached {
                let event = originalEvents[j]
                let belongs = NSLocationInRange(event.start, previous) || (event.length == 0 && event.start == source.length && NSMaxRange(previous) == source.length)
                guard belongs else { continue }
                if event.effectiveOffset <= NSMaxRange(previous) { mappedEvents[j].start = start + event.start - previous.location }
                else { mappedEvents[j].detached = true }
            }
        }
        // Validate serialization before replacing either text or its metadata.
        let data = try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        richText = data; plainText = result.string; scenes = entries; comments = mappedComments
        continuityEvents = mappedEvents.isEmpty ? nil : mappedEvents
    }
    mutating func addComment(range: NSRange, note: String) throws {
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= plainText.utf16.count else { throw ProjectError.invalid("Select a passage to attach a comment.") }
        let comment = PassageComment(start: range.location, length: range.length, quote: (plainText as NSString).substring(with: range), note: note)
        if comments == nil { comments = [] }
        comments?.append(comment)
    }
}

enum StoryDestinationKind: String { case chapter, character, world, reference }
struct StoryDestination: Equatable {
    var token = UUID()
    var kind: StoryDestinationKind
    var itemID: UUID
    var field = "body"
    var range: NSRange?
    var expectedText: String?
}
struct PassageResult: Identifiable {
    var destination: StoryDestination
    var title: String
    var category: String
    var preview: String
    var id: UUID { destination.token }
}

enum StorySearch {
    static func ranges(_ query: String, in text: String, wholeName: Bool = false) -> [NSRange] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if wholeName {
            let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: query) + #"(?![\p{L}\p{N}_])"#
            return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range) ?? []
        }
        let source = text as NSString
        var remaining = NSRange(location: 0, length: source.length), result: [NSRange] = []
        while remaining.length > 0 {
            let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard match.location != NSNotFound else { break }
            result.append(match)
            remaining = NSRange(location: NSMaxRange(match), length: source.length - NSMaxRange(match))
        }
        return result
    }
    static func preview(_ text: String, range: NSRange) -> String {
        let source = text as NSString
        let start = max(0, range.location - 65), end = min(source.length, NSMaxRange(range) + 100)
        let safe = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return (start > 0 ? "…" : "") + source.substring(with: safe).replacingOccurrences(of: "\n", with: " ") + (end < source.length ? "…" : "")
    }
    static func results(in project: StoryProject, query: String, manuscriptOnly: Bool = false) -> [PassageResult] {
        var result: [PassageResult] = []
        func field(_ text: String, _ name: String, _ title: String, _ category: String, _ kind: StoryDestinationKind, _ id: UUID) {
            for range in ranges(query, in: text) {
                result.append(PassageResult(destination: StoryDestination(kind: kind, itemID: id, field: name, range: range, expectedText: text), title: title, category: category, preview: preview(text, range: range)))
            }
        }
        for chapter in project.chapters {
            field(chapter.plainText, "body", chapter.title, "Manuscript", .chapter, chapter.id)
            field(chapter.title, "chapter title", chapter.title, "Chapter title", .chapter, chapter.id)
            field(chapter.synopsis, "synopsis", chapter.title, "Chapter synopsis", .chapter, chapter.id)
        }
        if manuscriptOnly { return result }
        for character in project.characters {
            let fields = [("name", character.name), ("role in the story", character.role), ("pronouns", character.pronouns), ("appearance & mannerisms", character.appearance), ("personality & voice", character.personality), ("wants & needs", character.motivation), ("conflict & secrets", character.conflict), ("character arc", character.arc), ("relationships", character.relationships), ("other notes", character.notes), ("aliases", (character.aliases ?? []).joined(separator: ","))]
            for (name, text) in fields { field(text, name, character.name, "Character · \(name)", .character, character.id) }
        }
        for note in project.worldNotes {
            for (name, text) in [("title", note.title), ("at a glance", note.summary), ("details & rules", note.details), ("connections & continuity", note.connections), ("aliases", (note.aliases ?? []).joined(separator: ","))] { field(text, name, note.title, "World · \(name)", .world, note.id) }
        }
        for source in project.sources {
            field(source.title, "reference title", source.title, "Reference title", .reference, source.id)
            field(source.notes, "reference note", source.title, "Reference notes", .reference, source.id)
            // Tags are searchable and navigate to their reference.
            if !ranges(query, in: source.tags).isEmpty { result.append(PassageResult(destination: StoryDestination(kind: .reference, itemID: source.id), title: source.title, category: "Reference tags", preview: source.tags)) }
        }
        return result
    }
    static func backlinks(in project: StoryProject, to reference: ProjectTagReference) -> [PassageResult] {
        let names: [String]
        if reference.kind == .character, let character = project.characters.first(where: { $0.id == reference.objectID }) {
            let first = character.name.split(separator: " ").first.map(String.init) ?? ""
            let uniqueFirst = character.name.contains(" ") && !project.characters.contains { $0.id != character.id && $0.name.split(separator: " ").first?.lowercased() == first.lowercased() }
            names = [character.name] + (character.aliases ?? []) + (uniqueFirst ? [first] : [])
        }
        else if let note = project.worldNotes.first(where: { $0.id == reference.objectID }) { names = [note.title] + (note.aliases ?? []) }
        else { return [] }
        var result: [PassageResult] = []
        for chapter in project.chapters {
            var linked: [NSRange] = []
            let text = chapter.attributedText
            text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if ProjectTagReference.from(value) == reference { linked.append(range) }
            }
            var matches = linked.map { ($0, "Tagged") }
            for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) {
                for range in ranges(name, in: chapter.plainText, wholeName: true) where !matches.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) { matches.append((range, "Name match")) }
            }
            for (range, category) in matches.sorted(by: { $0.0.location < $1.0.location }) {
                result.append(PassageResult(destination: StoryDestination(kind: .chapter, itemID: chapter.id, range: range, expectedText: chapter.plainText), title: chapter.title, category: category, preview: preview(chapter.plainText, range: range)))
            }
        }
        return result
    }
}

private struct NavigateStoryKey: EnvironmentKey { static let defaultValue: (StoryDestination) -> Void = { _ in } }
private struct StoryDestinationKey: EnvironmentKey { static let defaultValue: StoryDestination? = nil }
private struct PinResearchKey: EnvironmentKey { static let defaultValue: (PinnedResearch) -> Void = { _ in } }
extension EnvironmentValues {
    var navigateStory: (StoryDestination) -> Void { get { self[NavigateStoryKey.self] } set { self[NavigateStoryKey.self] = newValue } }
    var storyDestination: StoryDestination? { get { self[StoryDestinationKey.self] } set { self[StoryDestinationKey.self] = newValue } }
    var pinResearch: (PinnedResearch) -> Void { get { self[PinResearchKey.self] } set { self[PinResearchKey.self] = newValue } }
}
enum PinnedResearch: Hashable { case object(ProjectTagReference), source(UUID) }

struct PassageResultRow: View {
    var result: PassageResult
    var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.title).font(.system(size: 12, weight: .semibold))
            Text(result.category).font(.caption2).foregroundStyle(.secondary)
            Text(highlighted).font(.caption).lineLimit(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }
    private var highlighted: AttributedString {
        var value = AttributedString(result.preview)
        for match in StorySearch.ranges(query, in: result.preview) {
            if let swiftRange = Range(match, in: result.preview), let range = Range(swiftRange, in: value) { value[range].backgroundColor = .yellow.opacity(0.3); value[range].font = .system(size: 12, weight: .semibold) }
        }
        return value
    }
}

struct BacklinksView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.navigateStory) private var navigate
    var projectID: UUID
    var reference: ProjectTagReference
    var body: some View {
        let results = store.project(projectID).map { StorySearch.backlinks(in: $0, to: reference) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            Text("Appears in · \(results.count)").font(.headline)
            if results.isEmpty { Text("Tag this object in your writing, or add an alias to find its mentions.").font(.caption).foregroundStyle(.secondary) }
            ForEach(results) { result in Button { navigate(result.destination) } label: { PassageResultRow(result: result) }.buttonStyle(.plain); Divider() }
        }
    }
}

@MainActor
enum EditorNavigation {
    static func select(_ destination: StoryDestination, in view: NSTextView) {
        guard let range = destination.range, range.location >= 0, NSMaxRange(range) <= view.string.utf16.count,
              destination.expectedText == nil || destination.expectedText == view.string else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range); view.scrollRangeToVisible(range)
        view.showFindIndicator(for: range)
    }
}
