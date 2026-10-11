import AppKit
import SwiftUI
import Combine

/// Keeps passage actions attached to a stable selection without interrupting a drag.
@MainActor
final class SelectionQuickActionSession: NSObject, ObservableObject, NSPopoverDelegate {
    weak var view: ManuscriptTextView?
    @Published private var revision = 0
    private var popup: NSPopover?
    private var pending: Task<Void, Never>?
    private var scrollObserver: NSObjectProtocol?
    private var grammarObserver: AnyCancellable?
    private var observedRange = NSRange(location: NSNotFound, length: 0)
    private(set) var passageRange = NSRange(location: 0, length: 0)
    private var snapshot = ""
    private(set) var anchor: NSRect?
    var visible: Bool { popup?.isShown == true }

    init(view: ManuscriptTextView) {
        self.view = view
        super.init()
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        grammarObserver = view.grammarSession?.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshContent() }
        }
    }

    deinit {
        pending?.cancel()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func selectionChanged() {
        guard let view else { close(); return }
        let range = view.selectedRange()
        guard range != observedRange else { return }
        observedRange = range
        close()
        guard Self.isPassage(range, in: view.string) else { return }
        let text = view.string
        pending = Task { [weak self] in
            // Selection notifications arrive throughout mouse tracking and Shift-arrow repeats.
            try? await Task.sleep(nanoseconds: 180_000_000)
            while !Task.isCancelled && NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled, let self, let view = self.view,
                  view.selectedRange() == range, view.string == text,
                  view.window?.firstResponder === view,
                  view.tagSession?.visible != true, view.tagSession?.detailsVisible != true,
                  view.grammarSession?.popoverVisible != true,
                  view.objectNames?.popoverVisible != true else { return }
            self.present()
        }
    }

    static func isPassage(_ range: NSRange, in text: String) -> Bool {
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return false }
        return !source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func close() {
        pending?.cancel(); pending = nil
        let old = popup; popup = nil; anchor = nil
        old?.close()
    }
    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === popup { close() }
    }
    func refreshContent() {
        guard visible else { return }
        guard view?.string == snapshot, view?.selectedRange() == passageRange else { close(); return }
        revision += 1
    }

    @discardableResult func present() -> Bool {
        guard let view, view.window?.isVisible == true,
              Self.isPassage(view.selectedRange(), in: view.string),
              let manager = view.layoutManager, let container = view.textContainer else { close(); return false }
        close()
        passageRange = view.selectedRange(); observedRange = passageRange; snapshot = view.string
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: passageRange, actualCharacterRange: nil)
        var rect: NSRect?
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, line, stop in
            let selected = NSIntersectionRange(line, glyphs)
            let bounds = manager.boundingRect(forGlyphRange: selected, in: container)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            let visible = bounds.intersection(view.visibleRect)
            if !visible.isNull && visible.width > 0 && visible.height > 0 { rect = visible; stop.pointee = true }
        }
        guard let rect else { return false }
        view.tagSession?.close(); view.objectNames?.close()
        let popup = NSPopover(); popup.behavior = .transient; popup.animates = false; popup.delegate = self
        popup.contentViewController = NSHostingController(rootView: SelectionQuickActionBubble(session: self))
        self.popup = popup; anchor = rect
        popup.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        view.window?.makeFirstResponder(view)
        return popup.isShown
    }

    var wordCount: Int {
        guard Self.isPassage(passageRange, in: snapshot) else { return 0 }
        return (snapshot as NSString).substring(with: passageRange).wordCount
    }

    /// Every leaf validates the original passage and restores it before invoking existing tools.
    func run(_ action: () -> Void) {
        guard let view, view.string == snapshot, view.selectedRange() == passageRange else { close(); return }
        let range = passageRange
        close()
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range)
        action()
        view.contextEditor?.refresh()
    }
    private func protected(_ commands: [ContextCommand]) -> [ContextCommand] {
        commands.map { command in
            var result = command
            if let children = command.children { result.children = protected(children) }
            if let action = command.action { result.action = { [weak self] in self?.run(action) } }
            return result
        }
    }
    var chapterCommands: [ContextCommand] {
        guard let view, view.string == snapshot else { return [] }
        return protected(view.chapterContextCommands?(passageRange, snapshot) ?? [])
    }
    var formatting: [ContextCommand] {
        guard let view, view.string == snapshot, let editor = view.contextEditor,
              Self.isPassage(passageRange, in: view.string) else { return [] }
        let attrs = view.textStorage?.attributes(at: passageRange.location, effectiveRange: nil) ?? [:]
        let traits = NSFontManager.shared.traits(of: attrs[.font] as? NSFont ?? NSFont(name: "Georgia", size: 18) ?? NSFont.systemFont(ofSize: 18))
        return protected([
            .button("Bold", checked: traits.contains(.boldFontMask)) { [weak editor] in editor?.action(#selector(ManuscriptTextView.toggleBoldface(_:))) },
            .button("Italic", checked: traits.contains(.italicFontMask)) { [weak editor] in editor?.action(#selector(ManuscriptTextView.toggleItalics(_:))) },
            .button("Underline", checked: (attrs[.underlineStyle] as? Int ?? 0) != 0) { [weak editor] in editor?.action(#selector(NSTextView.underline(_:))) }
        ])
    }
    var reviewCommand: ContextCommand? {
        guard let grammar = view?.grammarSession else { return nil }
        let range = passageRange
        return protected([.button("Review text", enabled: !grammar.checking) { [weak grammar] in grammar?.review(.selection, selection: range) }]).first
    }
    var suggestionCommands: [ContextCommand] {
        guard let grammar = view?.grammarSession else { return [] }
        let range = passageRange
        let corrections = grammar.selectedCorrections(.selection, anchor: range)
        guard !corrections.isEmpty else { return [] }
        return protected([
            .button("Accept \(corrections.count) suggestion\(corrections.count == 1 ? "" : "s")") { [weak grammar] in grammar?.accept(.selection, anchor: range) },
            .button("Dismiss suggestions") { [weak grammar] in corrections.forEach { grammar?.dismiss($0.id) } }
        ])
    }
    var tagCommands: [ContextCommand] {
        guard let view, view.string == snapshot, let tags = view.tagSession, let storage = view.textStorage,
              NSMaxRange(passageRange) <= storage.length else { return [] }
        var commands: [ContextCommand] = []
        var references: [ProjectTagReference] = []
        storage.enumerateAttribute(.link, in: passageRange) { value, _, _ in
            if let ref = ProjectTagReference.from(value), !references.contains(ref) { references.append(ref) }
        }
        for reference in references {
            let title = tags.objects.first { $0.reference == reference }?.title ?? "tagged object"
            commands.append(.button("Open \(title)") { [weak tags] in tags?.open(reference) })
        }
        let selected = (snapshot as NSString).substring(with: passageRange).trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = ObjectTags.matches(tags.objects, query: selected)
        for object in matches.prefix(3) where !references.contains(object.reference) {
            commands.append(.button("Tag as \(object.title)") { [weak tags] in tags?.insert(object) })
        }
        if !commands.isEmpty { commands.append(.separator) }
        for group in ObjectTags.groupOrder {
            let objects = ObjectTags.matches(tags.objects.filter { $0.group == group }, query: "")
            if !objects.isEmpty {
                commands.append(.submenu(group, objects.map { object in
                    .button(object.title) { [weak tags] in tags?.insert(object) }
                }))
            }
        }
        if !references.isEmpty {
            commands += [.separator, .button("Remove tags from selection") { [weak tags] in tags?.removeSelectedTag() }]
        }
        return protected(commands)
    }
    func copyPassage() { run { [weak view] in view?.copy(nil) } }
}

private struct SelectionQuickActionBubble: View {
    @ObservedObject var session: SelectionQuickActionSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(session.wordCount) word\(session.wordCount == 1 ? "" : "s") selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { session.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).help("Dismiss · Escape").accessibilityLabel("Dismiss selection actions")
            }
            HStack(spacing: 6) {
                ForEach(Array(session.formatting.enumerated()), id: \.element.id) { index, command in
                    Button { command.action?() } label: { Image(systemName: ["bold", "italic", "underline"][index]).frame(width: 18, height: 18) }
                        .tint(command.checked == true ? .accentColor : .primary).help(command.title).accessibilityLabel(command.title)
                }
                Divider().frame(height: 20)
                if let comment = session.chapterCommands.first(where: { $0.title == "Add comment to selection" }) {
                    Button { comment.action?() } label: { Label("Comment", systemImage: "text.bubble") }.disabled(!comment.enabled)
                }
                if let review = session.reviewCommand {
                    Button { review.action?() } label: { Label("Review", systemImage: "text.badge.checkmark") }.disabled(!review.enabled).help("Review the selected passage")
                }
            }
            HStack(spacing: 10) {
                let tags = session.tagCommands
                if !tags.isEmpty { Menu { ContextCommandItems(commands: tags) } label: { Label("Tag", systemImage: "tag") } }
                if let continuity = session.chapterCommands.first(where: { $0.title == "Track a character change" }), let children = continuity.children, !children.isEmpty {
                    Menu { ContextCommandItems(commands: children) } label: { Label("Continuity", systemImage: "person.badge.clock") }
                }
                let suggestions = session.suggestionCommands
                if !suggestions.isEmpty { Menu { ContextCommandItems(commands: suggestions) } label: { Label("Suggestions", systemImage: "checkmark.circle") } }
                Spacer(minLength: 0)
                Button { session.copyPassage() } label: { Image(systemName: "doc.on.doc") }.help("Copy selection").accessibilityLabel("Copy selection")
            }.menuStyle(.borderlessButton).tint(.primary)
        }.buttonStyle(.bordered).controlSize(.small).padding(12).frame(width: 370)
    }
}
