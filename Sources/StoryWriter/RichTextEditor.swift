import SwiftUI
import AppKit

@MainActor
final class EditorController: ObservableObject {
    weak var textView: NSTextView?
    var chapterID: UUID?
    @Published var selectionWords = 0
    @Published var fieldFocused = false
    @Published var fontName = "Georgia"
    @Published var fontSize = 18.0
    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderlined = false
    @Published var alignment: NSTextAlignment = .left
    @Published var lineSpacing: CGFloat = 6
    @Published var selectionText = ""
    /// Always current; publish at most once per display frame without waiting for movement to stop.
    private(set) var selectionRange = NSRange(location: 0, length: 0)
    private var selectionSettle: Task<Void, Never>?
    private var selectionSettleIsTyping = false
    private var positionChapterID: UUID?
    @Published var grammar: InlineGrammarSession?
    @Published var tags: ObjectTagSession?
    @Published var objectNames: ObjectNameSession?
    @Published var pendingCommentFocus: UUID?

    func refresh(whileTyping: Bool = false) {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let moved = selectionRange != range || positionChapterID != chapterID
        if moved || whileTyping {
            selectionRange = range
            positionChapterID = chapterID
            if whileTyping || selectionSettle == nil || selectionSettleIsTyping {
                selectionSettle?.cancel()
                selectionSettleIsTyping = whileTyping
                selectionSettle = Task { [weak self] in
                    // AppKit paints typing immediately. Defer dependent SwiftUI
                    // panels while typing, but follow navigation within one frame.
                    try? await Task.sleep(nanoseconds: whileTyping ? 350_000_000 : 16_000_000)
                    guard !Task.isCancelled else { return }
                    self?.selectionSettle = nil
                    self?.objectWillChange.send()
                }
            }
        }
        grammar?.selectionChanged(whileTyping: whileTyping)
        if NSMaxRange(range) <= (view.string as NSString).length {
            let selected = (view.string as NSString).substring(with: range)
            if selectionText != selected {
                selectionText = selected
                let words = selected.wordCount
                if selectionWords != words { selectionWords = words }
            }
        }
        let attributes = range.location < view.textStorage?.length ?? 0 ? view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? view.typingAttributes : view.typingAttributes
        if let font = attributes[.font] as? NSFont {
            let name = font.familyName ?? "Georgia", size = Double(font.pointSize)
            if fontName != name { fontName = name }
            if fontSize != size { fontSize = size }
            let traits = NSFontManager.shared.traits(of: font)
            let bold = traits.contains(.boldFontMask), italic = traits.contains(.italicFontMask)
            if isBold != bold { isBold = bold }
            if isItalic != italic { isItalic = italic }
        }
        let underlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        if isUnderlined != underlined { isUnderlined = underlined }
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        let paragraphAlignment = paragraph?.alignment ?? .left, spacing = paragraph?.lineSpacing ?? 6
        if alignment != paragraphAlignment { alignment = paragraphAlignment }
        if lineSpacing != spacing { lineSpacing = spacing }
    }

    func selectionContainsAttribute(_ key: NSAttributedString.Key, matching: (Any) -> Bool = { _ in true }) -> Bool {
        guard let storage = textView?.textStorage, storage.length > 0,
              selectionRange.location >= 0, selectionRange.location < storage.length,
              NSMaxRange(selectionRange) <= storage.length else { return false }
        let range = selectionRange.length > 0 ? selectionRange : NSRange(location: selectionRange.location, length: 1)
        var found = false
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if let value, matching(value), !(value is String && (value as? String)?.isEmpty == true) { found = true; stop.pointee = true }
        }
        return found
    }

    func removeWebLinks() {
        guard let view = textView as? ManuscriptTextView, let storage = view.textStorage, storage.length > 0 else { return }
        var range = view.selectedRange()
        guard range.location >= 0, range.location < storage.length, NSMaxRange(range) <= storage.length else { return }
        if range.length == 0 {
            guard let value = storage.attribute(.link, at: range.location, effectiveRange: &range),
                  ProjectTagReference.from(value) == nil else { return }
        }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var links: [NSRange] = []
        replacement.enumerateAttribute(.link, in: NSRange(location: 0, length: replacement.length)) { value, part, _ in
            if let value, ProjectTagReference.from(value) == nil { links.append(part) }
        }
        guard !links.isEmpty else { return }
        for part in links { replacement.removeAttribute(.link, range: part) }
        if view.replaceAttributedText(replacement, range: range) { view.window?.makeFirstResponder(view); refresh() }
    }

    @discardableResult func tagPassage(_ reference: ProjectTagReference, chapterID: UUID, range: NSRange, expectedText: String) -> Bool {
        guard self.chapterID == chapterID, let view = textView as? ManuscriptTextView,
              view.string == expectedText, range.length > 0, range.location >= 0,
              NSMaxRange(range) <= view.string.utf16.count, Range(range, in: expectedText) != nil,
              let storage = view.textStorage else { return false }
        let tagged = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        tagged.addAttribute(.link, value: reference.url, range: NSRange(location: 0, length: tagged.length))
        guard view.replaceAttributedText(tagged, range: range) else { return false }
        view.undoManager?.setActionName("Tag object")
        refresh()
        return true
    }

    /// Keep the live chapter in sync before @ creation or selection tagging saves it again.
    func linkExistingMentions(_ reference: ProjectTagReference, in project: StoryProject) {
        guard let chapterID, project.chapters.contains(where: { $0.id == chapterID }),
              let view = textView as? ManuscriptTextView, let storage = view.textStorage else { return }
        let matches = ObjectMentionLinker(names: ObjectMentionLinker.names(in: project)).matches(in: storage, references: [reference])
        guard !matches.isEmpty else { return }
        let selection = view.selectedRanges, typing = view.typingAttributes
        view.breakUndoCoalescing(); view.undoManager?.beginUndoGrouping()
        for match in matches {
            let linked = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: match.range))
            linked.addAttribute(.link, value: reference.url, range: NSRange(location: 0, length: linked.length))
            _ = view.replaceAttributedText(linked, range: match.range)
        }
        view.selectedRanges = selection; view.typingAttributes = typing
        view.undoManager?.setActionName("Link existing mentions"); view.undoManager?.endUndoGrouping()
        refresh()
    }

    func action(_ selector: Selector) {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        NSApp.sendAction(selector, to: view, from: nil)
        refresh()
    }

    func find() {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        let item = NSMenuItem(); item.tag = 1; view.performFindPanelAction(item)
    }

    func setAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        guard let view = textView else { return }
        let range = view.selectedRange()
        if range.length > 0, let storage = view.textStorage, view.shouldChangeText(in: range, replacementString: nil) {
            storage.addAttributes(attributes, range: range); view.didChangeText()
        }
        if range.length == 0 { view.typingAttributes.merge(attributes) { _, new in new } }
        view.window?.makeFirstResponder(view); refresh()
    }

    func setFont(name: String? = nil, size: Double? = nil) {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let chosenName = name ?? fontName, chosenSize = CGFloat(size ?? fontSize)
        guard let base = NSFont(name: chosenName, size: chosenSize) else { return }
        if range.length == 0 { setAttributes([.font: base]); return }
        guard let storage = view.textStorage, view.shouldChangeText(in: range, replacementString: nil) else { return }
        var updates: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            let old = value as? NSFont ?? base
            let traits = NSFontManager.shared.traits(of: old)
            updates.append((part, NSFontManager.shared.convert(base, toHaveTrait: traits)))
        }
        for (part, font) in updates { storage.addAttribute(.font, value: font, range: part) }
        view.didChangeText(); view.window?.makeFirstResponder(view); refresh()
    }

    func paragraphSpacing(_ spacing: CGFloat) {
        guard let view = textView else { return }
        let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
        let style = ((view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineSpacing = spacing; style.paragraphSpacing = 12
        if range.length > 0, view.shouldChangeText(in: range, replacementString: nil) { view.textStorage?.addAttribute(.paragraphStyle, value: style, range: range); view.didChangeText() }
        view.typingAttributes[.paragraphStyle] = style
        view.window?.makeFirstResponder(view); refresh()
    }

    func bulletList(numbered: Bool = false) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let lines = (replacement.string as NSString).components(separatedBy: "\n")
        var offset = 0
        for (index, line) in lines.dropLast(lines.last == "" ? 1 : 0).enumerated() {
            let prefix = numbered ? "\(index + 1). " : "• "
            if !line.hasPrefix(prefix) {
                let attrs = replacement.length > offset ? replacement.attributes(at: offset, effectiveRange: nil) : WritingStyle.attributes
                replacement.insert(NSAttributedString(string: prefix, attributes: attrs), at: offset); offset += prefix.utf16.count
            }
            offset += (line as NSString).length + 1
        }
        view.insertText(replacement, replacementRange: range); view.window?.makeFirstResponder(view)
    }

    func strikeThrough() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let attributes = range.location < (view.textStorage?.length ?? 0) ? view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? view.typingAttributes : view.typingAttributes
        setAttributes([.strikethroughStyle: (attributes[.strikethroughStyle] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0])
    }

    @discardableResult func replaceUnique(original: String, replacement: String, expectedChapter: UUID) -> Bool {
        guard chapterID == expectedChapter, let view = textView, !original.isEmpty else { return false }
        let text = view.string as NSString
        let range = text.range(of: original)
        guard range.location != NSNotFound else { return false }
        let tail = NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))
        guard text.range(of: original, options: [], range: tail).location == NSNotFound else { return false }
        let attrs = view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? WritingStyle.attributes
        view.insertText(NSAttributedString(string: replacement, attributes: attrs), replacementRange: range)
        return true
    }
}

final class ManuscriptTextView: NSTextView {
    weak var contextEditor: EditorController?
    var appContextCommands: @MainActor () -> [ContextCommand] = { [] }
    var chapterContextCommands: (@MainActor (NSRange, String) -> [ContextCommand])?
    var pencilComments: PencilCommentLayer?
    private(set) var pencilColumnWidth: CGFloat = 0
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x - pencilColumnWidth / 2, y: origin.y)
    }
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + (pencilComments?.notes ?? [])
    }
    override func draw(_ dirtyRect: NSRect) {
        // NSTextView leaves a clip to the text column; margin marks need the original clip.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        pencilComments?.draw(in: dirtyRect)
        if let ghost = completionGhost() { ghost.text.draw(at: ghost.rect.origin) }
    }
    /// Grey remainder of a known name, drawn just after the caret.
    private func completionGhost(for completion: NameCompletion? = nil) -> (text: NSAttributedString, rect: NSRect)? {
        guard let completion = completion ?? tagSession?.completion, let manager = layoutManager, let storage = textStorage, let container = textContainer,
              NSMaxRange(completion.prefix) <= storage.length, completion.prefix.length > 0 else { return nil }
        let last = NSMaxRange(completion.prefix) - 1
        let glyph = manager.glyphIndexForCharacter(at: last)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let font = storage.attribute(.font, at: last, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 18)
        let text = NSAttributedString(string: completion.suffix, attributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.35)])
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        let baseline = line.minY + manager.location(forGlyphAt: glyph).y
        let origin = NSPoint(x: x + textContainerOrigin.x, y: baseline - font.ascender + textContainerOrigin.y)
        return (text, NSRect(origin: origin, size: text.size()).insetBy(dx: -2, dy: -2))
    }
    func completionChanged(from old: NameCompletion?) {
        if let old, let rect = completionGhost(for: old)?.rect { setNeedsDisplay(rect) }
        if let rect = completionGhost()?.rect { setNeedsDisplay(rect) }
    }
    var grammarSession: InlineGrammarSession?
    var tagSession: ObjectTagSession?
    var objectNames: ObjectNameSession?
    var selectionActions: SelectionQuickActionSession?
    var usesManuscriptMargins = true
    var paperMargins = PaperMargins.balanced
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        selectionActions?.close()
        tagSession?.close(); objectNames?.close()
        window?.makeFirstResponder(self)
        let selection = selectedRange()
        let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let preserveSelection = selection.length > 0 && NSLocationInRange(location, selection)
        if !preserveSelection { setSelectedRange(NSRange(location: location, length: 0)) }
        let menu = super.menu(for: event) ?? NSMenu()
        if preserveSelection { setSelectedRange(selection) }
        let additions = ContextCommand.menu(writingContextCommands())
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for item in additions.items { additions.removeItem(item); menu.addItem(item) }
        return menu
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { tagSession?.dismissCompletion(); onBlur?() }
        return result
    }
    @discardableResult func replaceAttributedText(_ replacement: NSAttributedString, range: NSRange) -> Bool {
        guard let storage = textStorage, range.location >= 0, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: replacement.string) else { return false }
        // NSTextView.insertText can extend a partially selected link across
        // the whole replacement. Write the prepared attributes exactly.
        storage.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        var typing = typingAttributes
        if ProjectTagReference.from(typing[.link]) != nil { typing.removeValue(forKey: .link) }
        typingAttributes = typing
        didChangeText()
        return true
    }

    /// Apply profile-created tags without replacing prose or clearing the writer's undo history.
    /// The model already contains these attributes, so no text-change notification is needed.
    func mergeAddedObjectTags(from incoming: NSAttributedString) -> Bool {
        guard let storage = textStorage, storage.string == incoming.string else { return false }
        let existingProse = NSMutableAttributedString(attributedString: storage)
        let incomingProse = NSMutableAttributedString(attributedString: incoming)
        let full = NSRange(location: 0, length: storage.length)
        existingProse.removeAttribute(.link, range: full); incomingProse.removeAttribute(.link, range: full)
        guard existingProse.isEqual(to: incomingProse) else { return false }
        var additions: [(NSRange, ProjectTagReference)] = [], valid = true
        incoming.enumerateAttribute(.link, in: full) { value, range, _ in
            storage.enumerateAttribute(.link, in: range) { old, part, _ in
                let newReference = ProjectTagReference.from(value), oldReference = ProjectTagReference.from(old)
                if oldReference != nil, oldReference == newReference { return }
                if old == nil, value == nil { return }
                if let old = old as? NSObject, let value = value as? NSObject, old.isEqual(value) { return }
                if old == nil, let newReference { additions.append((part, newReference)) }
                else { valid = false }
            }
        }
        guard valid else { return false }
        let selection = selectedRanges, typing = typingAttributes
        breakUndoCoalescing(); undoManager?.beginUndoGrouping()
        for (range, reference) in additions where shouldChangeText(in: range, replacementString: nil) {
            storage.addAttribute(.link, value: reference.url, range: range)
        }
        selectedRanges = selection; typingAttributes = typing
        undoManager?.setActionName("Link existing mentions"); undoManager?.endUndoGrouping()
        return true
    }

    private var tagBoundaryEdit: (range: NSRange, reference: ProjectTagReference)?
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typing arrives here on every macOS version; pasting, undo, and programmatic edits do not.
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let target = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        super.insertText(string, replacementRange: replacementRange)
        // A single space or punctuation mark typed at the caret may complete a known name.
        if target.length == 0, ObjectTags.isNameBoundary(typed), !hasMarkedText(),
           selectedRange() == NSRange(location: target.location + typed.utf16.count, length: 0) {
            tagSession?.autoTagName(endingAt: target.location)
        }
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        tagBoundaryEdit = nil
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed, tagSession?.inserting != true, affectedCharRange.length == 0, affectedCharRange.location > 0,
           let replacementString, !replacementString.isEmpty, let storage = textStorage,
           affectedCharRange.location <= storage.length,
           let reference = ProjectTagReference.from(storage.attribute(.link, at: affectedCharRange.location - 1, effectiveRange: nil)),
           affectedCharRange.location == storage.length || ProjectTagReference.from(storage.attribute(.link, at: affectedCharRange.location, effectiveRange: nil)) != reference {
            tagBoundaryEdit = (NSRange(location: affectedCharRange.location, length: replacementString.utf16.count), reference)
        }
        return allowed
    }
    override func didChangeText() {
        selectionActions?.close()
        tagSession?.closeDetails()
        if let edit = tagBoundaryEdit, let storage = textStorage, NSMaxRange(edit.range) <= storage.length {
            var ranges: [NSRange] = []
            storage.enumerateAttribute(.link, in: edit.range) { value, range, _ in
                if ProjectTagReference.from(value) == edit.reference { ranges.append(range) }
            }
            for range in ranges { storage.removeAttribute(.link, range: range) }
        }
        tagBoundaryEdit = nil
        pencilComments?.invalidate()
        super.didChangeText()
    }
    override func mouseDown(with event: NSEvent) {
        selectionActions?.close()
        let point = convert(event.locationInWindow, from: nil)
        tagSession?.close()
        objectNames?.close()
        if let session = grammarSession, let correction = session.correction(at: point) { session.show(correction); return }
        if let session = objectNames, let candidate = session.candidate(at: point) { session.show(candidate); return }
        if event.modifierFlags.contains(.command), event.clickCount == 1, let session = tagSession, session.showDetails(at: point) { return }
        super.mouseDown(with: event)
        selectionActions?.selectionChanged()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, selectionActions?.visible == true { selectionActions?.close(); return }
        selectionActions?.close()
        if tagSession?.handleKey(event) == true { return }
        tagSession?.closeDetails()
        if tagSession?.completion != nil, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 48, tagSession?.acceptCompletion() == true { return }
            if event.keyCode == 53 { tagSession?.dismissCompletion(); return }
        }
        super.keyDown(with: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { selectionActions?.close(); tagSession?.close(); objectNames?.cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
    @objc func toggleBoldface(_ sender: Any?) { toggleTrait(.boldFontMask) }
    @objc func toggleItalics(_ sender: Any?) { toggleTrait(.italicFontMask) }
    private func toggleTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        let attrs = range.location < (textStorage?.length ?? 0) ? textStorage?.attributes(at: range.location, effectiveRange: nil) ?? typingAttributes : typingAttributes
        let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 18)
        let remove = NSFontManager.shared.traits(of: font).contains(trait)
        func converted(_ font: NSFont) -> NSFont { remove ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait) }
        if range.length > 0, let storage = textStorage, shouldChangeText(in: range, replacementString: nil) {
            var updates: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: range) { value, part, _ in updates.append((part, converted(value as? NSFont ?? font))) }
            for (part, changed) in updates { storage.addAttribute(.font, value: changed, range: part) }
            didChangeText()
        }
        if range.length == 0 { typingAttributes[.font] = converted(font) }
    }
    override func layout() {
        super.layout()
        // Use the available sheet width, with modest margins even on large displays.
        let margin: CGFloat = usesManuscriptMargins ? paperMargins.horizontal(for: bounds.width) : 8
        pencilColumnWidth = PencilComments.columnWidth(pageWidth: bounds.width, margin: margin, hasNotes: pencilComments?.attached.isEmpty == false)
        let inset = NSSize(width: margin + pencilColumnWidth / 2, height: usesManuscriptMargins ? paperMargins.vertical : 4)
        if textContainerInset != inset { textContainerInset = inset }
        pencilComments?.layout()
    }
}

struct RichTextEditor: NSViewRepresentable {
    var typingPreferences = TypingPreferences()
    @AppStorage("discoverObjectNames") private var discoverNames = true
    @Environment(\.appContextCommands) private var appCommands
    @Environment(\.chapterContextCommands) private var chapterCommands
    @Environment(\.changePassageComment) private var changeComment
    @AppStorage("showPencilComments") private var showPencilComments = true
    @Environment(\.reviewFocus) private var reviewFocus
    @Environment(\.writingReviewContext) private var writingContext
    @Environment(\.storyDestination) private var destination
    @AppStorage("paperMargins") private var margins = PaperMargins.balanced.rawValue
    @AppStorage("selectionQuickActions") private var quickActions = true
    @AppStorage("defaultFontName") private var defaultFont = "Georgia"
    @AppStorage("defaultFontSize") private var defaultSize = 18.0
    @AppStorage("defaultLineSpacing") private var defaultSpacing = 6.0
    @AppStorage("readingZoom") private var readingZoom = 1.0
    @AppStorage("dimPaper") private var dimPaper = false
    @AppStorage("showTagHighlights") private var showTags = true
    @AppStorage("autoTagNames") private var autoTagNames = true
    @AppStorage("completeNames") private var completeNames = true
    @Environment(\.tagObjects) private var objects
    @Environment(\.openObjectTag) private var openTag
    @Environment(\.createProjectObject) private var createObject
    @Environment(\.ignoredObjectNames) private var ignoredNames
    @Environment(\.ignoreObjectName) private var ignoreName
    @Binding var chapter: Chapter
    @ObservedObject var controller: EditorController
    var language: String
    var onError: (String) -> Void

    private var typographyKey: String { "\(defaultFont)/\(defaultSize)/\(defaultSpacing)" }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.updatingView = true
        defer { context.coordinator.updatingView = false }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true; scroll.minMagnification = 0.75; scroll.maxMagnification = 1.5
        let storage = NSTextStorage()
        let manager = ManuscriptLayoutManager(); manager.showsTags = showTags; manager.dimsText = dimPaper; storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; manager.addTextContainer(container)
        let view = ManuscriptTextView(frame: .zero, textContainer: container)
        view.contextEditor = controller; view.appContextCommands = appCommands
        view.chapterContextCommands = { range, text in chapterCommands(chapter.id, range, text) }
        view.isRichText = true; view.importsGraphics = true; view.allowsUndo = true
        view.isEditable = true; view.isSelectable = true; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 28, height: 36)
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = ManuscriptPaper.color; view.insertionPointColor = .black; view.drawsBackground = false
        view.usesFontPanel = true; view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.linkTextAttributes = [:] // Tags and links are drawn by ManuscriptLayoutManager.
        typingPreferences.apply(to: view)
        view.textStorage?.setAttributedString(chapter.attributedText); view.typingAttributes = WritingStyle.attributes
        context.coordinator.typographyKey = typographyKey
        let pencil = PencilCommentLayer(view: view); view.pencilComments = pencil
        pencil.update(chapter.comments ?? [], enabled: showPencilComments, change: { changeComment(chapter.id, $0, $1) })
        view.delegate = context.coordinator; context.coordinator.lastData = chapter.richText
        let grammar = InlineGrammarSession(view: view, documentLabel: "chapter", documentKey: writingContext.storageKey("\(chapter.id.uuidString)/body"), context: writingContext); view.grammarSession = grammar; grammar.drawMarks()
        let tags = ObjectTagSession(view: view); tags.objects = objects; tags.open = openTag; tags.create = createObject; tags.ignoreName = ignoreName; tags.autoTagsNames = autoTagNames; tags.completionsEnabled = completeNames; view.tagSession = tags
        let names = ObjectNameSession(view: view); view.objectNames = names
        names.configure(objects: objects, ignored: ignoredNames, create: createObject, ignore: ignoreName, enabled: discoverNames); names.textChanged()
        view.onFocus = { [weak reviewFocus] in reviewFocus?.activate(nil) }
        controller.textView = view; controller.chapterID = chapter.id
        DispatchQueue.main.async { controller.grammar = grammar; controller.tags = tags; controller.objectNames = names; controller.refresh() }
        scroll.documentView = view
        view.selectionActions = SelectionQuickActionSession(view: view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        // The representable starts at zero size. Position the new chapter after
        // SwiftUI has sized the paper, rather than inheriting the clip's bottom edge.
        DispatchQueue.main.async {
            view.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.updatingView = true
        defer { context.coordinator.updatingView = false }
        typingPreferences.apply(to: view)
        if let manuscript = view as? ManuscriptTextView {
            let paperMargins = PaperMargins(rawValue: margins) ?? .balanced
            if manuscript.paperMargins != paperMargins {
                manuscript.paperMargins = paperMargins
                manuscript.needsLayout = true
            }
            if !quickActions { manuscript.selectionActions?.close() }
            if let manager = manuscript.layoutManager as? ManuscriptLayoutManager, manager.showsTags != showTags {
                manager.showsTags = showTags; manuscript.needsDisplay = true
            }
        }
        if context.coordinator.typographyKey != typographyKey {
            context.coordinator.typographyKey = typographyKey
            if view.string.isEmpty { view.typingAttributes = WritingStyle.attributes }
        }
        (view as? ManuscriptTextView)?.contextEditor = controller
        (view as? ManuscriptTextView)?.appContextCommands = appCommands
        (view as? ManuscriptTextView)?.chapterContextCommands = { range, text in chapterCommands(chapter.id, range, text) }
        (view as? ManuscriptTextView)?.grammarSession?.context = writingContext
        (view as? ManuscriptTextView)?.tagSession?.objects = objects
        (view as? ManuscriptTextView)?.tagSession?.open = openTag
        (view as? ManuscriptTextView)?.tagSession?.create = createObject
        (view as? ManuscriptTextView)?.tagSession?.ignoreName = ignoreName
        (view as? ManuscriptTextView)?.tagSession?.autoTagsNames = autoTagNames
        (view as? ManuscriptTextView)?.tagSession?.completionsEnabled = completeNames
        (view as? ManuscriptTextView)?.objectNames?.configure(objects: objects, ignored: ignoredNames, create: createObject, ignore: ignoreName, enabled: discoverNames)
        (view as? ManuscriptTextView)?.onFocus = { [weak reviewFocus] in reviewFocus?.activate(nil) }
        controller.textView = view; controller.chapterID = chapter.id
        let changedChapter = context.coordinator.chapterID != chapter.id
        let replacedText = changedChapter || context.coordinator.lastData != chapter.richText
        context.coordinator.chapterID = chapter.id
        if replacedText {
            let selected = view.selectedRange()
            (view as? ManuscriptTextView)?.selectionActions?.close()
            (view as? ManuscriptTextView)?.tagSession?.close()
            let incoming = chapter.attributedText
            if changedChapter || (view as? ManuscriptTextView)?.mergeAddedObjectTags(from: incoming) != true {
                view.textStorage?.setAttributedString(incoming)
                view.setSelectedRange(NSRange(location: changedChapter ? 0 : min(selected.location, view.string.utf16.count), length: 0))
                view.undoManager?.removeAllActions()
            }
            context.coordinator.lastData = chapter.richText
            (view as? ManuscriptTextView)?.grammarSession?.textChanged(automatic: false)
            (view as? ManuscriptTextView)?.objectNames?.textChanged()
            (view as? ManuscriptTextView)?.pencilComments?.invalidate()
            DispatchQueue.main.async { controller.refresh() }
        }
        (view as? ManuscriptTextView)?.selectionActions?.refreshContent()
        (view as? ManuscriptTextView)?.pencilComments?.update(chapter.comments ?? [], enabled: showPencilComments, change: { changeComment(chapter.id, $0, $1) })
        if let id = controller.pendingCommentFocus {
            DispatchQueue.main.async {
                guard controller.pendingCommentFocus == id else { return }
                view.layoutSubtreeIfNeeded()
                if let note = (view as? ManuscriptTextView)?.pencilComments?.notes.first(where: { $0.comment.id == id }) {
                    note.scrollToVisible(note.bounds); view.window?.makeFirstResponder(note.editor)
                    controller.pendingCommentFocus = nil
                }
            }
        }
        if abs(scroll.magnification - readingZoom) > 0.001 { scroll.setMagnification(readingZoom, centeredAt: scroll.contentView.bounds.origin) }
        scroll.appearance = NSAppearance(named: dimPaper ? .darkAqua : .aqua)
        view.appearance = scroll.appearance
        view.insertionPointColor = dimPaper ? .white : .black
        if let manager = view.layoutManager as? ManuscriptLayoutManager, manager.dimsText != dimPaper {
            manager.dimsText = dimPaper; view.needsDisplay = true
        }
        if let destination, destination.kind == .chapter, destination.itemID == chapter.id, destination.field == "body", context.coordinator.navigationToken != destination.token {
            context.coordinator.navigationToken = destination.token
            DispatchQueue.main.async { EditorNavigation.select(destination, in: view) }
        }
        if context.coordinator.spellingLanguage != language {
            context.coordinator.spellingLanguage = language
            let checker = NSSpellChecker.shared
            checker.automaticallyIdentifiesLanguages = language == "auto"
            if language != "auto" { _ = checker.setLanguage(language == "de" ? "de_DE" : "en_US") }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var typographyKey = ""
        var parent: RichTextEditor
        var lastData = ChapterText()
        var navigationToken: UUID?
        var chapterID: UUID
        var spellingLanguage: String?
        var updatingView = false
        init(_ parent: RichTextEditor) { self.parent = parent; chapterID = parent.chapter.id }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            var changed = parent.chapter
            changed.setEditingText(view.attributedString())
            lastData = changed.richText; parent.chapter = changed
            parent.controller.refresh(whileTyping: true)
            (view as? ManuscriptTextView)?.grammarSession?.textChanged(text: changed.plainText)
            (view as? ManuscriptTextView)?.tagSession?.refreshSuggestions()
            (view as? ManuscriptTextView)?.tagSession?.refreshCompletion()
            (view as? ManuscriptTextView)?.objectNames?.textChanged(text: changed.plainText)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if updatingView {
                DispatchQueue.main.async { self.parent.controller.refresh() }
                return
            }
            parent.controller.refresh()
            (notification.object as? ManuscriptTextView)?.selectionActions?.selectionChanged()
            if let view = notification.object as? ManuscriptTextView, view.tagSession?.visible == true { view.tagSession?.refreshSuggestions() }
            (notification.object as? ManuscriptTextView)?.tagSession?.refreshCompletion()
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard ProjectTagReference.from(link) != nil else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                (textView as? ManuscriptTextView)?.tagSession?.showDetails(atCharacter: charIndex); return true
            }
            // Tagged words edit like ordinary prose; ⌘-click shows their details.
            var caret = charIndex
            if let event = NSApp.currentEvent, event.window === textView.window, event.type == .leftMouseUp || event.type == .leftMouseDown {
                caret = textView.characterIndexForInsertion(at: textView.convert(event.locationInWindow, from: nil))
            }
            textView.setSelectedRange(NSRange(location: min(caret, textView.string.utf16.count), length: 0))
            return true
        }
    }
}

struct FormattingBar: View {
    @ObservedObject var editor: EditorController
    var compact = false
    @State private var showLink = false
    @State private var link = ""
    @Environment(\.tagObjects) private var objects
    var body: some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(["Georgia", "Helvetica", "Times New Roman", "Avenir Next", "Menlo"], id: \.self) { font in
                    Button { editor.setFont(name: font) } label: {
                        if editor.fontName == font { Label(font, systemImage: "checkmark") }
                        else { Text(font) }
                    }
                }
                Divider()
                Button("All fonts…") { editor.textView?.window?.makeFirstResponder(editor.textView); NSFontManager.shared.orderFrontFontPanel(nil) }
            } label: { Text(editor.fontName).lineLimit(1).frame(width: 92, alignment: .leading) }
            .menuStyle(.borderlessButton).tint(.primary).help("Font family")
            Stepper(value: Binding(get: { editor.fontSize }, set: { editor.setFont(size: $0) }), in: 8...72, step: 1) { Text("\(Int(editor.fontSize))").monospacedDigit().frame(width: 24) }
                .frame(width: 66).help("Font size").accessibilityLabel("Font size")
            Divider().frame(height: 18)
            HStack(spacing: 2) {
                formatButton("bold", help: "Bold · ⌘B", active: editor.isBold) { editor.action(#selector(ManuscriptTextView.toggleBoldface(_:))) }
                formatButton("italic", help: "Italic · ⌘I", active: editor.isItalic) { editor.action(#selector(ManuscriptTextView.toggleItalics(_:))) }
                formatButton("underline", help: "Underline · ⌘U", active: editor.isUnderlined) { editor.action(#selector(NSTextView.underline(_:))) }
            }
            Menu {
                Button("Body") {
                    let preferences = ApplicationPreferences()
                    editor.setFont(name: preferences.defaultFont.fontName, size: preferences.defaultFont.pointSize)
                    editor.paragraphSpacing(preferences.defaultLineSpacing)
                }
                Button("Heading 1") { editor.setFont(name: "Georgia-Bold", size: 30) }
                Button("Heading 2") { editor.setFont(name: "Georgia-Bold", size: 24) }
                Button("Caption") { editor.setFont(name: "Helvetica", size: 12) }
            } label: { WriterMenuLabel(title: "Style", symbol: "textformat.size", compact: compact, showsSymbol: false) }
                .menuStyle(.borderlessButton).tint(.primary).fixedSize().help("Body text, headings, and captions")
            Menu {
                Menu("Alignment") {
                    alignmentButton("Left", value: .left, selector: #selector(NSTextView.alignLeft(_:)))
                    alignmentButton("Center", value: .center, selector: #selector(NSTextView.alignCenter(_:)))
                    alignmentButton("Right", value: .right, selector: #selector(NSTextView.alignRight(_:)))
                    alignmentButton("Justified", value: .justified, selector: #selector(NSTextView.alignJustified(_:)))
                }
                Menu("Line spacing") {
                    spacingButton("Compact", value: 2)
                    spacingButton("Comfortable", value: 6)
                    spacingButton("Spacious", value: 12)
                }
                Divider()
                Button { editor.bulletList() } label: { Label("Bulleted list", systemImage: "list.bullet") }
                Button { editor.bulletList(numbered: true) } label: { Label("Numbered list", systemImage: "list.number") }
            } label: { WriterMenuLabel(title: "Paragraph", symbol: "text.alignleft", compact: compact, showsSymbol: false) }
                .menuStyle(.borderlessButton).tint(.primary).fixedSize().help("Alignment, spacing, and lists")
            Divider().frame(height: 18)
            Menu {
                Menu("Character & world tag") {
                    Button("Browse objects…") { editor.tags?.browse() }
                    Divider()
                    ForEach(ObjectTags.groupOrder, id: \.self) { group in
                        let members = ObjectTags.matches(objects.filter { $0.group == group }, query: "")
                        if !members.isEmpty { Menu(group) { ForEach(members) { object in Button(object.title) { editor.tags?.insert(object) } } } }
                    }
                    if objects.isEmpty { Button("Add characters or world entries first") {}.disabled(true) }
                    Divider()
                    Button("Remove tag") { editor.tags?.removeSelectedTag() }.disabled(!editor.selectionContainsAttribute(.link, matching: { ProjectTagReference.from($0) != nil }))
                }
                Divider()
                Button { link = ""; showLink = true } label: { Label("Add web link…", systemImage: "link") }.disabled(editor.selectionText.isEmpty)
                Button("Remove web link") { editor.removeWebLinks() }.disabled(!editor.selectionContainsAttribute(.link, matching: { ProjectTagReference.from($0) == nil }))
            } label: { WriterMenuLabel(title: "Insert", symbol: "plus.circle", compact: compact, showsSymbol: false) }
                .menuStyle(.borderlessButton).tint(.primary).fixedSize().help("Character and world tags, and web links · known names are tagged as you type, or type @ to choose")
                .popover(isPresented: $showLink) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Link selected text").font(.headline)
                        TextField("https://…", text: $link).textFieldStyle(.roundedBorder).frame(width: 300)
                        Button("Add link") {
                            let value = link.contains(":") ? link : "https://\(link)"
                            if let url = URL(string: value), ["http", "https", "mailto"].contains(url.scheme ?? "") { editor.setAttributes([.link: url]); showLink = false }
                        }.disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(20)
                }
            Menu {
                Button { editor.strikeThrough() } label: { Label("Strikethrough", systemImage: "strikethrough") }
                Menu("Text color") {
                    Button("Black") { editor.setAttributes([.foregroundColor: NSColor.black]) }
                    Button("Green") { editor.setAttributes([.foregroundColor: NSColor(srgbRed: 0.20, green: 0.43, blue: 0.36, alpha: 1)]) }
                    Button("Red") { editor.setAttributes([.foregroundColor: NSColor.systemRed]) }
                    Button("Gray") { editor.setAttributes([.foregroundColor: NSColor.gray]) }
                }
                Divider()
                Button { editor.setAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)]) } label: { Label("Highlight", systemImage: "highlighter") }
                Button("Remove highlight") { editor.setAttributes([.backgroundColor: NSColor.clear]) }.disabled(!editor.selectionContainsAttribute(.backgroundColor, matching: { (($0 as? NSColor)?.alphaComponent ?? 0) > 0 }))
            } label: { WriterMenuLabel(title: "Format", symbol: "paintbrush", compact: compact, showsSymbol: false) }
                .menuStyle(.borderlessButton).tint(.primary).fixedSize().help("Strikethrough, text color, and highlighting")
            Spacer(minLength: 0)
            Button { editor.find() } label: { Image(systemName: "magnifyingglass").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Find in chapter · ⌘F").accessibilityLabel("Find in chapter")
        }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 7)
    }
    private func alignmentButton(_ title: String, value: NSTextAlignment, selector: Selector) -> some View {
        Button { editor.action(selector) } label: {
            if editor.alignment == value { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
    private func spacingButton(_ title: String, value: CGFloat) -> some View {
        Button { editor.paragraphSpacing(value) } label: {
            if abs(editor.lineSpacing - value) < 0.01 { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
    private func formatButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 25, height: 24).background(active ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help).accessibilityValue(active ? "On" : "Off")
    }
}
