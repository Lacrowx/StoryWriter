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
    @Published var selectionText = ""
    @Published var selectionRange = NSRange(location: 0, length: 0)
    @Published var grammar: InlineGrammarSession?
    @Published var tags: ObjectTagSession?
    @Published var objectNames: ObjectNameSession?
    @Published var pendingCommentFocus: UUID?

    func refresh() {
        guard let view = textView else { return }
        let range = view.selectedRange()
        selectionRange = range
        grammar?.selectionChanged()
        if NSMaxRange(range) <= (view.string as NSString).length {
            selectionText = (view.string as NSString).substring(with: range)
            selectionWords = selectionText.wordCount
        }
        let attributes = range.location < view.textStorage?.length ?? 0 ? view.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? view.typingAttributes : view.typingAttributes
        if let font = attributes[.font] as? NSFont {
            fontName = font.familyName ?? "Georgia"; fontSize = Double(font.pointSize)
            let traits = NSFontManager.shared.traits(of: font)
            isBold = traits.contains(.boldFontMask); isItalic = traits.contains(.italicFontMask)
        }
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
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
        view.window?.makeFirstResponder(view)
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
    }
    var grammarSession: InlineGrammarSession?
    var tagSession: ObjectTagSession?
    var objectNames: ObjectNameSession?
    var usesManuscriptMargins = true
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
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
        if result { onBlur?() }
        return result
    }
    private var tagBoundaryEdit: (range: NSRange, reference: ProjectTagReference)?
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
        let point = convert(event.locationInWindow, from: nil)
        tagSession?.close()
        objectNames?.close()
        if let session = grammarSession, let correction = session.correction(at: point) { session.show(correction); return }
        if let session = objectNames, let candidate = session.candidate(at: point) { session.show(candidate); return }
        if !event.modifierFlags.contains(.option), event.clickCount == 1, let session = tagSession, session.showDetails(at: point) { return }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if tagSession?.handleKey(event) == true { return }
        tagSession?.closeDetails()
        super.keyDown(with: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { tagSession?.close(); objectNames?.cancel() }
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
        let margin: CGFloat = usesManuscriptMargins ? min(64, max(28, bounds.width * 0.045)) : 8
        pencilColumnWidth = PencilComments.columnWidth(pageWidth: bounds.width, margin: margin, hasNotes: pencilComments?.attached.isEmpty == false)
        let inset = NSSize(width: margin + pencilColumnWidth / 2, height: usesManuscriptMargins ? 36 : 4)
        if textContainerInset != inset { textContainerInset = inset }
        pencilComments?.layout()
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Environment(\.appContextCommands) private var appCommands
    @Environment(\.chapterContextCommands) private var chapterCommands
    @Environment(\.changePassageComment) private var changeComment
    @AppStorage("showPencilComments") private var showPencilComments = true
    @Environment(\.reviewFocus) private var reviewFocus
    @Environment(\.writingReviewContext) private var writingContext
    @Environment(\.storyDestination) private var destination
    @AppStorage("readingZoom") private var readingZoom = 1.0
    @AppStorage("dimPaper") private var dimPaper = false
    @Environment(\.tagObjects) private var objects
    @Environment(\.openObjectTag) private var openTag
    @Environment(\.createProjectObject) private var createObject
    @Environment(\.ignoredObjectNames) private var ignoredNames
    @Environment(\.ignoreObjectName) private var ignoreName
    @Binding var chapter: Chapter
    @ObservedObject var controller: EditorController
    var language: String
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true; scroll.minMagnification = 0.75; scroll.maxMagnification = 1.5
        let storage = NSTextStorage()
        let manager = NSLayoutManager(); storage.addLayoutManager(manager)
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
        view.isContinuousSpellCheckingEnabled = true; view.isGrammarCheckingEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = true; view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.textStorage?.setAttributedString(chapter.attributedText); view.typingAttributes = WritingStyle.attributes
        let pencil = PencilCommentLayer(view: view); view.pencilComments = pencil
        pencil.update(chapter.comments ?? [], enabled: showPencilComments, change: { changeComment(chapter.id, $0, $1) })
        view.delegate = context.coordinator; context.coordinator.lastData = chapter.richText
        let grammar = InlineGrammarSession(view: view, documentLabel: "chapter", documentKey: writingContext.storageKey("\(chapter.id.uuidString)/body"), context: writingContext); view.grammarSession = grammar; grammar.drawMarks()
        let tags = ObjectTagSession(view: view); tags.objects = objects; tags.open = openTag; tags.create = createObject; tags.ignoreName = ignoreName; view.tagSession = tags
        let names = ObjectNameSession(view: view); view.objectNames = names
        names.configure(objects: objects, ignored: ignoredNames, create: createObject, ignore: ignoreName); names.textChanged()
        view.onFocus = { [weak reviewFocus] in reviewFocus?.activate(nil) }
        controller.textView = view; controller.chapterID = chapter.id
        DispatchQueue.main.async { controller.grammar = grammar; controller.tags = tags; controller.objectNames = names }
        scroll.documentView = view
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
        (view as? ManuscriptTextView)?.contextEditor = controller
        (view as? ManuscriptTextView)?.appContextCommands = appCommands
        (view as? ManuscriptTextView)?.chapterContextCommands = { range, text in chapterCommands(chapter.id, range, text) }
        (view as? ManuscriptTextView)?.grammarSession?.context = writingContext
        (view as? ManuscriptTextView)?.tagSession?.objects = objects
        (view as? ManuscriptTextView)?.tagSession?.open = openTag
        (view as? ManuscriptTextView)?.tagSession?.create = createObject
        (view as? ManuscriptTextView)?.tagSession?.ignoreName = ignoreName
        (view as? ManuscriptTextView)?.objectNames?.configure(objects: objects, ignored: ignoredNames, create: createObject, ignore: ignoreName)
        (view as? ManuscriptTextView)?.onFocus = { [weak reviewFocus] in reviewFocus?.activate(nil) }
        controller.textView = view; controller.chapterID = chapter.id
        if context.coordinator.lastData != chapter.richText {
            let selected = view.selectedRange()
            (view as? ManuscriptTextView)?.tagSession?.close()
            view.textStorage?.setAttributedString(chapter.attributedText)
            view.setSelectedRange(NSRange(location: min(selected.location, view.string.utf16.count), length: 0))
            view.undoManager?.removeAllActions()
            context.coordinator.lastData = chapter.richText
            (view as? ManuscriptTextView)?.grammarSession?.textChanged(automatic: false)
            (view as? ManuscriptTextView)?.objectNames?.textChanged()
            (view as? ManuscriptTextView)?.pencilComments?.invalidate()
        }
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
        // Display colors are temporary layout attributes, excluded from saved text and exports.
        if let manager = view.layoutManager, let storage = view.textStorage {
            let all = NSRange(location: 0, length: storage.length)
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            if dimPaper {
                storage.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
                    let color = (value as? NSColor)?.usingColorSpace(.deviceRGB)
                    if color == nil || ((color?.redComponent ?? 0) + (color?.greenComponent ?? 0) + (color?.blueComponent ?? 0)) < 1.1 {
                        manager.addTemporaryAttribute(.foregroundColor, value: NSColor(srgbRed: 0.87, green: 0.86, blue: 0.83, alpha: 1), forCharacterRange: range)
                    }
                }
            }
        }
        if let destination, destination.kind == .chapter, destination.itemID == chapter.id, destination.field == "body", context.coordinator.navigationToken != destination.token {
            context.coordinator.navigationToken = destination.token
            DispatchQueue.main.async { EditorNavigation.select(destination, in: view) }
        }
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = language == "auto"
        if language != "auto" { _ = checker.setLanguage(language == "de" ? "de_DE" : "en_US") }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastData = Data()
        var navigationToken: UUID?
        init(_ parent: RichTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            do {
                var changed = parent.chapter
                try changed.setText(view.attributedString())
                lastData = changed.richText; parent.chapter = changed
                parent.controller.refresh()
                (view as? ManuscriptTextView)?.grammarSession?.textChanged()
                (view as? ManuscriptTextView)?.tagSession?.refreshSuggestions()
                (view as? ManuscriptTextView)?.objectNames?.textChanged()
            } catch { parent.onError("Could not preserve text formatting: \(error.localizedDescription)") }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.refresh()
            if let view = notification.object as? ManuscriptTextView, view.tagSession?.visible == true { view.tagSession?.refreshSuggestions() }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard ProjectTagReference.from(link) != nil else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true { return true }
            (textView as? ManuscriptTextView)?.tagSession?.showDetails(atCharacter: charIndex); return true
        }
    }
}

struct FormattingBar: View {
    @ObservedObject var editor: EditorController
    @State private var showLink = false
    @State private var link = ""
    @Environment(\.tagObjects) private var objects
    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(["Georgia", "Helvetica", "Times New Roman", "Avenir Next", "Menlo"], id: \.self) { font in Button(font) { editor.setFont(name: font) } }
                Divider()
                Button("All fonts…") { editor.textView?.window?.makeFirstResponder(editor.textView); NSFontManager.shared.orderFrontFontPanel(nil) }
            } label: { Text(editor.fontName).frame(width: 105, alignment: .leading) }
            .menuStyle(.borderlessButton)
            Stepper(value: Binding(get: { editor.fontSize }, set: { editor.setFont(size: $0) }), in: 8...72, step: 1) { Text("\(Int(editor.fontSize))").monospacedDigit().frame(width: 24) }.frame(width: 66)
            Divider().frame(height: 18)
            formatButton("bold", help: "Bold · ⌘B", active: editor.isBold) { editor.action(#selector(ManuscriptTextView.toggleBoldface(_:))) }
            formatButton("italic", help: "Italic · ⌘I", active: editor.isItalic) { editor.action(#selector(ManuscriptTextView.toggleItalics(_:))) }
            formatButton("underline", help: "Underline · ⌘U", active: editor.isUnderlined) { editor.action(#selector(NSTextView.underline(_:))) }
            Menu {
                Button("Left") { editor.action(#selector(NSTextView.alignLeft(_:))) }
                Button("Center") { editor.action(#selector(NSTextView.alignCenter(_:))) }
                Button("Right") { editor.action(#selector(NSTextView.alignRight(_:))) }
                Button("Justified") { editor.action(#selector(NSTextView.alignJustified(_:))) }
            } label: { Image(systemName: "text.alignleft") }.menuStyle(.borderlessButton).frame(width: 26)
            formatButton("list.bullet", help: "Bulleted list") { editor.bulletList() }
            Menu {
                Button("Compact") { editor.paragraphSpacing(2) }
                Button("Comfortable") { editor.paragraphSpacing(6) }
                Button("Spacious") { editor.paragraphSpacing(12) }
            } label: { Image(systemName: "line.3.horizontal") }.menuStyle(.borderlessButton).frame(width: 26).help("Line spacing")
            Menu {
                Button("Body") { editor.setFont(name: "Georgia", size: 18) }
                Button("Heading 1") { editor.setFont(name: "Georgia-Bold", size: 30) }
                Button("Heading 2") { editor.setFont(name: "Georgia-Bold", size: 24) }
                Button("Caption") { editor.setFont(name: "Helvetica", size: 12) }
            } label: { Image(systemName: "textformat.size") }.menuStyle(.borderlessButton).frame(width: 28).help("Text style")
            Menu {
                Button("Numbered list") { editor.bulletList(numbered: true) }
                Button("Strikethrough") { editor.strikeThrough() }
                Button("Add link…") { link = ""; showLink = true }.disabled(editor.selectionText.isEmpty)
                Button("Remove link") { editor.setAttributes([.link: ""]) }
                Divider()
                Menu("Text color") {
                    Button("Black") { editor.setAttributes([.foregroundColor: NSColor.black]) }
                    Button("Green") { editor.setAttributes([.foregroundColor: NSColor(srgbRed: 0.20, green: 0.43, blue: 0.36, alpha: 1)]) }
                    Button("Red") { editor.setAttributes([.foregroundColor: NSColor.systemRed]) }
                    Button("Gray") { editor.setAttributes([.foregroundColor: NSColor.gray]) }
                }
                Button("Highlight") { editor.setAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)]) }
                Button("Remove highlight") { editor.setAttributes([.backgroundColor: NSColor.clear]) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).help("Links, color, and more formatting")
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
                Button("Browse objects…") { editor.tags?.browse() }
                Divider()
                ForEach(ObjectTags.groupOrder, id: \.self) { group in
                    let members = ObjectTags.matches(objects.filter { $0.group == group }, query: "")
                    if !members.isEmpty { Menu(group) { ForEach(members) { object in Button(object.title) { editor.tags?.insert(object) } } } }
                }
                if objects.isEmpty { Text("Add characters or world entries first") }
                Divider()
                Button("Remove tag from selection") { editor.tags?.removeSelectedTag() }
            } label: { Image(systemName: "tag") }.menuStyle(.borderlessButton).frame(width: 24).help("Tag a character, location, item or world entry · type @ to search. Select existing text to tag it.")
            Spacer(minLength: 0)
            Button { editor.find() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).help("Find in chapter · ⌘F")
        }
        .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 10)
    }
    private func formatButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 25, height: 24).background(active ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help(help)
    }
}
