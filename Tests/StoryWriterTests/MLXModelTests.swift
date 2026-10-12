import XCTest
@testable import StoryWriter

final class MLXModelTests: XCTestCase {
    func testModelQualityCheckRequiresCorrectionOfTheActualError() {
        XCTAssertFalse(MLXModelQualityCheck.english.catchesError([]))
        XCTAssertFalse(MLXModelQualityCheck.english.catchesError([GrammarIssue(original: "harbour", replacement: "harbor", explanation: "", kind: .spelling)]))
        XCTAssertTrue(MLXModelQualityCheck.english.catchesError([GrammarIssue(original: "go", replacement: "went", explanation: "", kind: .grammar)]))
        XCTAssertFalse(MLXModelQualityCheck.german.catchesError([GrammarIssue(original: "bekommen", replacement: "erhalten", explanation: "", kind: .style)]))
        XCTAssertTrue(MLXModelQualityCheck.german.catchesError([GrammarIssue(original: "ein Brief", replacement: "einen Brief", explanation: "", kind: .grammar)]))
    }
    func testCancelledWaiterFinishesWhileAnotherReviewStillOwnsEngine() async throws {
        let gate = MLXOperationGate()
        try await gate.acquire()
        let cancelled = expectation(description: "Queued cancellation completes before active review")
        let request = Task {
            do { try await gate.withAccess { XCTFail("Cancelled review must not run") } }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected failure: \(error)") }
        }
        await waitForQueue(gate, count: 1)
        request.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let remaining = await gate.waitingCount
        XCTAssertEqual(remaining, 0)
        await gate.release()
        await request.value
        let value = try await gate.withAccess { 42 }
        XCTAssertEqual(value, 42)
    }

    func testCancellingMiddleWaiterPreservesQueueAndFailureReleasesEngine() async throws {
        actor Order {
            var values: [Int] = []
            func append(_ value: Int) { values.append(value) }
        }
        let gate = MLXOperationGate()
        let order = Order()
        try await gate.acquire()
        let first = Task { try await gate.withAccess { await order.append(1) } }
        await waitForQueue(gate, count: 1)
        let middle = Task { try await gate.withAccess { await order.append(2) } }
        await waitForQueue(gate, count: 2)
        let last = Task { try await gate.withAccess { await order.append(3) } }
        await waitForQueue(gate, count: 3)
        middle.cancel()
        await waitForQueue(gate, count: 2)
        await gate.release()
        try await first.value
        do { try await middle.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await last.value
        let values = await order.values
        XCTAssertEqual(values, [1, 3])
        do { try await gate.withAccess { throw ProjectError.invalid("Test failure") }; XCTFail("Expected failure") }
        catch { }
        let recovered = try await gate.withAccess { true }
        XCTAssertTrue(recovered)
    }

    func testCancellationRacingWithOwnershipDoesNotStrandEngine() async throws {
        let gate = MLXOperationGate()
        for _ in 0..<100 {
            try await gate.acquire()
            let request = Task { try await gate.withAccess { 1 } }
            request.cancel()
            await gate.release()
            _ = await request.result
        }
        let value = try await gate.withAccess { 42 }
        XCTAssertEqual(value, 42)
    }

    private func waitForQueue(_ gate: MLXOperationGate, count: Int) async {
        for _ in 0..<1000 {
            if await gate.waitingCount == count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Review queue did not reach \(count) waiters")
    }

    func testContextBudgetReservesOutputAndReadsCompositeTextConfig() throws {
        XCTAssertEqual(MLXContextBudget.contextLimit(config: [:]), 8192)
        XCTAssertEqual(MLXContextBudget.contextLimit(config: ["max_position_embeddings": 4096]), 4096)
        XCTAssertEqual(MLXContextBudget.contextLimit(config: ["n_positions": 2048]), 2048)
        let nested: [String: Any] = ["max_position_embeddings": 8192, "text_config": ["max_position_embeddings": 32768]]
        XCTAssertEqual(MLXContextBudget.contextLimit(config: nested), 32768)
        XCTAssertEqual(try MLXContextBudget.inputLimit(contextLimit: 4096, maxTokens: 2048), 2048)
        XCTAssertEqual(try MLXContextBudget.inputLimit(contextLimit: 262144, maxTokens: 8192), 8192)
        for limit in [1, 2048, 4096] {
            XCTAssertThrowsError(try MLXContextBudget.inputLimit(contextLimit: limit, maxTokens: 4096))
        }
    }

    func testIncompleteShardsAndMalformedTokenizerCannotBeImported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Model")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, text) in ["config.json": #"{"model_type":"qwen3"}"#, "tokenizer.json": "{}", "tokenizer_config.json": "{}", "model-00001-of-00002.safetensors": "fixture"] {
            try Data(text.utf8).write(to: source.appendingPathComponent(name))
        }
        let store = MLXModelStore(root: root.appendingPathComponent("Library"))
        XCTAssertThrowsError(try store.importFolder(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        try Data("fixture".utf8).write(to: source.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertGreaterThan(try MLXModelStore.validateDirectory(source), 0)
        let index = source.appendingPathComponent("model.safetensors.index.json")
        for invalid in [#"{"weight_map":{"layer":"missing.safetensors"}}"#, #"{"weight_map":{"layer":"../outside.safetensors"}}"#, #"{"weight_map":{"layer":"nested/../../outside.safetensors"}}"#, #"{"weight_map":{"layer":"optiq/vision.safetensors"}}"#, #"{"weight_map":{}}"#, "broken"] {
            try Data(invalid.utf8).write(to: index)
            XCTAssertThrowsError(try MLXModelStore.validateDirectory(source))
        }
        try Data(#"{"weight_map":{"layer":"model-00001-of-00002.safetensors"}}"#.utf8).write(to: index)
        XCTAssertGreaterThan(try MLXModelStore.validateDirectory(source), 0)
        // OptiQ repos index vision weights in a subfolder that downloads skip.
        try Data(#"{"weight_map":{"layer":"model-00001-of-00002.safetensors","vision_tower.pos_embed":"optiq/optiq_vision.safetensors"}}"#.utf8).write(to: index)
        XCTAssertGreaterThan(try MLXModelStore.validateDirectory(source), 0)
        try Data("not JSON".utf8).write(to: source.appendingPathComponent("tokenizer.json"))
        XCTAssertThrowsError(try MLXModelStore.validateDirectory(source))
        try Data("{}".utf8).write(to: source.appendingPathComponent("tokenizer.json"))
        try Data().write(to: source.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertThrowsError(try MLXModelStore.validateDirectory(source))
    }

    func testSettingsClampAndRoundTrip() throws {
        let defaults = UserDefaults(suiteName: "StoryWriter-MLX-test-\(UUID())")!
        let settings = MLXModelSettings(temperature: .nan, topP: -5, maxTokens: 999999, repetitionPenalty: 8, keepLoadedMinutes: -1)
        settings.save(to: defaults)
        let loaded = MLXModelSettings.load(from: defaults)
        XCTAssertEqual(loaded.temperature, 0)
        XCTAssertEqual(loaded.topP, 0.05)
        XCTAssertEqual(loaded.maxTokens, 8192)
        XCTAssertEqual(loaded.repetitionPenalty, 1.3)
        XCTAssertEqual(loaded.keepLoadedMinutes, 5)
        defaults.removeObject(forKey: "mlxModelSettings")
        XCTAssertEqual(MLXModelSettings.load(from: defaults), MLXModelSettings())
    }
    func testDownloadPlanPinsRevisionAndExcludesRemoteCodeAndPaths() throws {
        let data = Data(#"{"sha":"1234567890123456789012345678901234567890","siblings":[{"rfilename":"config.json","size":2},{"rfilename":"tokenizer.json","size":3},{"rfilename":"tokenizer_config.json","size":4},{"rfilename":"model.safetensors","lfs":{"size":20}},{"rfilename":"evil.py","size":100},{"rfilename":"../bad.json","size":100},{"rfilename":"nested/weights.safetensors","size":100}]}"#.utf8)
        let plan = try MLXDownloadPlan.from(data: data, repository: "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(plan.files.count, 4)
        XCTAssertEqual(plan.bytes, 29)
        XCTAssertEqual(plan.revision, "1234567890123456789012345678901234567890")
        for id in ["../model", "owner/..", "https://example.com/model", "owner/model?token=x", "owner/a/b"] { XCTAssertThrowsError(try MLXDownloadPlan.validatedRepository(id)) }
        XCTAssertThrowsError(try MLXDownloadPlan.from(data: Data(#"{"sha":"main","siblings":[]}"#.utf8), repository: "owner/model"))
    }
    func testMissingWeightsCannotRegisterAsModel() throws {
        let data = Data(#"{"sha":"1234567890123456789012345678901234567890","siblings":[{"rfilename":"config.json"},{"rfilename":"tokenizer.json"},{"rfilename":"tokenizer_config.json"},{"rfilename":"model.gguf"}]}"#.utf8)
        XCTAssertThrowsError(try MLXDownloadPlan.from(data: data, repository: "owner/model"))
    }
    func testImportCopiesOnlyRuntimeFilesAndManifestSurvivesReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original model")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, text) in ["config.json": #"{"model_type":"qwen3"}"#, "tokenizer.json": "{}", "tokenizer_config.json": "{}", "model.safetensors": "fixture", "run.py": "not a runtime asset"] {
            try Data(text.utf8).write(to: source.appendingPathComponent(name))
        }
        let store = MLXModelStore(root: root.appendingPathComponent("Library"))
        let installed = try store.importFolder(source)
        try store.save([installed])
        XCTAssertEqual(try store.load(), [installed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: installed).appendingPathComponent("run.py").path))
        try FileManager.default.removeItem(at: source)
        XCTAssertGreaterThan(try MLXModelStore.validateDirectory(store.directory(for: installed)), 0)
        let manifest = try String(contentsOf: store.root.appendingPathComponent("models.json"))
        XCTAssertFalse(manifest.contains(root.path))
        try FileManager.default.createSymbolicLink(at: store.directory(for: installed).appendingPathComponent("outside.json"), withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try MLXModelStore.validateDirectory(store.directory(for: installed)))
    }
    func testModelSettingsAndIdentityParticipateInReviewCache() {
        var cache = WritingReviewRequestCache()
        let key = WritingReviewRequestCache.Key(text: "She go.", language: "en", model: LocalModel(id: UUID().uuidString, owned_by: "mlx"), baseURL: "builtin:mlx", includeStyle: false, context: WritingReviewContext(), mlxSettings: MLXModelSettings())
        cache.store([], for: key)
        XCTAssertNotNil(cache.result(for: key))
        var changed = key; changed.mlxSettings?.temperature = 0.5
        XCTAssertNil(cache.result(for: changed))
        changed = key; changed.model.id = UUID().uuidString
        XCTAssertNil(cache.result(for: changed))
        changed = key; changed.mlxSettings?.maxTokens = 4096
        XCTAssertNil(cache.result(for: changed))
    }
    func testLiveMLXCancellationReleasesEngine() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORYWRITER_TEST_MLX_MODEL"], MLXWritingModel.available else { throw XCTSkip("Requires an installed MLX model on Apple Silicon.") }
        let directory = URL(fileURLWithPath: path)
        let model = InstalledMLXModel(id: UUID(), name: "Cancellation test", source: "Test", bytes: 0)
        let engine = MLXWritingModel()
        try await engine.load(model: model, directory: directory, keepLoadedMinutes: 5)
        let request = Task {
            try await engine.review(text: String(repeating: "She go to the harbour yesterday. ", count: 100), language: "en", model: model, directory: directory, settings: MLXModelSettings(), context: WritingReviewContext(), includeStyle: false)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled inference should not return corrections") }
        catch is CancellationError { }
        await engine.unload()
        // A subsequent load proves cancellation released the runtime gate.
        try await engine.load(model: model, directory: directory, keepLoadedMinutes: 0)
        await engine.unload()
    }
    func testLiveMLXReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORYWRITER_TEST_MLX_MODEL"] else { throw XCTSkip("Set STORYWRITER_TEST_MLX_MODEL to an installed MLX folder for live inference.") }
        guard MLXWritingModel.available else { throw XCTSkip("MLX requires Apple Silicon.") }
        let directory = URL(fileURLWithPath: path)
        let model = InstalledMLXModel(id: UUID(), name: "Live test", source: "Test", bytes: 0)
        let engine = MLXWritingModel()
        let englishSample = MLXModelQualityCheck.english
        let issues = try await engine.review(text: englishSample.text, language: englishSample.language, model: model, directory: directory,
            settings: MLXModelSettings(), context: WritingReviewContext(), includeStyle: false)
        XCTAssertTrue(englishSample.catchesError(issues), "The model should correct the past-tense verb error in this passage.")
        let germanSample = MLXModelQualityCheck.german
        let german = try await engine.review(text: germanSample.text, language: germanSample.language, model: model, directory: directory,
            settings: MLXModelSettings(), context: WritingReviewContext(), includeStyle: false)
        XCTAssertTrue(germanSample.catchesError(german), "The model should correct the German article error.")
        await engine.unload()
    }
}
