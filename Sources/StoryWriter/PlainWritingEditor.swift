import AppKit
import SwiftUI

struct PlainWritingEditor: NSViewRepresentable {
    @Environment(\.appContextCommands) private var appCommands
    @Environment(\.reviewFocus) private var reviewFocus
    @Environment(\.storyDestination) private var destination
    @Environment(\.writingReviewContext) private var writingContext
    @Environment(\.tagObjects) private var objects
    @Environment(\.createProjectObject) private var createObject
    @Environment(\.ignoredObjectNames) private var ignoredNames
    @Environment(\.ignoreObjectName) private var ignoreName
    @Binding var text: String
    @ObservedObject var controller: EditorController
    var fontSize: CGFloat = 14
    var label = "note"
    var documentKey: String
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = ManuscriptTextView(frame: .zero)
        view.contextEditor = controller; view.appContextCommands = appCommands
        view.usesManuscriptMargins = false
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.isEditable = true; view.isSelectable = true; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 8, height: 4)
        view.font = .systemFont(ofSize: fontSize); view.textColor = .textColor; view.backgroundColor = .textBackgroundColor; view.drawsBackground = false
        view.isContinuousSpellCheckingEnabled = true; view.isGrammarCheckingEnabled = true; view.usesFindBar = true
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = true; view.isAutomaticDashSubstitutionEnabled = true
        view.string = text; view.delegate = context.coordinator; context.coordinator.lastText = text
        var reviewContext = writingContext; reviewContext.document = label
        let session = InlineGrammarSession(view: view, documentLabel: label, documentKey: writingContext.storageKey(documentKey), context: reviewContext); view.grammarSession = session; session.drawMarks()
        let names = ObjectNameSession(view: view); view.objectNames = names
        names.configure(objects: objects, ignored: ignoredNames, create: createObject, ignore: ignoreName); names.textChanged()
        controller.textView = view
        view.onFocus = { [weak controller, weak reviewFocus] in controller?.fieldFocused = true; reviewFocus?.activate(session) }
        view.onBlur = { [weak controller] in controller?.fieldFocused = false }
        DispatchQueue.main.async { controller.grammar = session; controller.objectNames = names }
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ManuscriptTextView else { return }
        view.contextEditor = controller; view.appContextCommands = appCommands
        var reviewContext = writingContext; reviewContext.document = label
        view.grammarSession?.context = reviewContext
        view.objectNames?.configure(objects: objects, ignored: ignoredNames, create: createObject, ignore: ignoreName)
        view.onFocus = { [weak view, weak reviewFocus, weak controller] in controller?.fieldFocused = true; reviewFocus?.activate(view?.grammarSession) }
        view.onBlur = { [weak controller] in controller?.fieldFocused = false }
        if let destination, destination.field == label,
           documentKey.contains(destination.itemID.uuidString), context.coordinator.navigationToken != destination.token {
            context.coordinator.navigationToken = destination.token
            DispatchQueue.main.async { EditorNavigation.select(destination, in: view) }
        }
        let language = LocalGrammarService.shared.language
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = language == "auto"
        if language != "auto" { _ = NSSpellChecker.shared.setLanguage(language == "de" ? "de_DE" : "en_US") }
        if context.coordinator.lastText != text {
            let selection = view.selectedRange()
            view.string = text; context.coordinator.lastText = text
            view.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            view.undoManager?.removeAllActions(); view.grammarSession?.textChanged(automatic: false)
            view.objectNames?.textChanged()
        }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainWritingEditor
        var lastText = ""
        var navigationToken: UUID?
        init(_ parent: PlainWritingEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ManuscriptTextView else { return }
            lastText = view.string; parent.text = view.string; parent.controller.refresh(); view.grammarSession?.textChanged()
            view.objectNames?.textChanged()
        }
        func textViewDidChangeSelection(_ notification: Notification) { parent.controller.refresh() }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let action = parent.onSubmit { action(); return true }
            return false
        }
    }
}

struct WritingTextArea: View {
    @Binding var text: String
    var height: CGFloat = 120
    var label = "note"
    var fontSize: CGFloat = 14
    var compact = false
    var chrome = false
    @StateObject private var controller = EditorController()
    @Environment(\.grammarNamespace) private var namespace
    @Environment(\.reviewFocus) private var reviewFocus
    var body: some View {
        VStack(spacing: 0) {
            PlainWritingEditor(text: $text, controller: controller, fontSize: fontSize, label: label, documentKey: "\(namespace)/\(label)")
                .frame(height: height)
            if let session = controller.grammar {
                if reviewFocus == nil && controller.fieldFocused { InlineGrammarBar(session: session, compact: compact) }
                else { FieldSuggestionBadge(session: session).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            if let session = controller.objectNames { ObjectNameBar(session: session) }
        }.background(chrome ? Color.clear : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(chrome ? Color.clear : Color.primary.opacity(0.1)))
            .id("\(namespace)/\(label)")
    }
}
