import SwiftUI

/// The active workspace supplies the same actions to its toolbar and the Mac menu bar.
@MainActor
struct WorkspaceMenus {
    var project: [ContextCommand]
    var writing: [ContextCommand]
    var navigation: [ContextCommand]
    var display: [ContextCommand]
    var isStory: Bool
    var focusMode: Bool
    var search: () -> Void
    var toggleFocus: () -> Void
}

private struct WorkspaceMenusKey: FocusedValueKey {
    typealias Value = WorkspaceMenus
}

extension FocusedValues {
    var workspaceMenus: WorkspaceMenus? {
        get { self[WorkspaceMenusKey.self] }
        set { self[WorkspaceMenusKey.self] = newValue }
    }
}

struct WorkspaceMenuCommands: Commands {
    @FocusedValue(\.workspaceMenus) private var workspace

    var body: some Commands {
        CommandMenu("Project") {
            ContextCommandItems(commands: workspace?.project ?? [
                .button("Open a project to see its actions", enabled: false) {}
            ])
        }
        CommandMenu("Navigate") {
            if let workspace, workspace.isStory {
                ContextCommandItems(commands: workspace.navigation)
            } else {
                Button("Open a story to navigate its workspace") {}.disabled(true)
            }
        }
        CommandMenu("Writing") {
            if let workspace, workspace.isStory {
                ContextCommandItems(commands: workspace.writing)
            } else {
                Button("Open a story to use writing tools") {}.disabled(true)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Project…") { workspace?.search() }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(workspace == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(workspace?.focusMode == true ? "Exit Focus Mode" : "Enter Focus Mode") { workspace?.toggleFocus() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(workspace?.isStory != true)
            Menu("Manuscript Display") {
                ContextCommandItems(commands: workspace?.display ?? [])
            }.disabled(workspace?.isStory != true)
        }
    }
}

struct WriterMenuLabel: View {
    var title: String
    var symbol: String
    var active = false
    var compact = false
    var showsSymbol = true

    var body: some View {
        Group {
            if compact { Image(systemName: symbol).accessibilityLabel(title) }
            else if !showsSymbol { Text(title) }
            else { Label(title, systemImage: symbol) }
        }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.8))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(active ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
