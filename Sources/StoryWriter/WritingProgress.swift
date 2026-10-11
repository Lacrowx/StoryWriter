import SwiftUI

extension DraftStatus {
    var symbol: String {
        switch self {
        case .planned: return "circle.dashed"
        case .drafting: return "pencil"
        case .revising: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .planned: return .secondary
        case .drafting: return .orange
        case .revising: return .blue
        case .ready: return .accentColor
        }
    }
}

struct WritingProgressButton: View {
    var project: StoryProject
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                if project.targetWords > 0 {
                    ProgressView(value: min(1, Double(project.wordCount) / Double(project.targetWords)))
                        .frame(width: 48).accessibilityHidden(true)
                    Text("\(project.wordCount.formatted()) / \(project.targetWords.formatted()) words")
                } else {
                    Label("\(project.wordCount.formatted()) words · Set goal", systemImage: "scope")
                }
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("Writing progress and word goal")
            .accessibilityLabel("Writing progress, \(project.wordCount) words. \(project.targetWords > 0 ? "Goal: \(project.targetWords) words." : "No word goal.")")
            .popover(isPresented: $showing, arrowEdge: .top) {
                WritingProgressPopover(projectID: project.id)
            }
    }
}

struct WritingProgressPopover: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @State private var goal = ""
    @State private var editingGoal = false
    @FocusState private var goalFocused: Bool

    private var validGoal: Int? {
        guard let value = Int(goal.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { return nil }
        return value
    }

    var body: some View {
        if let project = store.project(projectID) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Writing progress", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 20, weight: .medium, design: .serif))
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(project.wordCount.formatted())").font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("words in your manuscript").font(.caption).foregroundStyle(.secondary)
                    if project.targetWords > 0 {
                        ProgressView(value: min(1, Double(project.wordCount) / Double(project.targetWords)))
                        Text(project.wordCount >= project.targetWords ? "Word goal reached" : "\((project.targetWords - project.wordCount).formatted()) words to your goal")
                            .font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
                Divider()
                VStack(spacing: 10) {
                    ForEach(DraftStatus.allCases) { status in
                        HStack {
                            Label(status.rawValue, systemImage: status.symbol).foregroundStyle(status.color)
                            Spacer()
                            Text(project.chapters.filter { $0.status == status }.count.formatted()).monospacedDigit()
                        }.font(.callout)
                    }
                }
                Divider()
                if editingGoal {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Word goal", text: $goal).textFieldStyle(.roundedBorder)
                                .focused($goalFocused).onSubmit { saveGoal() }
                                .accessibilityLabel("Manuscript word goal")
                            Button("Save", action: saveGoal).disabled(validGoal == nil)
                        }
                        Text("Use 0 for no word goal.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(project.targetWords > 0 ? "Goal: \(project.targetWords.formatted()) words" : "No word goal").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("\(project.targetWords > 0 ? "Edit" : "Set") goal") {
                            goal = String(max(0, project.targetWords)); editingGoal = true; goalFocused = true
                        }.buttonStyle(.link).font(.caption)
                    }
                }
            }.padding(24).frame(width: 300)
        }
    }

    private func saveGoal() {
        guard let value = validGoal else { return }
        store.update(projectID) { $0.targetWords = value }
        editingGoal = false
    }
}
