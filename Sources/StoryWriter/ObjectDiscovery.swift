import AppKit
import NaturalLanguage
import SwiftUI

enum NewObjectKind: String, CaseIterable, Identifiable {
    case character = "Character", location = "Location", item = "Item"
    var id: String { rawValue }
    var symbol: String { switch self { case .character: return "person.badge.plus"; case .location: return "map"; case .item: return "shippingbox" } }
}

struct ObjectNameSuggestion: Identifiable, Equatable {
    var name: String
    var range: NSRange
    var kind: NewObjectKind
    var id: String { ObjectDiscovery.key(name) }
}

enum ObjectDiscovery {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func known(_ name: String, objects: [TaggedProjectObject], ignored: [String]) -> Bool {
        let name = key(name)
        if ignored.contains(where: { key($0) == name }) { return true }
        return objects.contains { object in
            let title = key(object.title)
            if object.aliases.contains(where: { key($0) == name }) { return true }
            if title == name { return true }
            // A first name or surname can refer to an existing character.
            return object.reference.kind == .character && !name.contains(" ") && title.split { !$0.isLetter && !$0.isNumber }.contains { $0 == name }
        }
    }
    static func filter(_ candidates: [ObjectNameSuggestion], text: String, objects: [TaggedProjectObject], ignored: [String]) -> [ObjectNameSuggestion] {
        let source = text as NSString
        var seen = Set<String>()
        return candidates.filter {
            $0.name.count >= 2 && $0.name.count <= 100 && $0.name.contains(where: \.isLetter)
            && $0.range.location != NSNotFound && NSMaxRange($0.range) <= source.length
            && source.substring(with: $0.range) == $0.name
            && !known($0.name, objects: objects, ignored: ignored) && seen.insert(key($0.name)).inserted
        }.sorted { $0.range.location < $1.range.location }
    }
    static func names(in text: String, language: String, objects: [TaggedProjectObject], ignored: [String]) -> [ObjectNameSuggestion] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = text
        if language != "auto" { tagger.setLanguage(language == "de" ? .german : .english, range: text.startIndex..<text.endIndex) }
        var result: [ObjectNameSuggestion] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if Task.isCancelled { return false }
            if tag == .personalName || tag == .placeName {
                result.append(ObjectNameSuggestion(name: String(text[range]), range: NSRange(range, in: text), kind: tag == .placeName ? .location : .character))
            }
            return true
        }
        return filter(result, text: text, objects: objects, ignored: ignored)
    }
}

private struct CreateProjectObjectKey: EnvironmentKey { static let defaultValue: (String, NewObjectKind) -> ProjectTagReference? = { _, _ in nil } }
private struct IgnoredObjectNamesKey: EnvironmentKey { static let defaultValue: [String] = [] }
private struct IgnoreObjectNameKey: EnvironmentKey { static let defaultValue: (String) -> Void = { _ in } }
extension EnvironmentValues {
    var createProjectObject: (String, NewObjectKind) -> ProjectTagReference? { get { self[CreateProjectObjectKey.self] } set { self[CreateProjectObjectKey.self] = newValue } }
    var ignoredObjectNames: [String] { get { self[IgnoredObjectNamesKey.self] } set { self[IgnoredObjectNamesKey.self] = newValue } }
    var ignoreObjectName: (String) -> Void { get { self[IgnoreObjectNameKey.self] } set { self[IgnoreObjectNameKey.self] = newValue } }
}

extension ProjectStore {
    func createObject(named name: String, kind: NewObjectKind, projectID: UUID) -> ProjectTagReference? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let project = project(projectID) else { return nil }
        if let existing = project.tagObjects.first(where: { ObjectDiscovery.key($0.title) == ObjectDiscovery.key(name) }) { return existing.reference }
        let reference: ProjectTagReference
        switch kind {
        case .character:
            let character = Character(name: name); reference = ProjectTagReference(kind: .character, objectID: character.id)
            update(projectID) { $0.characters.append(character) }
        case .location, .item:
            let note = WorldNote(title: name, category: kind == .location ? .location : .object)
            reference = ProjectTagReference(kind: .world, objectID: note.id)
            update(projectID) { $0.worldNotes.append(note) }
        }
        return reference
    }
    func ignoreObjectName(_ name: String, projectID: UUID) {
        guard let project = project(projectID), !(project.ignoredObjectNames ?? []).contains(where: { ObjectDiscovery.key($0) == ObjectDiscovery.key(name) }) else { return }
        update(projectID) { $0.ignoredObjectNames = ($0.ignoredObjectNames ?? []) + [name] }
    }
}

@MainActor
final class ObjectNameSession: ObservableObject {
    weak var view: ManuscriptTextView?
    @Published private(set) var suggestions: [ObjectNameSuggestion] = []
    private(set) var snapshot = ""
    var objects: [TaggedProjectObject] = []
    var ignored: [String] = []
    var create: (String, NewObjectKind) -> ProjectTagReference? = { _, _ in nil }
    var ignoreName: (String) -> Void = { _ in }
    private var enabled = true
    private var task: Task<Void, Never>?
    private var worker: Task<[ObjectNameSuggestion], Never>?
    private var popover: NSPopover?
    var popoverVisible: Bool { popover?.isShown == true }
    init(view: ManuscriptTextView) { self.view = view }
    deinit { task?.cancel(); worker?.cancel() }
    func configure(objects: [TaggedProjectObject], ignored: [String], create: @escaping (String, NewObjectKind) -> ProjectTagReference?, ignore: @escaping (String) -> Void, enabled: Bool = ApplicationPreferences().discoversNames) {
        let changed = self.objects != objects || self.ignored != ignored || self.enabled != enabled
        self.enabled = enabled
        self.objects = objects; self.ignored = ignored; self.create = create; self.ignoreName = ignore
        if changed { textChanged() }
    }
    func textChanged() {
        task?.cancel(); worker?.cancel(); close()
        guard let view else { return }
        guard enabled else { suggestions = []; snapshot = view.string; redraw(); return }
        if snapshot != view.string { suggestions = []; snapshot = view.string; redraw() }
        else { suggestions = ObjectDiscovery.filter(suggestions, text: snapshot, objects: objects, ignored: ignored); redraw() }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }
    func scan() {
        task?.cancel(); worker?.cancel()
        guard enabled, let view else { return }
        let text = view.string, objects = objects, ignored = ignored, language = LocalGrammarService.shared.language
        snapshot = text
        let worker = Task.detached(priority: .utility) { ObjectDiscovery.names(in: text, language: language, objects: objects, ignored: ignored) }
        self.worker = worker
        task = Task { [weak self] in
            let found = await worker.value
            guard !Task.isCancelled, let self, self.view?.string == text, self.objects == objects, self.ignored == ignored else { return }
            self.suggestions = found.filter { candidate in
                guard let storage = self.view?.textStorage else { return false }
                return ProjectTagReference.from(storage.attribute(.link, at: candidate.range.location, effectiveRange: nil)) == nil
            }
            self.redraw()
        }
    }
    private func redraw() {
        if let grammar = view?.grammarSession { grammar.drawMarks() }
        else if let view, let manager = view.layoutManager {
            manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: view.string.utf16.count))
            manager.removeTemporaryAttribute(.underlineColor, forCharacterRange: NSRange(location: 0, length: view.string.utf16.count))
            drawMarks()
        }
    }
    /// Returns whether any name was marked.
    @discardableResult func drawMarks() -> Bool {
        guard let view, !suggestions.isEmpty, snapshot == view.string, let manager = view.layoutManager else { return false }
        var drawn = false
        for suggestion in suggestions where NSMaxRange(suggestion.range) <= view.string.utf16.count {
            if view.grammarSession?.corrections.contains(where: { NSIntersectionRange($0.range, suggestion.range).length > 0 }) == true { continue }
            manager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue, .underlineColor: NSColor.systemPurple], forCharacterRange: suggestion.range)
            drawn = true
        }
        if drawn { view.needsDisplay = true }
        return drawn
    }
    func candidate(at point: NSPoint) -> ObjectNameSuggestion? {
        guard let view, snapshot == view.string, let manager = view.layoutManager, let container = view.textContainer else { return nil }
        let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        return suggestions.first {
            NSLocationInRange(index, $0.range) && manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: $0.range, actualCharacterRange: nil), in: container).insetBy(dx: -2, dy: -2).contains(local)
        }
    }
    func close() { popover?.close(); popover = nil }
    func cancel() { task?.cancel(); worker?.cancel(); close() }
    func next() { if let first = suggestions.first { show(first) } }
    func show(_ suggestion: ObjectNameSuggestion) {
        guard let view, valid(suggestion) else { return }
        view.selectionActions?.close()
        close(); view.tagSession?.close(); view.setSelectedRange(suggestion.range); view.scrollRangeToVisible(suggestion.range)
        guard view.window?.isVisible == true, let manager = view.layoutManager, let container = view.textContainer else { return }
        var rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: suggestion.range, actualCharacterRange: nil), in: container)
        rect.origin.x += view.textContainerOrigin.x; rect.origin.y += view.textContainerOrigin.y
        let popup = NSPopover(); popup.behavior = .transient
        popup.contentViewController = NSHostingController(rootView: ObjectNameCard(session: self, suggestion: suggestion))
        popover = popup; popup.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
    private func valid(_ suggestion: ObjectNameSuggestion) -> Bool {
        guard let view, snapshot == view.string, NSMaxRange(suggestion.range) <= view.string.utf16.count else { return false }
        return (view.string as NSString).substring(with: suggestion.range) == suggestion.name
    }
    func createObject(_ suggestion: ObjectNameSuggestion, kind: NewObjectKind) {
        guard valid(suggestion) else { close(); return }
        close()
        guard create(suggestion.name, kind) != nil else { return }
        suggestions.removeAll { $0.id == suggestion.id }; redraw()
    }
    func ignore(_ suggestion: ObjectNameSuggestion) {
        guard valid(suggestion) else { close(); return }
        close(); ignored.append(suggestion.name); ignoreName(suggestion.name)
        suggestions.removeAll { $0.id == suggestion.id }; redraw()
    }
}

private struct ObjectNameCard: View {
    @ObservedObject var session: ObjectNameSession
    var suggestion: ObjectNameSuggestion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New name: \(suggestion.name)", systemImage: "person.badge.plus").font(.headline).foregroundStyle(.purple)
            Text("This name has no matching project object. Add a profile to keep its details consistent, or ignore it.").font(.callout)
            ForEach([suggestion.kind] + NewObjectKind.allCases.filter { $0 != suggestion.kind }) { kind in
                Button { session.createObject(suggestion, kind: kind) } label: { Label("Create \(kind.rawValue.lowercased()): \(suggestion.name)", systemImage: kind.symbol).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Button("Ignore this name in this project") { session.ignore(suggestion) }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text("Your prose stays unchanged. Recognition may miss invented names; type @ to tag one manually.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 340).tint(AppTheme.accent)
    }
}

struct ObjectNameBar: View {
    @ObservedObject var session: ObjectNameSession
    var body: some View {
        if !session.suggestions.isEmpty {
            HStack {
                Button { session.next() } label: { Label("\(session.suggestions.count) new name\(session.suggestions.count == 1 ? "" : "s")", systemImage: "person.badge.plus") }.buttonStyle(.plain).foregroundStyle(.purple)
                Spacer()
                Text("Add to project or ignore").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}
