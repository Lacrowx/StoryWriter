import Foundation
#if canImport(MLXLLM) && arch(arm64)
import MLX
import Metal
import MLXLLM
import MLXLMCommon
#endif

actor MLXWritingModel {
    static let shared = MLXWritingModel()
    static var available: Bool {
        #if canImport(MLXLLM) && arch(arm64)
        MTLCreateSystemDefaultDevice() != nil
        #else
        false
        #endif
    }
    // An actor can reenter at awaits. Serialize the whole load/generate/unload
    // operation as well so simultaneous field reviews cannot double-load weights.
    private var occupied = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var idleTask: Task<Void, Never>?
    private var loadedID: UUID?
    private var contextLimit = 8192
    #if canImport(MLXLLM) && arch(arm64)
    private var container: ModelContainer?
    #endif

    private func acquire() async {
        if occupied { await withCheckedContinuation { waiting.append($0) } }
        else { occupied = true }
        idleTask?.cancel(); idleTask = nil
    }
    private func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().resume() }
    }
    func unload() async {
        await acquire(); defer { release() }
        clearModel()
    }
    private func clearModel() {
        guard loadedID != nil else { return }
        #if canImport(MLXLLM) && arch(arm64)
        container = nil
        Memory.clearCache()
        #endif
        loadedID = nil
    }
    func setRetention(minutes: Int) async {
        await acquire(); defer { release() }
        scheduleUnload(minutes: minutes)
    }
    private func scheduleUnload(minutes: Int) {
        idleTask?.cancel()
        if minutes == 0 { clearModel(); return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
    func load(model: InstalledMLXModel, directory: URL, keepLoadedMinutes: Int) async throws {
        await acquire(); defer { release(); scheduleUnload(minutes: keepLoadedMinutes) }
        try Task.checkCancellation()
        try await loadIfNeeded(model: model, directory: directory)
    }
    private func loadIfNeeded(model: InstalledMLXModel, directory: URL) async throws {
        #if canImport(MLXLLM) && arch(arm64)
        if loadedID == model.id, container != nil { return }
        clearModel()
        let bytes = try MLXModelStore.validateDirectory(directory)
        guard Double(bytes) < Double(ProcessInfo.processInfo.physicalMemory) * 0.75 else {
            throw ProjectError.invalid("This model leaves too little RAM for writing and generation on this Mac. Choose a smaller quantized model.")
        }
        // Limit spare allocator cache; model weights and request KV cache are
        // separate. This is not a promise that arbitrary models fit in RAM.
        Memory.cacheLimit = 256 * 1024 * 1024
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        contextLimit = max(1, (config?["max_position_embeddings"] as? Int) ?? 8192)
        container = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: directory))
        loadedID = model.id
        try Task.checkCancellation()
        #else
        throw ProjectError.invalid("Built-in MLX models require an Apple Silicon Mac. Choose another review backend on this Mac.")
        #endif
    }
    func review(text: String, language: String, model: InstalledMLXModel, directory: URL,
                settings: MLXModelSettings, context: WritingReviewContext, includeStyle: Bool) async throws -> [GrammarIssue] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard text.count <= 6000 else { throw ProjectError.invalid("Review a passage of up to 6,000 characters at a time.") }
        let context = context.forPassage(text)
        let names = context.protectedTerms + WritingIdentityGuard.detectedNames(in: text, language: language)
        let spelling = await SpellingReview.candidates(text, language: language, protectedTerms: names)
        await acquire()
        let settings = settings.validated
        defer { release(); scheduleUnload(minutes: settings.keepLoadedMinutes) }
        try Task.checkCancellation()
        try await loadIfNeeded(model: model, directory: directory)
        #if canImport(MLXLLM) && arch(arm64)
        guard let container else { throw ProjectError.invalid("The MLX model could not be loaded.") }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let system = WritingReviewPrompt.system(language: language, context: context, includeStyle: includeStyle, spelling: spelling, retry: attempt == 1)
            let inputBudget = min(8192, contextLimit - settings.maxTokens)
            do {
                let result = try await container.perform { modelContext in
                    let input = try await modelContext.processor.prepare(input: UserInput(
                        chat: [.system(system), .user(text)], additionalContext: ["enable_thinking": false]))
                    // A fixed budget prevents long passages from exhausting memory.
                    // Reject instead of silently truncating the input or losing names.
                    guard input.text.tokens.size <= inputBudget else { throw ProjectError.invalid("This review exceeds the model's context budget. Shorten the brief, review a smaller passage, or lower Maximum output in MLX settings.") }
                    let parameters = GenerateParameters(maxTokens: settings.maxTokens,
                        temperature: Float(settings.temperature), topP: Float(settings.topP),
                        repetitionPenalty: settings.repetitionPenalty == 1 ? nil : Float(settings.repetitionPenalty), repetitionContextSize: 64)
                    let iterator = try TokenIterator(input: input, model: modelContext.model, parameters: parameters)
                    let (stream, task) = generateTask(promptTokenCount: input.text.tokens.size,
                        modelConfiguration: modelContext.configuration, tokenizer: modelContext.tokenizer, iterator: iterator)
                    // Wait for the producer even on cancellation, before unloading
                    // weights or handing the engine to another review.
                    return try await withTaskCancellationHandler {
                        var output = ""
                        var completed = false
                        var truncated = false
                        for await event in stream {
                            switch event {
                            case .chunk(let text): output += text
                            case .info(let info):
                                completed = true
                                switch info.stopReason {
                                case .length: truncated = true
                                case .cancelled: task.cancel(); completed = false
                                case .stop: break
                                }
                            case .toolCall: break
                            }
                            if Task.isCancelled { task.cancel() }
                        }
                        await task.value
                        try Task.checkCancellation()
                        guard completed else { throw WritingReviewResponseError.format }
                        if truncated { throw WritingReviewResponseError.truncated }
                        return output
                    } onCancel: { task.cancel() }
                }
                let issues = try OsaurusClient.parseIssues(result, passage: text, includeStyle: includeStyle)
                return SpellingReview.supplement(WritingIdentityGuard.protect(issues, names: names, language: language), with: spelling, passage: text)
            } catch is WritingReviewResponseError where attempt == 0 { continue }
        }
        throw WritingReviewResponseError.format
        #else
        throw ProjectError.invalid("Built-in MLX models require an Apple Silicon Mac.")
        #endif
    }
}
