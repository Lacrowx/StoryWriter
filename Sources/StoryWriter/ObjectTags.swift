import AppKit
import SwiftUI

struct ProjectTagReference: Hashable, Identifiable {
    enum Kind: String { case character, world }
    var kind: Kind
    var objectID: UUID
    var id: String { "\(kind.rawValue)/\(objectID.uuidString)" }
    var url: URL { URL(string: "storywriter://tag/\(id)")! }
    init(kind: Kind, objectID: UUID) { self.kind = kind; self.objectID = objectID }
    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == "storywriter", url.host == "tag", url.query == nil, url.fragment == nil,
              parts.count == 2, let kind = Kind(rawValue: parts[0]), let id = UUID(uuidString: parts[1]) else { return nil }
        self.kind = kind; objectID = id
    }
    static func from(_ value: Any?) -> ProjectTagReference? {
        if let url = value as? URL { return ProjectTagReference(url: url) }
        if let value = value as? String, let url = URL(string: value) { return ProjectTagReference(url: url) }
        return nil
    }
}

struct NameCompletion: Equatable {
    var prefix: NSRange
    var name: String
    var object: TaggedProjectObject
    var suffix: String { String(name.utf16.dropFirst(prefix.length)) ?? "" }
}

struct TaggedObjectDetail: Equatable, Identifiable {
    var title: String
    var text: String
    var id: String { title }
}

struct TaggedProjectObject: Identifiable, Equatable {
    var reference: ProjectTagReference
    var title: String
    var group: String
    var symbol: String
    var summary: String
    var aliases: [String] = []
    var kindLabel: String = ""
    var details: [TaggedObjectDetail] = []
    var id: String { reference.id }
}

extension StoryProject {
    var tagObjects: [TaggedProjectObject] {
        characters.map { character in
            TaggedProjectObject(reference: ProjectTagReference(kind: .character, objectID: character.id), title: character.name, group: "Characters", symbol: "person", summary: character.role, aliases: (character.aliases ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, kindLabel: "Character", details: [
                TaggedObjectDetail(title: "Pronouns", text: character.pronouns),
                TaggedObjectDetail(title: "Appearance", text: character.appearance),
                TaggedObjectDetail(title: "Personality & voice", text: character.personality),
                TaggedObjectDetail(title: "Motivation", text: character.motivation),
                TaggedObjectDetail(title: "Conflict", text: character.conflict),
                TaggedObjectDetail(title: "Character arc", text: character.arc),
                TaggedObjectDetail(title: "Relationships", text: character.relationships),
                TaggedObjectDetail(title: "Notes", text: character.notes)
            ].filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        + worldNotes.map { note in
            let group: String
            switch note.category {
            case .location: group = "Locations"
            case .object: group = "Items"
            case .culture: group = "Cultures"
            case .history: group = "History"
            case .rules: group = "Rules & systems"
            case .other: group = "Other world entries"
            }
            return TaggedProjectObject(reference: ProjectTagReference(kind: .world, objectID: note.id), title: note.title, group: group, symbol: note.category.symbol, summary: note.summary, aliases: (note.aliases ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, kindLabel: note.category == .object ? "Item" : note.category.rawValue, details: [
                TaggedObjectDetail(title: "Details", text: note.details),
                TaggedObjectDetail(title: "Connections", text: note.connections)
            ].filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }
}

enum ObjectTags {
    static let groupOrder = ["Characters", "Locations", "Items", "Cultures", "History", "Rules & systems", "Other world entries"]
    static func matches(_ objects: [TaggedProjectObject], query: String) -> [TaggedProjectObject] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return objects.filter { query.isEmpty || ([$0.title, $0.summary] + $0.aliases).contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
            .sorted {
                let a = groupOrder.firstIndex(of: $0.group) ?? 99, b = groupOrder.firstIndex(of: $1.group) ?? 99
                return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a < b
            }
    }
    static func queryRange(in text: String, selection: NSRange, objects: [TaggedProjectObject] = []) -> NSRange? {
        let text = text as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let scan = NSRange(location: max(0, selection.location - 100), length: min(100, selection.location))
        let at = text.range(of: "@", options: .backwards, range: scan)
        guard at.location != NSNotFound else { return nil }
        let range = NSRange(location: at.location, length: selection.location - at.location)
        if at.location > 0 {
            let preceding = text.substring(with: text.rangeOfComposedCharacterSequence(at: at.location - 1))
            let separated = preceding.allSatisfy({ $0.isWhitespace }) || "([{\"'“‘".contains(preceding)
            // A bare @ immediately after a known name is a request to tag it.
            guard separated || (range.length == 1 && objects.contains {
                existingMention(in: text as String, object: $0, beside: range)?.upperBound == at.location
            }) else { return nil }
        }
        let query = text.substring(with: NSRange(location: at.location + 1, length: range.length - 1))
        guard !query.contains(where: { $0.isNewline || ",.;:!?@)]}".contains($0) }) else { return nil }
        return range
    }
    /// Characters that finish a word, so a name typed just before them is complete.
    static func isNameBoundary(_ text: String) -> Bool {
        guard text.count == 1, let character = text.first else { return false }
        return character.isWhitespace || ".,;:!?)]}\"'”’»…—–".contains(character)
    }

    /// The known name, spelled exactly as in its profile, that ends just before `boundary`.
    /// The longest name wins; a name shared by several objects is left for the writer to tag.
    static func autoTagMatch(in text: NSAttributedString, boundary: Int, objects: [TaggedProjectObject]) -> (range: NSRange, object: TaggedProjectObject)? {
        let source = text.string as NSString
        guard boundary > 0, boundary < source.length, isNameBoundary(source.substring(with: NSRange(location: boundary, length: 1))) else { return nil }
        var best: [(range: NSRange, object: TaggedProjectObject)] = []
        for object in objects {
            for name in nameChoices(object) {
                let length = name.utf16.count
                guard name.count >= 2, length <= boundary, !best.contains(where: { $0.range.length > length }) else { continue }
                let range = NSRange(location: boundary - length, length: length)
                guard source.substring(with: range) == name else { continue }
                if range.location > 0 {
                    let before = source.substring(with: source.rangeOfComposedCharacterSequence(at: range.location - 1))
                    guard !before.contains(where: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "@" }) else { continue }
                }
                if best.first.map({ $0.range.length < length }) == true { best = [] }
                if !best.contains(where: { $0.object.reference == object.reference }) { best.append((range, object)) }
            }
        }
        guard best.count == 1, let match = best.first else { return nil }
        // Leave web links and other tags alone, and skip names that are already tagged.
        var conflicting = false, alreadyTagged = true
        text.enumerateAttribute(.link, in: match.range) { value, _, stop in
            let reference = ProjectTagReference.from(value)
            if value != nil && reference != match.object.reference { conflicting = true; stop.pointee = true }
            if reference == nil { alreadyTagged = false }
        }
        return conflicting || alreadyTagged ? nil : match
    }

    /// The rest of a known name whose start the writer is typing at the end of a line.
    /// The longest typed prefix decides; prefixes shared by several entries complete nothing.
    static func completion(in text: String, caret: Int, objects: [TaggedProjectObject]) -> NameCompletion? {
        let source = text as NSString
        guard caret > 1, caret <= source.length else { return nil }
        if caret < source.length, !CharacterSet.newlines.contains(Unicode.Scalar(source.character(at: caret)) ?? " ") { return nil }
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < source.length, let scalar = Unicode.Scalar(source.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        guard isWord(caret - 1) else { return nil }
        let names = objects.flatMap { object in nameChoices(object).map { (name: $0, object: object) } }
        var index = caret - 1
        while index >= max(0, caret - 80) {
            let scalar = Unicode.Scalar(source.character(at: index)) ?? " "
            if CharacterSet.newlines.contains(scalar) { break }
            if isWord(index) && !isWord(index - 1) && (index == 0 || source.character(at: index - 1) != 0x40) { // Not after @.
                let prefix = NSRange(location: index, length: caret - index)
                let typed = source.substring(with: prefix)
                let matches = names.filter { $0.name.utf16.count > prefix.length && $0.name.hasPrefix(typed) }
                if !matches.isEmpty {
                    // A finished name, such as a first name, needs no further suggestion.
                    guard prefix.length >= 2, Set(matches.map(\.object.reference)).count == 1, !names.contains(where: { $0.name == typed }),
                          let shortest = matches.min(by: { $0.name.utf16.count < $1.name.utf16.count }) else { return nil }
                    return NameCompletion(prefix: prefix, name: shortest.name, object: shortest.object)
                }
            }
            index -= 1
        }
        return nil
    }

    static func nameChoices(_ object: TaggedProjectObject) -> [String] {
        var names = [object.title] + object.aliases
        if object.reference.kind == .character, let first = object.title.split(whereSeparator: \.isWhitespace).first, first.count >= 2 {
            names.append(String(first))
        }
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    static func existingMention(in text: String, object: TaggedProjectObject, beside trigger: NSRange) -> NSRange? {
        let source = text as NSString
        guard trigger.location >= 0, NSMaxRange(trigger) <= source.length else { return nil }
        let names = nameChoices(object).sorted { $0.utf16.count > $1.utf16.count }
        // Only inspect the words beside the trigger, even in a long chapter.
        let reach = (names.map { $0.utf16.count }.max() ?? 0) * 2 + 64
        let beforeStart = max(0, trigger.location - reach)
        let before = NSRange(location: beforeStart, length: trigger.location - beforeStart)
        let after = NSRange(location: NSMaxRange(trigger), length: min(reach, source.length - NSMaxRange(trigger)))
        func horizontalSpace(_ text: String) -> Bool { text.allSatisfy { $0.isWhitespace && !$0.isNewline } }
        for name in names {
            let words = name.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + words.joined(separator: "[ \\t\\u00a0]+") + "(?![\\p{L}\\p{M}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            // Prefer the longest complete label, preserving its existing spelling.
            if let match = regex.matches(in: text, options: [.withTransparentBounds], range: before).last,
               horizontalSpace(source.substring(with: NSRange(location: NSMaxRange(match.range), length: trigger.location - NSMaxRange(match.range)))) {
                return match.range
            }
            if let match = regex.firstMatch(in: text, options: [.withTransparentBounds], range: after),
               horizontalSpace(source.substring(with: NSRange(location: after.location, length: match.range.location - after.location))) {
                return match.range
            }
            // @ was inserted into existing prose and the caret is inside the name.
            if trigger.length > 0 {
                let suffixStart = trigger.location + 1
                let suffix = NSRange(location: suffixStart, length: min(reach, source.length - suffixStart))
                if let match = regex.firstMatch(in: text, options: [.anchored, .withTransparentBounds], range: suffix),
                   (NSMaxRange(match.range) >= NSMaxRange(trigger) ||
                    horizontalSpace(source.substring(with: NSRange(location: NSMaxRange(match.range), length: NSMaxRange(trigger) - NSMaxRange(match.range))))) {
                    return match.range
                }
            }
        }
        return nil
    }
    static func publicationText(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        var ranges: [NSRange] = []
        source.enumerateAttribute(.link, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            if ProjectTagReference.from(value) != nil { ranges.append(range) }
        }
        for range in ranges { result.removeAttribute(.link, range: range) }
        return result
    }
}

/// Draws tags as soft highlights tinted by kind, and web links with a thin
/// underline, in place of AppKit's blue hyperlink styling.
final class ManuscriptLayoutManager: NSLayoutManager {
    var showsTags = true
    struct TagHighlight: Equatable { var rect: NSRect; var kind: ProjectTagReference.Kind }

    static func color(for kind: ProjectTagReference.Kind) -> NSColor {
        kind == .character ? .systemIndigo : .systemTeal
    }

    /// One rectangle per line, fitted to the letters rather than the line spacing.
    func tagHighlights(in characters: NSRange) -> [TagHighlight] {
        var result: [TagHighlight] = []
        guard showsTags else { return result }
        enumerateLinks(in: characters) { range, value in
            guard let tag = ProjectTagReference.from(value) else { return }
            for rect in letterRects(for: range) { result.append(TagHighlight(rect: rect, kind: tag.kind)) }
        }
        return result
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for highlight in tagHighlights(in: characters) {
            let rect = highlight.rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 0)
            Self.color(for: highlight.kind).withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        enumerateLinks(in: characters) { range, value in
            guard ProjectTagReference.from(value) == nil else { return }
            NSColor.linkColor.withAlphaComponent(0.7).setFill()
            for rect in letterRects(for: range) {
                NSRect(x: rect.minX + origin.x, y: rect.maxY + origin.y - 1, width: rect.width, height: 1).fill()
            }
        }
    }

    private func enumerateLinks(in characters: NSRange, _ body: (NSRange, Any) -> Void) {
        guard let storage = textStorage, NSMaxRange(characters) <= storage.length else { return }
        storage.enumerateAttribute(.link, in: characters) { value, range, _ in if let value { body(range, value) } }
    }

    private func letterRects(for characters: NSRange) -> [NSRect] {
        guard let storage = textStorage, let container = textContainers.first else { return [] }
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rects: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, lineGlyphs, _ in
            let part = NSIntersectionRange(glyphs, lineGlyphs)
            guard part.length > 0 else { return }
            let bounds = self.boundingRect(forGlyphRange: part, in: container)
            let font = storage.attribute(.font, at: self.characterIndexForGlyph(at: part.location), effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 18)
            let baseline = line.minY + self.location(forGlyphAt: part.location).y
            rects.append(NSRect(x: bounds.minX, y: baseline - font.ascender - 1, width: bounds.width, height: font.ascender - font.descender + 2))
        }
        return rects
    }
}

private struct TagObjectsKey: EnvironmentKey { static let defaultValue: [TaggedProjectObject] = [] }
private struct OpenObjectTagKey: EnvironmentKey { static let defaultValue: (ProjectTagReference) -> Void = { _ in } }
extension EnvironmentValues {
    var tagObjects: [TaggedProjectObject] { get { self[TagObjectsKey.self] } set { self[TagObjectsKey.self] = newValue } }
    var openObjectTag: (ProjectTagReference) -> Void { get { self[OpenObjectTagKey.self] } set { self[OpenObjectTagKey.self] = newValue } }
}

@MainActor
final class ObjectTagSession: NSObject, ObservableObject, NSPopoverDelegate {
    weak var view: ManuscriptTextView?
    var objects: [TaggedProjectObject] = [] {
        didSet {
            guard objects != oldValue, let reference = inspectedReference,
                  let controller = detailsPopup?.contentViewController as? NSHostingController<ObjectTagDetailsBubble> else { return }
            controller.rootView = detailsBubble(for: reference)
        }
    }
    var open: (ProjectTagReference) -> Void = { _ in }
    var create: (String, NewObjectKind) -> ProjectTagReference? = { _, _ in nil }
    var ignoreName: (String) -> Void = { _ in }
    @Published var suggestions: [TaggedProjectObject] = []
    @Published var highlighted = 0
    @Published var selectedLabel: String?
    @Published var newName: String?
    private var popup: NSPopover?
    private var queryRange: NSRange?
    private var chosenReference: ProjectTagReference?
    private var detailsPopup: NSPopover?
    private var scrollObserver: NSObjectProtocol?
    private(set) var inspectedReference: ProjectTagReference?
    private(set) var detailsAnchor: NSRect?
    var detailsVisible: Bool { detailsPopup?.isShown == true }
    private(set) var inserting = false
    var autoTagsNames = true
    var completionsEnabled = true
    private(set) var completion: NameCompletion? {
        didSet { if completion != oldValue { view?.completionChanged(from: oldValue) } }
    }
    var visible: Bool { popup?.isShown == true }
    init(view: ManuscriptTextView) { self.view = view; super.init() }

    func close() { popup?.close(); popup = nil; queryRange = nil; selectedLabel = nil; chosenReference = nil; closeDetails() }

    /// Offers the rest of a known name as grey text that Tab accepts.
    func refreshCompletion() {
        guard completionsEnabled, !visible, !inserting, let view, !view.hasMarkedText(), view.selectedRange().length == 0 else { completion = nil; return }
        completion = ObjectTags.completion(in: view.string, caret: view.selectedRange().location, objects: objects)
    }
    func dismissCompletion() { completion = nil }
    @discardableResult func acceptCompletion() -> Bool {
        guard let completion, let view, let storage = view.textStorage, NSMaxRange(completion.prefix) <= storage.length,
              view.selectedRange() == NSRange(location: NSMaxRange(completion.prefix), length: 0),
              objects.contains(where: { $0.reference == completion.object.reference }) else { self.completion = nil; return false }
        let original = storage.attributedSubstring(from: completion.prefix)
        let tagged = NSMutableAttributedString(attributedString: GrammarText.replacement(original, with: completion.name))
        tagged.addAttribute(.link, value: completion.object.reference.url, range: NSRange(location: 0, length: tagged.length))
        inserting = true; self.completion = nil
        view.breakUndoCoalescing(); view.undoManager?.beginUndoGrouping()
        let changed = view.replaceAttributedText(tagged, range: completion.prefix)
        view.undoManager?.setActionName("Complete \(completion.name)"); view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        inserting = false
        return changed
    }
    func closeDetails() {
        let popup = detailsPopup
        detailsPopup = nil; inspectedReference = nil; detailsAnchor = nil
        popup?.close()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
    }
    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === detailsPopup { closeDetails() }
        else if let closed = notification.object as? NSPopover, closed === popup { popup = nil; queryRange = nil; selectedLabel = nil; chosenReference = nil }
    }
    private func detailsBubble(for reference: ProjectTagReference) -> ObjectTagDetailsBubble {
        ObjectTagDetailsBubble(object: objects.first { $0.reference == reference }, close: { [weak self] in self?.closeDetails() }, open: { [weak self] in
            self?.closeDetails(); self?.open(reference)
        })
    }
    @discardableResult func showDetails(at point: NSPoint) -> Bool {
        guard let index = taggedCharacter(at: point) else { return false }
        return showDetails(atCharacter: index)
    }
    @discardableResult func showDetails(atCharacter index: Int) -> Bool {
        guard let view, view.window?.isVisible == true, let storage = view.textStorage,
              index >= 0, index < storage.length, let manager = view.layoutManager, let container = view.textContainer else { return false }
        var range = NSRange()
        guard let reference = ProjectTagReference.from(storage.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))) else { return false }
        close()
        manager.ensureLayout(for: container)
        // Anchor to the clicked line when a tagged phrase wraps across lines.
        let glyph = manager.glyphIndexForCharacter(at: index)
        var line = NSRange()
        _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let glyphs = NSIntersectionRange(line, manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let rect = bounds.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let details = NSPopover(); details.behavior = .transient; details.animates = false; details.delegate = self
        details.contentViewController = NSHostingController(rootView: detailsBubble(for: reference))
        detailsPopup = details; inspectedReference = reference; detailsAnchor = rect
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closeDetails() }
            }
        }
        details.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        return true
    }
    func refreshSuggestions() {
        guard !inserting, let view, let range = ObjectTags.queryRange(in: view.string, selection: view.selectedRange(), objects: objects) else { close(); return }
        queryRange = range
        let query = (view.string as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 1))
        suggestions = ObjectTags.matches(objects, query: query); highlighted = 0; selectedLabel = nil; chosenReference = nil
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = suggestions.isEmpty && name.count >= 2 && name.count <= 100 && name.contains(where: \.isLetter) ? name : nil
        present()
    }
    func browse() {
        guard let view else { return }
        queryRange = nil; newName = nil; suggestions = ObjectTags.matches(objects, query: ""); highlighted = 0; selectedLabel = nil; chosenReference = nil
        view.window?.makeFirstResponder(view); present()
    }
    private func present() {
        guard let view, view.window?.isVisible == true else { return }
        if popup?.isShown == true { return }
        let popup = NSPopover(); popup.behavior = .applicationDefined; popup.animates = false
        popup.delegate = self
        popup.contentViewController = NSHostingController(rootView: ObjectTagSuggestions(session: self))
        self.popup = popup
        var rect = NSRect(origin: view.textContainerOrigin, size: NSSize(width: 1, height: view.font?.pointSize ?? 18))
        if let manager = view.layoutManager, let container = view.textContainer, !view.string.isEmpty {
            manager.ensureLayout(for: container)
            let caret = min(view.selectedRange().location, view.string.utf16.count)
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: min(caret, view.string.utf16.count - 1), length: 1), actualCharacterRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            rect = NSRect(x: view.textContainerOrigin.x + (caret == view.string.utf16.count ? bounds.maxX : bounds.minX), y: view.textContainerOrigin.y + bounds.minY, width: 1, height: max(bounds.height, 18))
        }
        popup.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(view)
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard visible else { return false }
        switch event.keyCode {
        case 53: close(); return true
        case 125: if !suggestions.isEmpty { highlighted = min(highlighted + 1, suggestions.count - 1); selectedLabel = nil; chosenReference = suggestions[highlighted].reference }; return true
        case 126: highlighted = max(0, highlighted - 1); selectedLabel = nil
            if suggestions.indices.contains(highlighted) { chosenReference = suggestions[highlighted].reference }; return true
        case 123, 124:
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            guard suggestions.indices.contains(highlighted) else { return false }
            let object = suggestions[highlighted], names = ObjectTags.nameChoices(object)
            let current = names.firstIndex { $0.caseInsensitiveCompare(insertionLabel(for: object)) == .orderedSame } ?? 0
            let next = (current + (event.keyCode == 124 ? 1 : names.count - 1)) % max(1, names.count)
            if names.indices.contains(next) { selectedLabel = names[next] }
            return true
        case 49:
            guard event.characters == " ", event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  view?.hasMarkedText() != true, let choice = spaceCompletion() else { return false }
            return insert(choice.object, label: choice.label, trailingSpace: true)
        case 36, 48, 76:
            guard suggestions.indices.contains(highlighted) else { close(); return false }
            insert(suggestions[highlighted], label: selectedLabel); return true
        default: return false
        }
    }
    private func spaceCompletion() -> (object: TaggedProjectObject, label: String?)? {
        guard let view, let range = queryRange,
              ObjectTags.queryRange(in: view.string, selection: view.selectedRange(), objects: objects) == range else { return nil }
        if suggestions.indices.contains(highlighted) {
            let object = suggestions[highlighted]
            if selectedLabel != nil || chosenReference == object.reference { return (object, selectedLabel) }
        }
        let query = (view.string as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 1)).trimmingCharacters(in: .whitespaces)
        // Ordinary spaces must still work inside multiword names, and shared aliases need an explicit choice.
        let exact = suggestions.filter { object in
            ObjectTags.nameChoices(object).contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }
        return exact.count == 1 ? (exact[0], nil) : nil
    }

    func insertionLabel(for object: TaggedProjectObject) -> String {
        if suggestions.indices.contains(highlighted), suggestions[highlighted].reference == object.reference, let selectedLabel { return selectedLabel }
        guard let view else { return object.title }
        let selected = queryRange ?? view.selectedRange()
        if queryRange == nil, selected.location >= 0, selected.length > 0, NSMaxRange(selected) <= view.string.utf16.count {
            return (view.string as NSString).substring(with: selected)
        }
        if let mention = ObjectTags.existingMention(in: view.string, object: object, beside: selected) {
            return (view.string as NSString).substring(with: mention)
        }
        return object.title
    }

    @discardableResult func insert(_ object: TaggedProjectObject, label: String? = nil, trailingSpace: Bool = false) -> Bool {
        guard let view, objects.contains(where: { $0.reference == object.reference }),
              label.map({ ObjectTags.nameChoices(object).contains($0) }) ?? true else { close(); return false }
        var selected = queryRange ?? view.selectedRange()
        guard selected.location >= 0, selected.location != NSNotFound, NSMaxRange(selected) <= view.string.utf16.count else { close(); return false }
        let tagged: NSMutableAttributedString
        if (queryRange != nil || selected.length == 0), let storage = view.textStorage,
           let mention = ObjectTags.existingMention(in: view.string, object: object, beside: selected) {
            // The combined range contains only the trigger, its query, and the known name.
            // Keep the name's exact original spelling and attributes unless another label was chosen.
            let original = storage.attributedSubstring(from: mention)
            tagged = NSMutableAttributedString(attributedString: label.map { GrammarText.replacement(original, with: $0) } ?? original)
            selected = NSUnionRange(selected, mention)
        } else if queryRange == nil, selected.length > 0, let storage = view.textStorage {
            let original = storage.attributedSubstring(from: selected)
            tagged = NSMutableAttributedString(attributedString: label.map { GrammarText.replacement(original, with: $0) } ?? original)
        } else {
            // A partial query completes to the full name; an exact alias retains its own spelling.
            var attributes = view.typingAttributes; attributes.removeValue(forKey: .link)
            tagged = NSMutableAttributedString(string: label ?? object.title, attributes: attributes)
        }
        tagged.addAttribute(.link, value: object.reference.url, range: NSRange(location: 0, length: tagged.length))
        var typing = view.typingAttributes; typing.removeValue(forKey: .link)
        if trailingSpace { tagged.append(NSAttributedString(string: " ", attributes: typing)) }
        inserting = true; close()
        view.window?.makeFirstResponder(view); view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        let changed = view.replaceAttributedText(tagged, range: selected)
        view.undoManager?.endUndoGrouping()
        view.typingAttributes = typing; view.undoManager?.setActionName("Tag project object")
        inserting = false
        return changed
    }
    /// Tags a known name the writer just finished typing, as its own undo step.
    func autoTagName(endingAt boundary: Int) {
        guard autoTagsNames, !inserting, !visible, let storage = view?.textStorage,
              let match = ObjectTags.autoTagMatch(in: storage, boundary: boundary, objects: objects) else { return }
        let name = (storage.string as NSString).substring(with: match.range)
        // Apply after the keystroke's own editing and undo step have finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, let storage = view.textStorage, NSMaxRange(match.range) <= storage.length,
                  (storage.string as NSString).substring(with: match.range) == name,
                  self.objects.contains(where: { $0.reference == match.object.reference }) else { return }
            let selection = view.selectedRanges
            // An explicit group keeps the tag a separate undo step from the typing on either side.
            view.breakUndoCoalescing(); view.undoManager?.beginUndoGrouping()
            defer { view.undoManager?.setActionName("Tag \(match.object.title)"); view.undoManager?.endUndoGrouping() }
            guard view.shouldChangeText(in: match.range, replacementString: nil) else { return }
            storage.addAttribute(.link, value: match.object.reference.url, range: match.range)
            view.didChangeText()
            view.selectedRanges = selection
            view.breakUndoCoalescing()
        }
    }

    func createNew(_ kind: NewObjectKind) {
        guard let name = newName, let range = queryRange, let view,
              NSMaxRange(range) <= view.string.utf16.count,
              (view.string as NSString).substring(with: range).dropFirst().trimmingCharacters(in: .whitespacesAndNewlines) == name else { close(); return }
        close()
        guard let reference = create(name, kind) else { return }
        let object = TaggedProjectObject(reference: reference, title: name, group: kind == .character ? "Characters" : kind == .location ? "Locations" : "Items", symbol: kind.symbol, summary: "")
        if !objects.contains(where: { $0.reference == reference }) { objects.append(object) }
        queryRange = range; insert(object); newName = nil
    }
    func ignoreNewName() {
        guard let name = newName, let range = queryRange, let view, NSMaxRange(range) <= view.string.utf16.count else { close(); return }
        inserting = true; close()
        var attributes = view.typingAttributes; attributes.removeValue(forKey: .link)
        view.insertText(NSAttributedString(string: name, attributes: attributes), replacementRange: range)
        inserting = false; newName = nil; ignoreName(name)
    }
    func reference(at point: NSPoint) -> ProjectTagReference? {
        guard let index = taggedCharacter(at: point) else { return nil }
        return ProjectTagReference.from(view?.textStorage?.attribute(.link, at: index, effectiveRange: nil))
    }
    private func taggedCharacter(at point: NSPoint) -> Int? {
        guard let view, let manager = view.layoutManager, let container = view.textContainer else { return nil }
        let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < (view.textStorage?.length ?? 0), ProjectTagReference.from(view.textStorage?.attribute(.link, at: index, effectiveRange: nil)) != nil else { return nil }
        return index
    }
    func removeSelectedTag() {
        guard let view, let storage = view.textStorage, storage.length > 0 else { return }
        var range = view.selectedRange()
        if range.length == 0 {
            var index = min(range.location, storage.length - 1)
            if ProjectTagReference.from(storage.attribute(.link, at: index, effectiveRange: nil)) == nil, index > 0 { index -= 1 }
            guard let reference = ProjectTagReference.from(storage.attribute(.link, at: index, effectiveRange: nil)) else { return }
            var start = index, end = index + 1
            while start > 0, ProjectTagReference.from(storage.attribute(.link, at: start - 1, effectiveRange: nil)) == reference { start -= 1 }
            while end < storage.length, ProjectTagReference.from(storage.attribute(.link, at: end, effectiveRange: nil)) == reference { end += 1 }
            range = NSRange(location: start, length: end - start)
        }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var links: [NSRange] = []
        replacement.enumerateAttribute(.link, in: NSRange(location: 0, length: replacement.length)) { value, part, _ in
            if ProjectTagReference.from(value) != nil { links.append(part) }
        }
        guard !links.isEmpty else { return }
        guard view.shouldChangeText(in: range, replacementString: nil) else { return }
        close(); view.window?.makeFirstResponder(view)
        for part in links { storage.removeAttribute(.link, range: NSRange(location: range.location + part.location, length: part.length)) }
        view.didChangeText()
        view.undoManager?.setActionName("Remove object tag")
        var typing = view.typingAttributes; typing.removeValue(forKey: .link); view.typingAttributes = typing
    }
}

private struct ObjectTagSuggestions: View {
    @ObservedObject var session: ObjectTagSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Tag a project object", systemImage: "tag").font(.headline); Spacer(); Button { session.close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close suggestions · Escape") }
            Text(session.newName == nil ? "↑ ↓ object · ← → name · Space / Return to tag" : "Choose how to add this name · Esc to close").font(.caption).foregroundStyle(.secondary)
            if let name = session.newName {
                Text("No matching object for “\(name)”.").foregroundStyle(.secondary)
                ForEach(NewObjectKind.allCases) { kind in
                    Button { session.createNew(kind) } label: { Label("Create \(kind.rawValue.lowercased()): \(name)", systemImage: kind.symbol).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Button("Ignore this name in this project") { session.ignoreNewName() }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if session.suggestions.isEmpty { Text("No matching objects. Add characters or world entries to this project.").foregroundStyle(.secondary).padding(.vertical, 16) }
            else { ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(session.suggestions.enumerated()), id: \.element.id) { index, object in
                            VStack(alignment: .leading, spacing: 8) {
                                Button { session.insert(object, label: index == session.highlighted ? session.selectedLabel : nil) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: object.symbol).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 3) { Text(object.title).fontWeight(.medium); Text(object.group + (object.summary.isEmpty ? "" : " · " + object.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                let names = ObjectTags.nameChoices(object)
                                if names.count > 1 {
                                    Text("Insert as").font(.caption2).foregroundStyle(.secondary)
                                    TagNameChoiceLayout {
                                        ForEach(names, id: \.self) { name in
                                            let active = name.caseInsensitiveCompare(session.insertionLabel(for: object)) == .orderedSame
                                            Button { session.insert(object, label: name) } label: {
                                                HStack(spacing: 4) {
                                                    if active { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
                                                    Text(name).fixedSize(horizontal: false, vertical: true)
                                                }.font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                                                    .background(active ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: Capsule())
                                                    .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12), lineWidth: 1))
                                            }.buttonStyle(.plain).accessibilityLabel("Tag as \(name)").help("Use \(name) in the text, linked to \(object.title)")
                                        }
                                    }
                                }
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(index == session.highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8)).id(object.id)
                        }
                    }
                }.frame(maxHeight: 280)
                    .onChange(of: session.highlighted) { _, value in if session.suggestions.indices.contains(value) { proxy.scrollTo(session.suggestions[value].id) } }
            } }
        }.padding(16).frame(width: 340).tint(AppTheme.accent)
    }
}

/// Natural-width name buttons wrap inside the bubble, including long aliases.
private struct TagNameChoiceLayout: Layout {
    private func positions(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 6; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); usedWidth = max(usedWidth, x + size.width)
            x += size.width + 6; rowHeight = max(rowHeight, size.height)
        }
        return (points, CGSize(width: usedWidth, height: y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(subviews, width: proposal.width ?? 304).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

private struct ObjectTagDetailsBubble: View {
    var object: TaggedProjectObject?
    var close: () -> Void
    var open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: object?.symbol ?? "tag.slash").font(.title2).foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(object?.title ?? "Missing object").font(.title3).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                    Text(object.map { $0.kindLabel.isEmpty ? $0.group : $0.kindLabel } ?? "Disconnected tag").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close details · Escape").keyboardShortcut(.cancelAction)
            }
            if let object {
                ViewThatFits(in: .vertical) {
                    detailContent(object).fixedSize(horizontal: false, vertical: true)
                    ScrollView { detailContent(object) }
                }.frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
                Divider()
                Button(action: open) { Label("Open full profile", systemImage: "sidebar.right").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).foregroundStyle(AppTheme.accent)
            } else {
                Text("This object is no longer in the project.")
                Text("Your words are preserved. Use Remove tag from selection to unlink them.").font(.caption).foregroundStyle(.secondary)
            }
            Text("⌘-click any tag to see its details.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(width: 340).tint(AppTheme.accent)
    }
    private func detailContent(_ object: TaggedProjectObject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !object.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(object.summary).fixedSize(horizontal: false, vertical: true) }
            if !object.aliases.isEmpty { detail("Also known as", text: object.aliases.joined(separator: ", ")) }
            ForEach(object.details) { field in detail(field.title, text: field.text) }
            if object.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && object.details.isEmpty {
                Text("No details yet. Open the profile to add them.").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private func detail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProjectObjectDetailsSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    var reference: ProjectTagReference
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label("Tagged object", systemImage: "tag").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            if let project = store.project(projectID) {
                if reference.kind == .character, let character = project.characters.first(where: { $0.id == reference.objectID }) {
                    CharacterDetails(projectID: projectID, character: store.itemBinding(projectID, \.characters, id: character.id, fallback: character)).environment(\.grammarNamespace, character.id.uuidString)
                } else if reference.kind == .world, let note = project.worldNotes.first(where: { $0.id == reference.objectID }) {
                    WorldDetails(projectID: projectID, note: store.itemBinding(projectID, \.worldNotes, id: note.id, fallback: note)).environment(\.grammarNamespace, note.id.uuidString)
                } else {
                    VStack(spacing: 12) { Image(systemName: "tag.slash").font(.largeTitle); Text("This object is no longer in the project."); Text("Your writing is preserved. Use Remove tag to unlink it.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(width: 740, height: 700)
    }
}
