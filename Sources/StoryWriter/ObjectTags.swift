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
    static func queryRange(in text: String, selection: NSRange) -> NSRange? {
        let text = text as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let scan = NSRange(location: max(0, selection.location - 100), length: min(100, selection.location))
        let at = text.range(of: "@", options: .backwards, range: scan)
        guard at.location != NSNotFound else { return nil }
        if at.location > 0 {
            let preceding = text.substring(with: text.rangeOfComposedCharacterSequence(at: at.location - 1))
            guard preceding.allSatisfy({ $0.isWhitespace }) || "([{\"'“‘".contains(preceding) else { return nil }
        }
        let range = NSRange(location: at.location, length: selection.location - at.location)
        let query = text.substring(with: NSRange(location: at.location + 1, length: range.length - 1))
        guard !query.contains(where: { $0.isNewline || ",.;:!?@)]}".contains($0) }) else { return nil }
        return range
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
    @Published var newName: String?
    private var popup: NSPopover?
    private var queryRange: NSRange?
    private var detailsPopup: NSPopover?
    private var scrollObserver: NSObjectProtocol?
    private(set) var inspectedReference: ProjectTagReference?
    private(set) var detailsAnchor: NSRect?
    var detailsVisible: Bool { detailsPopup?.isShown == true }
    private(set) var inserting = false
    var visible: Bool { popup?.isShown == true }
    init(view: ManuscriptTextView) { self.view = view; super.init() }

    func close() { popup?.close(); popup = nil; queryRange = nil; closeDetails() }
    func closeDetails() {
        detailsPopup?.close(); detailsPopup = nil; inspectedReference = nil; detailsAnchor = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
    }
    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === detailsPopup { closeDetails() }
        else if let closed = notification.object as? NSPopover, closed === popup { popup = nil; queryRange = nil }
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
        guard !inserting, let view, let range = ObjectTags.queryRange(in: view.string, selection: view.selectedRange()) else { close(); return }
        queryRange = range
        let query = (view.string as NSString).substring(with: NSRange(location: range.location + 1, length: range.length - 1))
        suggestions = ObjectTags.matches(objects, query: query); highlighted = 0
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = suggestions.isEmpty && name.count >= 2 && name.count <= 100 && name.contains(where: \.isLetter) ? name : nil
        present()
    }
    func browse() {
        guard let view else { return }
        queryRange = nil; newName = nil; suggestions = ObjectTags.matches(objects, query: ""); highlighted = 0
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
        case 125: if !suggestions.isEmpty { highlighted = min(highlighted + 1, suggestions.count - 1) }; return true
        case 126: highlighted = max(0, highlighted - 1); return true
        case 36, 48, 76:
            guard suggestions.indices.contains(highlighted) else { close(); return false }
            insert(suggestions[highlighted]); return true
        default: return false
        }
    }
    func insert(_ object: TaggedProjectObject) {
        guard let view, objects.contains(where: { $0.reference == object.reference }) else { close(); return }
        let selected = queryRange ?? view.selectedRange()
        guard NSMaxRange(selected) <= view.string.utf16.count else { close(); return }
        let label: NSAttributedString
        if queryRange == nil, selected.length > 0, let storage = view.textStorage {
            label = storage.attributedSubstring(from: selected)
        } else {
            var attributes = view.typingAttributes; attributes.removeValue(forKey: .link)
            label = NSAttributedString(string: object.title, attributes: attributes)
        }
        let tagged = NSMutableAttributedString(attributedString: label)
        tagged.addAttribute(.link, value: object.reference.url, range: NSRange(location: 0, length: tagged.length))
        inserting = true; close()
        var typing = view.typingAttributes; typing.removeValue(forKey: .link)
        view.window?.makeFirstResponder(view); view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.insertText(tagged, replacementRange: selected)
        view.undoManager?.endUndoGrouping()
        view.typingAttributes = typing; view.undoManager?.setActionName("Tag project object")
        inserting = false
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
            Text(session.newName == nil ? "↑ ↓ to choose · Return to tag · Esc to close" : "Choose how to add this name · Esc to close").font(.caption).foregroundStyle(.secondary)
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
                            Button { session.insert(object) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: object.symbol).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) { Text(object.title).fontWeight(.medium); Text(object.group + (object.summary.isEmpty ? "" : " · " + object.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    Spacer()
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(index == session.highlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).id(object.id)
                        }
                    }
                }.frame(maxHeight: 280)
                    .onChange(of: session.highlighted) { _, value in if session.suggestions.indices.contains(value) { proxy.scrollTo(session.suggestions[value].id) } }
            } }
        }.padding(16).frame(width: 340).tint(AppTheme.accent)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !object.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(object.summary).fixedSize(horizontal: false, vertical: true) }
                        if !object.aliases.isEmpty { detail("Also known as", text: object.aliases.joined(separator: ", ")) }
                        ForEach(object.details) { field in detail(field.title, text: field.text) }
                        if object.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && object.details.isEmpty {
                            Text("No details yet. Open the profile to add them.").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 300)
                Divider()
                Button(action: open) { Label("Open full profile", systemImage: "sidebar.right").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).foregroundStyle(AppTheme.accent)
            } else {
                Text("This object is no longer in the project.")
                Text("Your words are preserved. Use Remove tag from selection to unlink them.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Option-click tagged words to edit the text.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(width: 340).tint(AppTheme.accent)
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
