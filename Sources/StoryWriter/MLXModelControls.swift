import SwiftUI
import AppKit

struct MLXModelPicker: View {
    @ObservedObject private var library = MLXModelLibrary.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Built-in model", selection: $library.selectedID) {
                Text("Choose a model").tag("")
                ForEach(library.models) { Text($0.name).tag($0.id.uuidString) }
            }.disabled(library.busy || !MLXWritingModel.available)
            if !MLXWritingModel.available {
                Text("MLX requires an Apple Silicon Mac. The other review backends remain available.").font(.caption).foregroundStyle(.secondary)
            } else if library.models.isEmpty {
                Text("Download or import an MLX model in Settings → Writing Review.").font(.caption).foregroundStyle(.secondary)
            } else if let model = library.selectedModel {
                Text("\(MLXModelLibrary.size(model.bytes)) on disk · Runs on this Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MLXModelControls: View {
    @ObservedObject private var library = MLXModelLibrary.shared
    @State private var repository = "mlx-community/Qwen3-4B-4bit"
    var body: some View {
        Section("Built-in model library") {
            Text("Download once, then review offline. Models stay outside projects and app updates. System memory: \(MLXModelLibrary.size(Int64(ProcessInfo.processInfo.physicalMemory))) total system RAM; the model also needs working memory.").font(.caption).foregroundStyle(.secondary)
            TextField("Hugging Face model ID", text: $repository).disabled(library.busy)
            HStack {
                Button("Check download") { library.checkRepository(repository) }.disabled(library.busy)
                Button("Import model folder…") { library.importModel() }.disabled(library.busy)
            }
            if let plan = library.plan {
                HStack {
                    Button("Download \(MLXModelLibrary.size(plan.bytes))") { library.download() }.disabled(library.busy)
                    Link("Model card & license", destination: URL(string: "https://huggingface.co/\(plan.repository)")!)
                }
                Text("\(plan.repository) · \(plan.files.count) files").font(.caption).foregroundStyle(.secondary)
            }
            if library.downloading { ProgressView(value: library.progress) }
            HStack {
                if library.busy { ProgressView().controlSize(.small); Button("Cancel") { library.cancel() } }
                Text(library.status).font(.caption).foregroundStyle(.secondary)
            }
            if let error = library.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if library.selectedModel != nil {
                HStack {
                    Button("Load / verify model") { library.loadSelected() }
                    Button("Release memory") { library.unload() }
                    Button("Remove model…") { library.removeSelected() }
                }.disabled(library.busy)
            }
        }.disabled(!MLXWritingModel.available)
        Section("MLX generation settings") {
            settingSlider("Temperature", value: $library.settings.temperature, range: 0...1.5, step: 0.05)
            Text("0 gives the most consistent output. Higher values vary the wording; proofreading usually benefits from 0.").font(.caption).foregroundStyle(.secondary)
            settingSlider("Top-p", value: $library.settings.topP, range: 0.05...1, step: 0.05)
            Text("Restricts token choices when temperature is above 0. 1 leaves this filter off.").font(.caption).foregroundStyle(.secondary)
            Stepper("Maximum output: \(library.settings.maxTokens) tokens", value: $library.settings.maxTokens, in: 256...8192, step: 256)
            Text("Limits each review reply. A reply that hits the limit is rejected; raise it if reviews are being cut short.").font(.caption).foregroundStyle(.secondary)
            settingSlider("Repetition penalty", value: $library.settings.repetitionPenalty, range: 1...1.3, step: 0.01)
            Text("1 leaves repetition unchanged. Higher values discourage repeats but can interfere with exact quoted corrections.").font(.caption).foregroundStyle(.secondary)
            Picker("Release model after", selection: $library.settings.keepLoadedMinutes) {
                Text("Each review").tag(0); Text("5 minutes idle").tag(5)
                Text("15 minutes idle").tag(15); Text("30 minutes idle").tag(30)
            }
            Button("Reset model settings") { library.settings = MLXModelSettings() }
        }.disabled(!MLXWritingModel.available)
    }
    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(title).frame(width: 140, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 45, alignment: .trailing)
        }
    }
}
