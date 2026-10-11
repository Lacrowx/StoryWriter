import AppKit
import SwiftUI

/// One command tree serves SwiftUI surfaces and native text views.
@MainActor
struct ContextCommand: Identifiable {
    let id = UUID()
    var title: String
    var enabled = true
    var checked: Bool?
    var children: [ContextCommand]?
    var action: (() -> Void)?
    var symbol: String?

    static var separator: ContextCommand { ContextCommand(title: "") }
    static func button(_ title: String, enabled: Bool = true, checked: Bool? = nil, symbol: String? = nil, action: @escaping () -> Void) -> ContextCommand {
        ContextCommand(title: title, enabled: enabled, checked: checked, action: action, symbol: symbol)
    }
    static func submenu(_ title: String, _ children: [ContextCommand], symbol: String? = nil) -> ContextCommand {
        ContextCommand(title: title, children: children, symbol: symbol)
    }

    static func menu(_ commands: [ContextCommand]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for command in commands {
            if command.title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
            item.isEnabled = command.enabled
            if let symbol = command.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: command.title) }
            if let checked = command.checked { item.state = checked ? .on : .off }
            if let children = command.children { item.submenu = Self.menu(children) }
            else if let action = command.action {
                let target = ContextCommandTarget(enabled: command.enabled, action)
                // NSMenuItem.target is weak; the menu owns the target for its lifetime.
                item.representedObject = target; item.target = target
                item.action = #selector(ContextCommandTarget.invokeContextCommand(_:))
            }
            menu.addItem(item)
        }
        return menu
    }
}

@MainActor private final class ContextCommandTarget: NSObject, NSMenuItemValidation {
    let action: () -> Void
    let enabled: Bool
    init(enabled: Bool, _ action: @escaping () -> Void) { self.enabled = enabled; self.action = action }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
    @objc func invokeContextCommand(_ sender: NSMenuItem) { if enabled { action() } }
}

private struct AppContextCommandsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> [ContextCommand] = { [] }
}
private struct ChapterContextCommandsKey: EnvironmentKey {
    static let defaultValue: @MainActor (UUID, NSRange, String) -> [ContextCommand] = { _, _, _ in [] }
}
extension EnvironmentValues {
    var appContextCommands: @MainActor () -> [ContextCommand] {
        get { self[AppContextCommandsKey.self] } set { self[AppContextCommandsKey.self] = newValue }
    }
    var chapterContextCommands: @MainActor (UUID, NSRange, String) -> [ContextCommand] {
        get { self[ChapterContextCommandsKey.self] } set { self[ChapterContextCommandsKey.self] = newValue }
    }
}

struct ContextCommandItems: View {
    var commands: [ContextCommand]
    var body: some View {
        ForEach(commands) { command in
            if command.title.isEmpty { Divider() }
            else if let children = command.children {
                Menu { ContextCommandItems(commands: children) } label: {
                    if let symbol = command.symbol { Label(command.title, systemImage: symbol) }
                    else { Text(command.title) }
                }.disabled(!command.enabled)
            } else {
                Button(action: { command.action?() }) {
                    if command.checked == true { Label(command.title, systemImage: "checkmark") }
                    else if let symbol = command.symbol { Label(command.title, systemImage: symbol) }
                    else { Text(command.title) }
                }.disabled(!command.enabled)
            }
        }
    }
}

struct AppContextMenuItems: View {
    @Environment(\.appContextCommands) private var commands
    @ObservedObject private var service = LocalGrammarService.shared
    var body: some View { ContextCommandItems(commands: commands()) }
}

private struct AppContextMenuModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.contextMenu { AppContextMenuItems() }
    }
}
extension View {
    func appContextMenu() -> some View { modifier(AppContextMenuModifier()) }
}

extension ManuscriptTextView {
    /// Build at invocation time so selection, suggestion counts, and settings stay current.
    func writingContextCommands() -> [ContextCommand] {
        let range = selectedRange()
        var commands = chapterContextCommands?(range, string) ?? []
        if let session = grammarSession {
            let review = GrammarScope.allCases.map { scope in
                ContextCommand.button("Review \(scope.rawValue.lowercased())", enabled: !string.isEmpty && (scope != .selection || range.length > 0)) { [weak session] in session?.review(scope, selection: range) }
            }
            let accept = GrammarScope.allCases.map { scope in
                ContextCommand.button("Accept in \(scope.rawValue.lowercased())", enabled: !session.selectedCorrections(scope, anchor: range).isEmpty) { [weak session] in session?.accept(scope, anchor: range) }
            }
            commands.append(.submenu("Review writing", review + [.separator, .submenu("Accept suggestions", accept),
                .button("Dismiss suggestions in selection", enabled: !session.selectedCorrections(.selection, anchor: range).isEmpty) { [weak session] in
                    guard let session else { return }
                    for correction in session.selectedCorrections(.selection, anchor: range) { session.dismiss(correction.id) }
                },
                .button("Cancel review", enabled: session.checking || session.pending) { [weak session] in session?.cancel() }
            ]))
        }
        if isRichText, let editor = contextEditor {
            editor.refresh()
            commands.append(.submenu("Formatting", [
                .button("Bold", checked: editor.isBold) { [weak editor] in editor?.action(#selector(ManuscriptTextView.toggleBoldface(_:))) },
                .button("Italic", checked: editor.isItalic) { [weak editor] in editor?.action(#selector(ManuscriptTextView.toggleItalics(_:))) },
                .button("Underline", checked: editor.isUnderlined) { [weak editor] in editor?.action(#selector(NSTextView.underline(_:))) },
                .button("Strikethrough") { [weak editor] in editor?.strikeThrough() }, .separator,
                .submenu("Text style", [("Body", "Georgia", 18.0), ("Heading 1", "Georgia-Bold", 30.0), ("Heading 2", "Georgia-Bold", 24.0), ("Caption", "Helvetica", 12.0)].map { title, font, size in
                    .button(title) { [weak editor] in editor?.setFont(name: font, size: size) }
                }),
                .button("Fonts…") { [weak self] in self?.window?.makeFirstResponder(self); NSFontManager.shared.orderFrontFontPanel(nil) },
                .submenu("Alignment", [("Left", #selector(NSTextView.alignLeft(_:))), ("Center", #selector(NSTextView.alignCenter(_:))), ("Right", #selector(NSTextView.alignRight(_:))), ("Justified", #selector(NSTextView.alignJustified(_:)))].map { title, selector in
                    .button(title) { [weak editor] in editor?.action(selector) }
                }),
                .button("Bulleted list") { [weak editor] in editor?.bulletList() },
                .button("Numbered list") { [weak editor] in editor?.bulletList(numbered: true) },
                .button("Highlight") { [weak editor] in editor?.setAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45)]) },
                .button("Remove highlight") { [weak editor] in editor?.setAttributes([.backgroundColor: NSColor.clear]) }
            ]))
        }
        if let tags = tagSession {
            var tagCommands: [ContextCommand] = [.button("Browse objects…") { [weak tags] in tags?.browse() }]
            for group in ObjectTags.groupOrder {
                let objects = ObjectTags.matches(tags.objects.filter { $0.group == group }, query: "")
                if !objects.isEmpty { tagCommands.append(.submenu(group, objects.map { object in .button(object.title) { [weak tags] in tags?.insert(object) } })) }
            }
            if range.location < (textStorage?.length ?? 0), let reference = ProjectTagReference.from(textStorage?.attribute(.link, at: range.location, effectiveRange: nil)) {
                tagCommands += [.separator, .button("Open tagged object") { [weak tags] in tags?.open(reference) }]
            }
            tagCommands.append(.button("Remove tag from selection", enabled: range.length > 0) { [weak tags] in tags?.removeSelectedTag() })
            commands.append(.submenu("Character & world tags", tagCommands))
        }
        commands.append(.button(isRichText ? "Find in chapter…" : "Find in field…") { [weak self] in
            guard let self else { return }; window?.makeFirstResponder(self)
            let item = NSMenuItem(); item.tag = 1; performFindPanelAction(item)
        })
        commands.append(.separator)
        let shared = appContextCommands()
        let settings = shared.filter { $0.title == "Settings…" }
        let app = shared.filter { $0.title != "Settings…" }
        if !app.isEmpty { commands.append(.submenu("StoryWriter", app)) }
        commands += settings
        return commands
    }
}
