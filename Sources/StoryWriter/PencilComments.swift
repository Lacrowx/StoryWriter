import AppKit
import SwiftUI

enum CommentInk: String, Codable, CaseIterable {
    case rose = "Rose", blue = "Blue", green = "Green", amber = "Amber"
    func color(dark: Bool) -> NSColor {
        switch self {
        case .rose: return dark ? NSColor(srgbRed: 0.94, green: 0.58, blue: 0.69, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.22, blue: 0.38, alpha: 1)
        case .blue: return dark ? NSColor(srgbRed: 0.53, green: 0.74, blue: 0.98, alpha: 1) : NSColor(srgbRed: 0.22, green: 0.43, blue: 0.74, alpha: 1)
        case .green: return dark ? NSColor(srgbRed: 0.48, green: 0.80, blue: 0.66, alpha: 1) : NSColor(srgbRed: 0.18, green: 0.48, blue: 0.36, alpha: 1)
        case .amber: return dark ? NSColor(srgbRed: 0.95, green: 0.74, blue: 0.40, alpha: 1) : NSColor(srgbRed: 0.65, green: 0.38, blue: 0.10, alpha: 1)
        }
    }
}
extension PassageComment {
    var pencilInk: CommentInk { ink ?? CommentInk.allCases[Int(id.uuid.0) % CommentInk.allCases.count] }
}
enum PencilCommentChange { case note(String), resolved(Bool), ink(CommentInk) }
private struct ChangePassageCommentKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID, UUID, PencilCommentChange) -> Void = { _, _, _ in }
}
extension EnvironmentValues {
    var changePassageComment: @MainActor (UUID, UUID, PencilCommentChange) -> Void {
        get { self[ChangePassageCommentKey.self] } set { self[ChangePassageCommentKey.self] = newValue }
    }
}

enum PencilComments {
    static func attached(_ comments: [PassageComment], to text: String) -> [PassageComment] {
        let string = text as NSString
        return comments.filter { comment in
            !comment.resolved && !comment.detached && comment.start >= 0 && comment.length > 0 &&
            comment.start <= string.length && comment.length <= string.length - comment.start &&
            string.substring(with: comment.range) == comment.quote
        }.sorted { $0.start == $1.start ? $0.createdAt < $1.createdAt : $0.start < $1.start }
    }
    static func columnWidth(pageWidth: CGFloat, margin: CGFloat, hasNotes: Bool) -> CGFloat {
        guard hasNotes else { return 0 }
        return max(0, min(190, max(100, pageWidth * 0.23), pageWidth - margin * 2 - 220))
    }
    static var font: NSFont { NSFont(name: "Noteworthy-Light", size: 15) ?? NSFont(name: "Bradley Hand", size: 15) ?? .systemFont(ofSize: 14, weight: .light) }
}

/// Editable margin notes and sketch marks are display-only, outside the manuscript.
@MainActor
final class PencilCommentLayer {
    weak var view: ManuscriptTextView?
    var comments: [PassageComment] = []
    var change: (UUID, PencilCommentChange) -> Void = { _, _ in }
    var enabled = true
    private(set) var notes: [PencilNoteView] = []
    private var marks: [(rect: NSRect, ink: CommentInk, seed: Int)] = []
    private var connectors: [(geometry: PencilConnector, ink: CommentInk, seed: Int)] = []
    private var lastWidth: CGFloat = -1
    private var needsRebuild = true
    private var rebuilding = false
    var attached: [PassageComment] { guard enabled, let view else { return [] }; return PencilComments.attached(comments, to: view.string) }

    init(view: ManuscriptTextView) { self.view = view }
    func invalidate() {
        needsRebuild = true
        // Empty margins have no geometry to update. Forcing NSTextView layout
        // here also invalidates input-method coordinates on every keystroke.
        if !notes.isEmpty || !marks.isEmpty || !connectors.isEmpty ||
            (enabled && comments.contains(where: { !$0.resolved && !$0.detached })) {
            view?.needsLayout = true
        }
    }
    func update(_ comments: [PassageComment], enabled: Bool, change: @escaping (UUID, PencilCommentChange) -> Void) {
        self.change = change
        guard self.comments != comments || self.enabled != enabled else { return }
        self.comments = comments; self.enabled = enabled; invalidate()
    }
    func layout() {
        guard !rebuilding, let view, let manager = view.layoutManager, let container = view.textContainer,
              needsRebuild || abs(lastWidth - container.size.width) > 0.5 else { return }
        rebuilding = true; defer { rebuilding = false }
        needsRebuild = false; lastWidth = container.size.width
        let active = attached
        let hadDecorations = !notes.isEmpty || !marks.isEmpty || !connectors.isEmpty
        let ids = Set(active.map(\.id))
        for note in notes where !ids.contains(note.comment.id) {
            if view.window?.firstResponder === note.editor { view.window?.makeFirstResponder(view) }
            note.removeFromSuperview()
        }
        notes.removeAll { !ids.contains($0.comment.id) }
        marks = []; connectors = []
        // An empty margin must not force TextKit to lay out the entire chapter.
        guard !active.isEmpty else {
            let resized = view.minSize.height != 0
            if resized {
                view.minSize = NSSize(width: 0, height: 0)
                view.sizeToFit()
            }
            if hadDecorations || resized { view.needsDisplay = true }
            return
        }
        manager.ensureLayout(for: container)
        var bottom: CGFloat = 0
        let origin = view.textContainerOrigin
        let width = max(24, view.pencilColumnWidth - 24)
        let x = origin.x + container.size.width + 22
        for (index, comment) in active.enumerated() {
            let firstGlyph = manager.glyphIndexForCharacter(at: comment.start)
            let line = manager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
            let measure = (comment.note as NSString).boundingRect(with: NSSize(width: max(1, width - 24), height: 180), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: PencilComments.font])
            let height = min(220, max(62, ceil(measure.height) + 36))
            let y = max(line.minY + origin.y - 6, bottom == 0 ? 0 : bottom + 12)
            let note = notes.first { $0.comment.id == comment.id } ?? PencilNoteView(comment: comment)
            if note.superview == nil { view.addSubview(note); notes.append(note) }
            note.number = index + 1
            note.change = { [weak self] in self?.change(comment.id, $0) }
            note.appCommands = view.appContextCommands
            note.frame = NSRect(x: x, y: y, width: width, height: height)
            note.configure(comment)
            bottom = note.frame.maxY
        }
        for (index, comment) in active.enumerated() {
            let glyphs = manager.glyphRange(forCharacterRange: comment.range, actualCharacterRange: nil)
            var lines: [PencilAnchorLine] = []
            var cursor = glyphs.location
            while cursor < NSMaxRange(glyphs) {
                var lineRange = NSRange()
                let used = manager.lineFragmentUsedRect(forGlyphAt: cursor, effectiveRange: &lineRange)
                let part = NSIntersectionRange(glyphs, lineRange)
                let selection = manager.boundingRect(forGlyphRange: part, in: container)
                if selection.width > 0 {
                    lines.append(PencilAnchorLine(selection: selection.offsetBy(dx: origin.x, dy: origin.y), text: used.offsetBy(dx: origin.x, dy: origin.y)))
                }
                cursor = max(cursor + 1, NSMaxRange(lineRange))
            }
            marks += lines.enumerated().map { (rect: $0.element.selection, ink: comment.pencilInk, seed: index + $0.offset) }
            if let note = notes.first(where: { $0.comment.id == comment.id }),
               let geometry = PencilRouting.connector(lines: lines, textEdge: origin.x + container.size.width, note: note.frame) {
                connectors.append((geometry, comment.pencilInk, index))
            }
        }
        view.minSize = NSSize(width: 0, height: active.isEmpty ? 0 : bottom + 36)
        view.sizeToFit(); view.needsDisplay = true
    }
    func draw(in dirtyRect: NSRect) {
        guard let view else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (rect, ink, seed) in marks where rect.insetBy(dx: -4, dy: -6).intersects(dirtyRect) {
            ink.color(dark: dark).withAlphaComponent(0.7).setStroke()
            let line = NSBezierPath(); line.lineWidth = 0.8; line.lineCapStyle = .round
            let y = rect.maxY + 2
            line.move(to: NSPoint(x: rect.minX - 1, y: y))
            line.curve(to: NSPoint(x: rect.maxX + 1, y: y + 0.5), controlPoint1: NSPoint(x: rect.minX + rect.width * 0.35, y: y + CGFloat(seed % 3) - 0.5), controlPoint2: NSPoint(x: rect.minX + rect.width * 0.7, y: y - 1))
            line.stroke()
            ink.color(dark: dark).withAlphaComponent(0.3).setStroke()
            let echo = NSBezierPath(); echo.lineWidth = 0.4; echo.lineCapStyle = .round
            let accent = min(24, rect.width * 0.3)
            echo.move(to: NSPoint(x: rect.minX + 2, y: y + 1.7)); echo.line(to: NSPoint(x: rect.minX + 2 + accent, y: y + 2)); echo.stroke()
        }
        for (geometry, ink, seed) in connectors {
            ink.color(dark: dark).withAlphaComponent(0.72).setStroke()
            PencilRouting.marker(geometry).stroke()
            PencilRouting.path(geometry, seed: seed).stroke()
        }
    }
}

@MainActor
final class PencilNoteView: NSView, NSTextViewDelegate {
    var comment: PassageComment
    var number = 1
    var change: (PencilCommentChange) -> Void = { _ in }
    var appCommands: @MainActor () -> [ContextCommand] = { [] }
    let editor = ManuscriptTextView(frame: .zero)
    private let scroll = NSScrollView()
    private let resolve = NSButton(title: "✓", target: nil, action: nil)
    private let inkButton = NSButton(title: "●", target: nil, action: nil)
    override var isFlipped: Bool { true }
    init(comment: PassageComment) {
        self.comment = comment; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        editor.usesManuscriptMargins = false; editor.isRichText = false; editor.allowsUndo = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.font = PencilComments.font; editor.drawsBackground = false; editor.delegate = self
        editor.isAutomaticSpellingCorrectionEnabled = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = editor; addSubview(scroll)
        for button in [resolve, inkButton] { button.isBordered = false; button.font = .systemFont(ofSize: 13); addSubview(button) }
        resolve.target = self; resolve.action = #selector(resolveComment(_:)); resolve.toolTip = "Resolve comment"
        resolve.setAccessibilityLabel("Resolve comment")
        inkButton.target = self; inkButton.action = #selector(chooseInk(_:)); inkButton.toolTip = "Comment ink"
        inkButton.setAccessibilityLabel("Comment ink")
        configure(comment)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ comment: PassageComment) {
        self.comment = comment
        if editor.string != comment.note {
            let selection = editor.selectedRange()
            editor.string = comment.note
            editor.setSelectedRange(NSRange(location: min(selection.location, comment.note.utf16.count), length: 0))
        }
        editor.appContextCommands = { [weak self] in self?.commentCommands() ?? [] }
        setAccessibilityLabel("Handwritten comment \(number)")
        refreshInk(); needsLayout = true
    }
    private func refreshInk() {
        let color = comment.pencilInk.color(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        editor.textColor = color; editor.insertionPointColor = color
        resolve.contentTintColor = color; inkButton.contentTintColor = color
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshInk() }
    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(26, bounds.height - 26))
        inkButton.frame = NSRect(x: max(0, bounds.width - 48), y: bounds.height - 25, width: 22, height: 22)
        resolve.frame = NSRect(x: max(22, bounds.width - 24), y: bounds.height - 25, width: 22, height: 22)
    }
    func textDidChange(_ notification: Notification) { change(.note(editor.string)) }
    @objc private func resolveComment(_ sender: NSButton) { change(.resolved(true)) }
    @objc private func chooseInk(_ sender: NSButton) {
        ContextCommand.menu(inkCommands()).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    private func inkCommands() -> [ContextCommand] {
        CommentInk.allCases.map { ink in .button(ink.rawValue, checked: comment.pencilInk == ink) { [weak self] in self?.change(.ink(ink)) } }
    }
    private func commentCommands() -> [ContextCommand] {
        [.button("Resolve comment") { [weak self] in self?.change(.resolved(true)) }, .submenu("Comment ink", inkCommands()), .separator] + appCommands()
    }
    override func menu(for event: NSEvent) -> NSMenu? { ContextCommand.menu(commentCommands()) }
}
