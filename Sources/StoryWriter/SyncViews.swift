import SwiftUI

struct SyncSettings: View {
    @ObservedObject var sync: DriveSync
    var body: some View {
        Section("Sync across Macs") {
            Text("Choose the same iCloud Drive folder on each Mac. Compatible edits merge automatically; overlapping edits stay available for review.").font(.caption).foregroundStyle(.secondary)
            if let folder = sync.folder {
                LabeledContent("Sync folder", value: folder.lastPathComponent)
                Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Sync now") { Task { await sync.checkNow() } }.disabled(sync.running)
                    Button("Change folder…", action: sync.chooseFolder)
                    Button("Disconnect", action: sync.disconnect)
                }
                Text("Disconnecting keeps your local writing and the shared versions. Files in the folder may take time to reach your other Mac.").font(.caption).foregroundStyle(.secondary)
            } else { Button("Choose sync folder…", action: sync.chooseFolder) }
        }
    }
}

struct SyncLibraryStatus: View {
    @ObservedObject var sync: DriveSync
    var body: some View {
        if sync.folder != nil {
            VStack(alignment: .leading, spacing: 6) {
                Label(sync.status, systemImage: sync.reviews.isEmpty ? "icloud" : "exclamationmark.bubble")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).help(sync.status)
                ForEach(sync.reviews.values.sorted { $0.projectID.uuidString < $1.projectID.uuidString }) { review in
                    Button("Review changes: " + review.local.project.title) { sync.reviewProjectID = review.projectID }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

struct SyncWorkspaceStatus: View {
    @ObservedObject var sync: DriveSync
    var projectID: UUID
    var body: some View {
        if sync.folder != nil {
            Text("·")
            if sync.reviews[projectID] != nil {
                Button("Changes need review") { sync.reviewProjectID = projectID }.buttonStyle(.link)
            } else {
                Label(sync.status, systemImage: "icloud").lineLimit(1).help(sync.status)
            }
        }
    }
}

struct SyncReviewSheet: View {
    @ObservedObject var sync: DriveSync
    var review: DriveReview
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [String: MergeChoice] = [:]
    @State private var selectedID: String?
    @State private var applying = false
    private var current: DriveReview { sync.reviews[review.projectID] ?? review }
    private var selected: MergeConflict? { current.conflicts.first { $0.id == selectedID } ?? current.conflicts.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review changes to " + current.local.project.title).font(.title2)
            Text("Compatible changes will be combined. Choose which version to keep for each overlap, or keep the other Mac's complete version as a separate story.").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                List(current.conflicts, selection: $selectedID) { conflict in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conflict.title).font(.callout)
                        Text(choices[conflict.id].map { $0 == .local ? "Using this Mac" : "Using other Mac" } ?? "Choose a version").font(.caption).foregroundStyle(.secondary)
                    }.tag(conflict.id)
                }.frame(width: 230)
                if let conflict = selected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(conflict.title).font(.headline)
                        HStack(alignment: .top) {
                            preview(conflict, choice: .local, title: "This Mac", project: current.local.project)
                            preview(conflict, choice: .incoming, title: current.incoming.deviceName, project: current.incoming.project)
                        }
                    }
                }
            }.frame(minHeight: 350)
            Text(sync.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Keep both stories") { apply(keepBoth: true) }.disabled(applying || sync.running)
                Spacer()
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge chosen versions") { apply(keepBoth: false) }
                    .buttonStyle(.borderedProminent).disabled(applying || sync.running || current.conflicts.contains { choices[$0.id] == nil })
            }
        }.padding(24).frame(width: 1040, height: 620)
            .onChange(of: current.id) { _, _ in choices = [:]; selectedID = nil }
    }
    @ViewBuilder private func preview(_ conflict: MergeConflict, choice: MergeChoice, title: String, project: StoryProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if let writing = choice == .local ? conflict.localWriting : conflict.incomingWriting {
                SyncWritingPreview(text: writing)
            } else {
                ScrollView { Text(choice == .local ? conflict.local : conflict.incoming).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }
                    .background(.background).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button(choice == .local ? "Use this Mac" : "Use other Mac") { choices[conflict.id] = choice }
                .buttonStyle(.bordered).tint(choices[conflict.id] == choice ? .accentColor : .secondary)
        }.frame(maxWidth: .infinity)
    }
    private func apply(keepBoth: Bool) {
        applying = true
        let request = current, selected = choices
        Task {
            if await sync.resolve(request, choices: keepBoth ? [:] : selected, keepBoth: keepBoth) { dismiss() }
            applying = false
        }
    }
}

private struct SyncWritingPreview: View {
    var text: NSAttributedString
    @StateObject private var controller = EditorController()
    var body: some View { SavedPassagePreview(text: text, controller: controller).clipShape(RoundedRectangle(cornerRadius: 8)) }
}
