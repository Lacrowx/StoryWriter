import AppKit
import SwiftUI

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}

@MainActor
final class MLXModelLibrary: ObservableObject {
    static let shared = MLXModelLibrary()
    @Published private(set) var models: [InstalledMLXModel] = []
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "mlxSelectedModel"); settingsChanged(); if selectedID != oldValue { Task { await MLXWritingModel.shared.unload() }; status = "Model changed. It will load for the next review." } }
    }
    @Published var settings: MLXModelSettings {
        didSet { settings.save(); settingsChanged(); if settings.keepLoadedMinutes != oldValue.keepLoadedMinutes { let minutes = settings.validated.keepLoadedMinutes; Task { await MLXWritingModel.shared.setRetention(minutes: minutes) } } }
    }
    @Published private(set) var busy = false
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "Models run on this Mac. No server is needed."
    @Published private(set) var error: String?
    @Published private(set) var plan: MLXDownloadPlan?
    private var operation: Task<Void, Never>?
    let store: MLXModelStore
    var selectedModel: InstalledMLXModel? { models.first { $0.id.uuidString == selectedID } }
    var settingsChanged: () -> Void = {}
    init(store: MLXModelStore = .standard) {
        self.store = store
        selectedID = UserDefaults.standard.string(forKey: "mlxSelectedModel") ?? ""
        settings = MLXModelSettings.load()
        do { models = try store.load() }
        catch { self.error = "Could not read the model library. \(error.localizedDescription)" }
        if selectedModel == nil { selectedID = models.first?.id.uuidString ?? "" }
    }
    func checkRepository(_ repository: String) {
        guard !busy else { return }
        busy = true; error = nil; plan = nil; status = "Checking model files…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let id = try MLXDownloadPlan.validatedRepository(repository)
                let url = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true")!
                let (data, response) = try await URLSession.shared.data(from: url)
                try Self.checkResponse(response)
                try Task.checkCancellation()
                plan = try MLXDownloadPlan.from(data: data, repository: id)
                status = "Download size: \(Self.size(plan!.bytes)). Model licenses apply; inspect the model card before downloading."
            } catch { report(error) }
        }
    }
    func cancel() { operation?.cancel() }
    func download() {
        guard !busy, let plan else { return }
        busy = true; downloading = true; progress = 0; error = nil
        operation = Task { [self] in
            defer { busy = false; downloading = false; operation = nil }
            let model = InstalledMLXModel(id: UUID(), name: plan.repository.components(separatedBy: "/").last!, source: plan.repository, bytes: plan.bytes)
            let directory = store.directory(for: model)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let available = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard plan.bytes == 0 || available > plan.bytes + 512 * 1024 * 1024 else { throw ProjectError.invalid("There is not enough disk space for this model.") }
                var finishedBytes: Int64 = 0
                for file in plan.files {
                    try Task.checkCancellation()
                    status = "Downloading \(file.name)…"
                    let alreadyDownloaded = finishedBytes
                    let delegate = ModelDownloadProgress { [weak self] bytes in
                        Task { @MainActor in
                            guard let self else { return }
                            self.progress = min(1, Double(alreadyDownloaded + bytes) / Double(max(1, plan.bytes)))
                        }
                    }
                    let url = URL(string: "https://huggingface.co/\(plan.repository)/resolve/\(plan.revision)/\(file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")!
                    let (temporary, response) = try await session.download(from: url, delegate: delegate)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Self.checkResponse(response)
                    try Task.checkCancellation()
                    let actualSize = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard file.bytes == 0 || actualSize == file.bytes else { throw ProjectError.invalid("The download of \(file.name) was incomplete. Try again.") }
                    try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(file.name))
                    finishedBytes += actualSize
                }
                var installed = model
                installed.bytes = try MLXModelStore.validateDirectory(directory)
                try register(installed)
                progress = 1; self.plan = nil; status = "Model installed. Ready for a local review."
            } catch { try? FileManager.default.removeItem(at: directory); report(error) }
        }
    }
    func importModel() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose an MLX model folder. StoryWriter copies its weights and tokenizer into its own model library."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        busy = true; error = nil; status = "Copying model files…"
        let store = store
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let work = Task.detached { try store.importFolder(source) }
                let installed = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                do { try Task.checkCancellation(); try register(installed) }
                catch { try? FileManager.default.removeItem(at: store.directory(for: installed)); throw error }
                status = "Model imported. Ready for a local review."
            } catch { report(error) }
        }
    }
    private func register(_ model: InstalledMLXModel) throws {
        let updated = models + [model]
        try store.save(updated)
        models = updated; selectedID = model.id.uuidString
    }
    func loadSelected() {
        guard !busy, let model = selectedModel else { return }
        busy = true; error = nil; status = "Loading \(model.name)…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await MLXWritingModel.shared.load(model: model, directory: store.directory(for: model), keepLoadedMinutes: settings.keepLoadedMinutes)
                status = settings.keepLoadedMinutes == 0 ? "Model verified. Memory released." : "Model loaded. Idle memory release is enabled."
            } catch { report(error) }
        }
    }
    func testSelected() {
        guard !busy, let model = selectedModel else { return }
        busy = true; error = nil
        let settings = settings.validated
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                var results: [Bool] = []
                for sample in [MLXModelQualityCheck.english, MLXModelQualityCheck.german] {
                    try Task.checkCancellation()
                    status = "Testing \(sample.language == "en" ? "English" : "German") proofreading with \(model.name)…"
                    let issues = try await MLXWritingModel.shared.review(text: sample.text, language: sample.language,
                        model: model, directory: store.directory(for: model), settings: settings,
                        context: WritingReviewContext(), includeStyle: false)
                    results.append(sample.catchesError(issues))
                }
                try Task.checkCancellation()
                status = "English: \(results[0] ? "error corrected" : "error missed") · German: \(results[1] ? "error corrected" : "error missed"). "
                    + (results.allSatisfy { $0 } ? "Both sample checks passed. Review suggestions before accepting." : "Try another model for languages where the error was missed.")
            } catch { report(error) }
        }
    }
    func unload() {
        guard !busy else { return }
        busy = true
        operation = Task {
            await MLXWritingModel.shared.unload()
            busy = false; operation = nil; status = "Model memory released. It will load for the next review."
        }
    }
    func removeSelected() {
        guard !busy, let model = selectedModel else { return }
        let alert = NSAlert(); alert.messageText = "Remove \(model.name)?"
        alert.informativeText = "This removes StoryWriter's copy of the model. Your writing and any original imported folder are preserved."
        alert.addButton(withTitle: "Remove model"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; error = nil
        operation = Task {
            defer { busy = false; operation = nil }
            await MLXWritingModel.shared.unload()
            do {
                let updated = models.filter { $0.id != model.id }
                // Persist first. If removal fails the orphan remains recoverable
                // on disk, rather than retaining a record pointing at lost files.
                try store.save(updated)
                models = updated; selectedID = models.first?.id.uuidString ?? ""
                try FileManager.default.removeItem(at: store.directory(for: model))
                status = "Model removed."
            } catch { report(error) }
        }
    }
    private func report(_ failure: Error) {
        if failure is CancellationError || (failure as NSError).code == NSURLErrorCancelled { status = "Operation cancelled." }
        else { error = failure.localizedDescription; status = "Model operation failed." }
    }
    private static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProjectError.invalid("Could not download this public model. Check the model ID and connection. Gated models must be downloaded separately and imported.")
        }
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
