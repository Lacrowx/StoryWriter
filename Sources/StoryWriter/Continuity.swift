import Foundation

enum ContinuityCategory: String, Codable, CaseIterable, Identifiable {
    case knowledge, possession, task, rule
    var id: String { rawValue }
    var label: String {
        switch self { case .knowledge: return "Knows"; case .possession: return "Has"; case .task: return "Needs to do"; case .rule: return "Must follow" }
    }
    var noun: String {
        switch self { case .knowledge: return "Information"; case .possession: return "Possession"; case .task: return "Task"; case .rule: return "Rule / promise" }
    }
    var actions: [ContinuityAction] {
        switch self {
        case .knowledge: return [.learns, .believes, .suspects, .confirmed, .reminded, .forgets]
        case .possession: return [.gets, .loses]
        case .task: return [.assigned, .completed, .failed, .abandoned]
        case .rule: return [.applies, .broken, .released]
        }
    }
}

enum ContinuityAction: String, Codable, CaseIterable, Identifiable {
    case learns, believes, suspects, confirmed, reminded, forgets
    case gets, loses, assigned, completed, failed, abandoned, applies, broken, released
    var id: String { rawValue }
    var label: String {
        switch self {
        case .learns: return "Learns"; case .believes: return "Believes"; case .suspects: return "Suspects"
        case .confirmed: return "Confirms"; case .reminded: return "Is reminded"; case .forgets: return "Forgets"
        case .gets: return "Gets"; case .loses: return "Loses"; case .assigned: return "Is assigned"
        case .completed: return "Completes"; case .failed: return "Fails"; case .abandoned: return "Abandons"
        case .applies: return "Must follow"; case .broken: return "Breaks"; case .released: return "Is released from"
        }
    }
    var category: ContinuityCategory {
        if [.learns, .believes, .suspects, .confirmed, .reminded, .forgets].contains(self) { return .knowledge }
        if [.gets, .loses].contains(self) { return .possession }
        if [.assigned, .completed, .failed, .abandoned].contains(self) { return .task }
        return .rule
    }
    var active: Bool { ![.forgets, .loses, .completed, .failed, .abandoned, .released].contains(self) }
    var status: String? {
        switch self {
        case .believes: return "Believes"; case .suspects: return "Suspects"; case .forgets: return "Forgotten"
        case .loses: return "No longer has"; case .completed: return "Completed"; case .failed: return "Failed"
        case .abandoned: return "Abandoned"; case .broken: return "Broken · still applies"; case .released: return "No longer applies"
        default: return nil
        }
    }
}

/// Shared identity; manuscript wording is never used as an identifier.
struct ContinuityItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var category: ContinuityCategory
    var aliases: [String] = []
    var details = ""
    var parentID: UUID?
    var worldObjectID: UUID?
}

/// Stored with its chapter so passage edits and scene moves can carry the anchor.
struct ContinuityEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var itemID: UUID
    var characterID: UUID
    var action: ContinuityAction
    var start = 0
    var length = 0
    var quote = ""
    var note = ""
    var detached = false
    var planned = false
    var range: NSRange { NSRange(location: start, length: length) }
    var effectiveOffset: Int { start + length }
}

struct ContinuityLocation: Comparable, Equatable {
    var rank: Int
    var offset: Int
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.rank, lhs.offset) < (rhs.rank, rhs.offset) }
}

struct LocatedContinuityEvent: Identifiable {
    var event: ContinuityEvent
    var chapterID: UUID?
    var location: ContinuityLocation
    var sequence: Int
    var id: UUID { event.id }
}

struct ContinuityState: Identifiable {
    var item: ContinuityItem
    var latest: LocatedContinuityEvent
    var id: UUID { item.id }
}

struct ObjectCharacterState: Identifiable {
    var character: Character
    var knowledge: ContinuityState?
    var possession: ContinuityState?
    var id: UUID { character.id }
    var knowledgeLabel: String {
        guard let action = knowledge?.latest.event.action else { return "No knowledge recorded" }
        switch action {
        case .learns, .confirmed: return "Knows about it"
        case .believes: return "Believes"
        case .suspects: return "Suspects"
        case .forgets: return "Forgotten"
        default: return "No knowledge recorded"
        }
    }
}

enum Continuity {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func matches(_ items: [ContinuityItem], query: String, category: ContinuityCategory? = nil) -> [ContinuityItem] {
        let q = normalized(query)
        let tokens = Set(q.split(separator: " ").map(String.init))
        func score(_ item: ContinuityItem) -> Int {
            guard !q.isEmpty else { return 1 }
            let names = ([item.name] + item.aliases).map(normalized).filter { !$0.isEmpty }
            if names.contains(q) { return 1000 }
            if names.contains(where: { $0.contains(q) || q.contains($0) }) { return 500 }
            let nameTokens = Set(names.joined(separator: " ").split(separator: " ").map(String.init))
            let shared = tokens.intersection(nameTokens).count
            if shared > 0 { return 100 * shared / max(1, tokens.count) }
            return normalized(item.details).contains(q) ? 1 : 0
        }
        let candidates = items.filter { category == nil || $0.category == category }
        let scored: [(item: ContinuityItem, score: Int)] = candidates.map { ($0, score($0)) }
        let sorted = scored.filter { $0.score > 0 }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.item.name.localizedStandardCompare(b.item.name) == .orderedAscending
        }
        return sorted.map { $0.item }
    }
    static func exactMatch(_ items: [ContinuityItem], name: String, category: ContinuityCategory, parentID: UUID? = nil) -> ContinuityItem? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        let matches = items.filter { $0.category == category && $0.parentID == parentID && ([$0.name] + $0.aliases).contains { normalized($0) == key } }
        return matches.count == 1 ? matches.first : nil
    }

    private struct Segment {
        var chapterID: UUID
        var start: Int
        var order: Int?
        var chapterIndex: Int
        var sceneIndex: Int
    }
    private static func segments(_ project: StoryProject) -> [Segment] {
        project.chapters.enumerated().flatMap { c, chapter -> [Segment] in
            if chapter.orderedScenes.isEmpty { return [Segment(chapterID: chapter.id, start: 0, chapterIndex: c, sceneIndex: 0)] }
            return chapter.orderedScenes.enumerated().map { s, scene in Segment(chapterID: chapter.id, start: scene.start, order: scene.timelineOrder, chapterIndex: c, sceneIndex: s) }
        }.sorted { ($0.order ?? Int.max, $0.chapterIndex, $0.sceneIndex) < ($1.order ?? Int.max, $1.chapterIndex, $1.sceneIndex) }
    }
    static func location(in project: StoryProject, chapterID: UUID, offset: Int, sourceStart: Int? = nil) -> ContinuityLocation? {
        location(in: segments(project), chapterID: chapterID, offset: offset, sourceStart: sourceStart)
    }
    private static func location(in entries: [Segment], chapterID: UUID, offset: Int, sourceStart: Int? = nil) -> ContinuityLocation? {
        let point = sourceStart ?? offset
        guard let segment = entries.filter({ $0.chapterID == chapterID && $0.start <= point }).max(by: { $0.start < $1.start }),
              let rank = entries.firstIndex(where: { $0.chapterID == segment.chapterID && $0.start == segment.start }) else { return nil }
        return ContinuityLocation(rank: rank, offset: offset - segment.start)
    }
    static func history(in project: StoryProject, itemID: UUID? = nil, characterID: UUID? = nil, itemIDs: Set<UUID>? = nil) -> [LocatedContinuityEvent] {
        let segments = segments(project)
        var result: [LocatedContinuityEvent] = []
        for event in project.initialContinuity ?? [] where itemIDs == nil || itemIDs!.contains(event.itemID) {
            result.append(LocatedContinuityEvent(event: event, location: ContinuityLocation(rank: -1, offset: 0), sequence: result.count))
        }
        for chapter in project.chapters {
            for event in chapter.continuityEvents ?? [] {
                guard (itemID == nil || event.itemID == itemID), (characterID == nil || event.characterID == characterID),
                      itemIDs == nil || itemIDs!.contains(event.itemID),
                      let location = location(in: segments, chapterID: chapter.id, offset: event.effectiveOffset, sourceStart: event.start) else { continue }
                result.append(LocatedContinuityEvent(event: event, chapterID: chapter.id, location: location, sequence: result.count))
            }
        }
        return result.filter { (itemID == nil || $0.event.itemID == itemID) && (characterID == nil || $0.event.characterID == characterID) }
            .sorted { $0.location == $1.location ? $0.sequence < $1.sequence : $0.location < $1.location }
    }
    static func states(in project: StoryProject, characterID: UUID, chapterID: UUID, offset: Int, sourceStart: Int? = nil) -> [ContinuityState] {
        snapshots(in: project, chapterID: chapterID, offset: offset, sourceStart: sourceStart, characterID: characterID)[characterID] ?? []
    }
    private static func snapshots(in project: StoryProject, chapterID: UUID, offset: Int, sourceStart: Int? = nil, characterID: UUID? = nil, itemIDs: Set<UUID>? = nil) -> [UUID: [ContinuityState]] {
        guard let cursor = location(in: project, chapterID: chapterID, offset: offset, sourceStart: sourceStart) else { return [:] }
        var latest: [UUID: [UUID: LocatedContinuityEvent]] = [:]
        for entry in history(in: project, characterID: characterID, itemIDs: itemIDs) where entry.location <= cursor && !entry.event.detached && !entry.event.planned {
            // Repetition is evidence of a mention, not a new first acquisition.
            if entry.event.action != .reminded { latest[entry.event.characterID, default: [:]][entry.event.itemID] = entry }
        }
        let items = Dictionary(uniqueKeysWithValues: project.trackedContinuityItems.map { ($0.id, $0) })
        return latest.mapValues { entries in
            entries.compactMap { id, entry in items[id].map { ContinuityState(item: $0, latest: entry) } }
                .sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
        }
    }
    static func objectStates(in project: StoryProject, worldID: UUID, chapterID: UUID, offset: Int) -> [ObjectCharacterState] {
        let knowledgeIDs = Set(project.continuityChoices(for: .knowledge).filter { $0.worldObjectID == worldID }.map(\.id))
        let possessionIDs = Set(project.continuityChoices(for: .possession).filter { $0.worldObjectID == worldID }.map(\.id))
        let snapshots = snapshots(in: project, chapterID: chapterID, offset: offset, itemIDs: knowledgeIDs.union(possessionIDs))
        return project.characters.map { person in
            let states = snapshots[person.id] ?? []
            return ObjectCharacterState(character: person, knowledge: states.first { knowledgeIDs.contains($0.id) }, possession: states.first { possessionIDs.contains($0.id) })
        }
    }
    static func viewpoint(in chapter: Chapter, offset: Int) -> UUID? {
        chapter.orderedScenes.last(where: { $0.start <= offset })?.viewpointID
    }
    static func validatesAnchor(_ event: ContinuityEvent, in text: String) -> Bool {
        let count = text.utf16.count
        guard event.start >= 0, event.length >= 0, event.start <= count, event.length <= count - event.start else { return false }
        guard wholeCharacters(event.range, in: text), let range = Range(event.range, in: text) else { return false }
        return String(text[range]) == event.quote
    }
    static func anchor(_ event: inout ContinuityEvent, range: NSRange, text: String) throws {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location, wholeCharacters(range, in: text), let swiftRange = Range(range, in: text) else { throw ProjectError.invalid("Select a valid manuscript passage or place the cursor between characters.") }
        event.start = range.location; event.length = range.length; event.quote = String(text[swiftRange]); event.detached = false
    }
    private static func wholeCharacters(_ range: NSRange, in text: String) -> Bool {
        let source = text as NSString
        return [range.location, NSMaxRange(range)].allSatisfy { $0 == source.length || source.rangeOfComposedCharacterSequence(at: $0).location == $0 }
    }
    static func rebase(_ events: [ContinuityEvent], old: String, new: String, edit suppliedEdit: PassageEdit? = nil) -> [ContinuityEvent] {
        let edit = suppliedEdit ?? PassageEdit(old: old, new: new)
        return events.map { original in
            var event = original
            guard !event.detached else { return event }
            let start = event.start, end = event.effectiveOffset
            if event.length == 0 {
                if edit.range.length > 0 && edit.range.location <= start && NSMaxRange(edit.range) > start { event.detached = true }
                else if NSMaxRange(edit.range) < start || (edit.range.length > 0 && NSMaxRange(edit.range) == start) { event.start += edit.delta }
                // Inserting at the point happens after the recorded event.
            } else if edit.range.length == 0 {
                if edit.range.location <= start { event.start += edit.delta }
                else if edit.range.location < end { event.detached = true }
                else if edit.range.location == end {
                    let inserted = (new as NSString).substring(with: NSRange(location: edit.range.location, length: edit.replacementLength))
                    if inserted.first?.isLetter == true && event.quote.last?.isLetter == true { event.detached = true }
                }
            } else if NSMaxRange(edit.range) <= start { event.start += edit.delta }
            else if NSIntersectionRange(event.range, edit.range).length > 0 { event.detached = true }
            if !event.detached && !validatesAnchor(event, in: new) { event.detached = true }
            return event
        }
    }
}

extension StoryProject {
    @discardableResult mutating func addStoryObject(name: String, summary: String = "") throws -> WorldNote {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Continuity.normalized(title).isEmpty else { throw ProjectError.invalid("Give the object a name.") }
        let key = Continuity.normalized(title)
        let existing = worldNotes.filter { $0.category == .object && ([$0.title] + ($0.aliases ?? [])).contains { Continuity.normalized($0) == key } }
        guard existing.count <= 1 else { throw ProjectError.invalid("Several objects use this name. Choose the intended object from World or give this one a distinct name.") }
        if let object = existing.first { return object }
        let object = WorldNote(title: title, category: .object, summary: summary)
        worldNotes.append(object)
        return object
    }
    /// Only recorded identities appear in character state; World items are offered separately.
    var trackedContinuityItems: [ContinuityItem] {
        let worlds = Dictionary(uniqueKeysWithValues: worldNotes.map { ($0.id, $0) })
        return (continuityItems ?? []).map { item in
            guard let worldID = item.worldObjectID, let world = worlds[worldID] else { return item }
            return continuityDisplay(item, world: world)
        }
    }

    private func continuityDisplay(_ item: ContinuityItem, world: WorldNote) -> ContinuityItem {
        var result = item
        result.name = world.title
        var seen = Set([Continuity.normalized(world.title)])
        result.aliases = ((world.aliases ?? []) + [item.name] + item.aliases).filter {
            let key = Continuity.normalized($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
        return result
    }

    /// Offer awareness and possession independently, reusing unambiguous legacy identities.
    func continuityChoices(for category: ContinuityCategory, parentID: UUID? = nil) -> [ContinuityItem] {
        var choices = trackedContinuityItems.filter { $0.category == category }
        guard [.possession, .knowledge].contains(category), parentID == nil else { return choices }
        let objects = worldNotes.filter { $0.category == .object }
        func names(_ title: String, _ aliases: [String]) -> Set<String> {
            Set(([title] + aliases).map(Continuity.normalized).filter { !$0.isEmpty })
        }
        let objectLabels = objects.map { names($0.title, $0.aliases ?? []) }
        var worldsByLabel: [String: Set<Int>] = [:]
        for (index, labels) in objectLabels.enumerated() {
            for label in labels { worldsByLabel[label, default: []].insert(index) }
        }
        var choicesByLabel: [String: Set<Int>] = [:]
        var linkedWorldIDs = Set(choices.compactMap(\.worldObjectID))
        for (index, item) in choices.enumerated() where item.worldObjectID == nil && item.parentID == nil {
            for label in names(item.name, item.aliases) { choicesByLabel[label, default: []].insert(index) }
        }
        for (worldIndex, world) in objects.enumerated() {
            guard linkedWorldIDs.insert(world.id).inserted else { continue }
            let labels = objectLabels[worldIndex]
            let existing = labels.reduce(into: Set<Int>()) { $0.formUnion(choicesByLabel[$1] ?? []) }.filter { choices[$0].worldObjectID == nil }
            let matchingWorldObjects = labels.reduce(into: Set<Int>()) { $0.formUnion(worldsByLabel[$1] ?? []) }
            if existing.count == 1, matchingWorldObjects.count == 1, let index = existing.first {
                choices[index].worldObjectID = world.id
                choices[index] = continuityDisplay(choices[index], world: world)
            } else {
                choices.append(ContinuityItem(id: world.id, name: world.title, category: category,
                    aliases: world.aliases ?? [], details: [world.summary, world.details].filter { !$0.isEmpty }.joined(separator: "\n\n"), worldObjectID: world.id))
            }
        }
        return choices
    }

    /// Materialize an offered World item only when the user saves a character change.
    @discardableResult mutating func useContinuityChoice(_ id: UUID, category: ContinuityCategory, parentID: UUID? = nil) throws -> ContinuityItem {
        guard let choice = continuityChoices(for: category, parentID: parentID).first(where: { $0.id == id }) else {
            throw ProjectError.invalid("This item changed or was removed. Choose it again.")
        }
        if let index = continuityItems?.firstIndex(where: { $0.id == id }) {
            continuityItems?[index].worldObjectID = choice.worldObjectID
            continuityItems?[index].name = choice.name
            continuityItems?[index].aliases = choice.aliases
        } else {
            // Project records have globally unique IDs; the World UUID is only the picker key.
            var recorded = choice
            recorded.id = UUID()
            if continuityItems == nil { continuityItems = [] }
            continuityItems?.append(recorded)
            return recorded
        }
        return choice
    }
    @discardableResult mutating func createContinuityItem(name: String, category: ContinuityCategory, aliases: [String] = [], parentID: UUID? = nil) throws -> ContinuityItem {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Continuity.normalized(title).isEmpty else { throw ProjectError.invalid("Give the tracked item a name.") }
        if let match = Continuity.exactMatch(continuityChoices(for: category, parentID: parentID), name: title, category: category, parentID: parentID) { return try useContinuityChoice(match.id, category: category, parentID: parentID) }
        if let parentID, !(continuityItems ?? []).contains(where: { $0.id == parentID && $0.category == category }) { throw ProjectError.invalid("Choose a topic in the same category.") }
        let item = ContinuityItem(name: title, category: category, aliases: aliases, parentID: parentID)
        if continuityItems == nil { continuityItems = [] }; continuityItems?.append(item)
        return item
    }
    @discardableResult mutating func recordContinuity(itemID: UUID, characterID: UUID, action: ContinuityAction, chapterID: UUID?, range: NSRange = NSRange(location: 0, length: 0), expectedText: String? = nil, note: String = "", planned: Bool = false) throws -> ContinuityEvent {
        guard characters.contains(where: { $0.id == characterID }), let item = continuityItems?.first(where: { $0.id == itemID }), item.category == action.category else { throw ProjectError.invalid("Choose an existing character and an item matching this change.") }
        var event = ContinuityEvent(itemID: itemID, characterID: characterID, action: action, note: note, planned: planned)
        if let chapterID {
            guard let c = chapters.firstIndex(where: { $0.id == chapterID }), expectedText == nil || expectedText == chapters[c].plainText else { throw ProjectError.invalid("The passage changed. Select it again before recording this change.") }
            try Continuity.anchor(&event, range: range, text: chapters[c].plainText)
            let current = Continuity.states(in: self, characterID: characterID, chapterID: chapterID, offset: event.effectiveOffset, sourceStart: event.start).first { $0.id == itemID }
            if !planned, action == .learns, let current, [.learns, .confirmed].contains(current.latest.event.action) { throw ProjectError.invalid("This character already knows \(item.name). Record a reminder or a new detail instead.") }
            if chapters[c].continuityEvents == nil { chapters[c].continuityEvents = [] }; chapters[c].continuityEvents?.append(event)
        } else {
            guard !planned else { throw ProjectError.invalid("Choose a chapter for a planned change.") }
            let current = (initialContinuity ?? []).last { $0.itemID == itemID && $0.characterID == characterID && $0.action != .reminded }
            if action == .learns, let current, [.learns, .confirmed].contains(current.action) { throw ProjectError.invalid("This character already starts the story knowing \(item.name).") }
            if initialContinuity == nil { initialContinuity = [] }; initialContinuity?.append(event)
        }
        return event
    }
    mutating func mergeContinuityItem(_ sourceID: UUID, into targetID: UUID) throws {
        guard sourceID != targetID, let source = continuityItems?.first(where: { $0.id == sourceID }), let target = continuityItems?.first(where: { $0.id == targetID }), source.category == target.category else { throw ProjectError.invalid("Choose two items in the same category to merge.") }
        // A topic cannot be merged into one of its own descendants.
        var ancestor = target.parentID
        var visited = Set<UUID>()
        while let id = ancestor, visited.insert(id).inserted {
            if id == sourceID { throw ProjectError.invalid("Move the detail out of this topic before merging into it.") }
            ancestor = continuityItems?.first(where: { $0.id == id })?.parentID
        }
        guard let t = continuityItems?.firstIndex(where: { $0.id == targetID }) else { return }
        if target.worldObjectID == nil { continuityItems?[t].worldObjectID = source.worldObjectID }
        let names = target.aliases + [source.name] + source.aliases
        var keys = Set([Continuity.normalized(target.name)])
        continuityItems?[t].aliases = names.filter { keys.insert(Continuity.normalized($0)).inserted }
        if !source.details.isEmpty { continuityItems?[t].details += (target.details.isEmpty ? "" : "\n\n") + source.details }
        for i in (continuityItems ?? []).indices where continuityItems?[i].parentID == sourceID { continuityItems?[i].parentID = targetID }
        for c in chapters.indices {
            for e in (chapters[c].continuityEvents ?? []).indices where chapters[c].continuityEvents?[e].itemID == sourceID { chapters[c].continuityEvents?[e].itemID = targetID }
        }
        for e in (initialContinuity ?? []).indices where initialContinuity?[e].itemID == sourceID { initialContinuity?[e].itemID = targetID }
        continuityItems?.removeAll { $0.id == sourceID }
    }
}
