import SwiftUI

struct RenameProjectSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    @State private var title: String
    init(projectID: UUID, initialTitle: String) { self.projectID = projectID; self._title = State(initialValue: initialTitle) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename project").font(.system(size: 24, weight: .semibold))
            TextField("Project title", text: $title).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Rename") { store.update(projectID) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }; dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(30).frame(width: 430).writerSheet()
    }
}
