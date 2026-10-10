import SwiftUI

struct WritingBriefSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    var projectID: UUID
    @State private var brief: String
    init(projectID: UUID, initialBrief: String) { self.projectID = projectID; _brief = State(initialValue: initialBrief) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Your project's writing brief", subtitle: "Tell the local AI what you want your writing to sound like.")
            Text("Describe the tone, point of view, tense, pacing, dialogue and language you prefer. You can also explain the subject, boundaries and details the editor should preserve.").foregroundStyle(.secondary)
            Text("For example: Write a tense coastal mystery in close third person and present tense. Keep Mara's voice direct. Prefer concrete verbs and natural German phrasing. Avoid flowery descriptions, repeated explanations and invented details.").font(.callout).foregroundStyle(.secondary).padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            WritingTextArea(text: $brief, height: 260, label: "AI writing brief").environment(\.grammarNamespace, "brief-draft/\(projectID)")
            Text("Reviews include this brief and short story, character, world and chapter summaries. Osaurus uses up to 3,000 brief characters; Apple's model uses up to 1,500 to fit its smaller context. Everything is processed locally.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(brief.count) characters · up to 3,000 sent").font(.caption).foregroundStyle(brief.count > 3000 ? .orange : .secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save brief") { store.update(projectID) { $0.aiWritingBrief = brief }; dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 690)
    }
}
