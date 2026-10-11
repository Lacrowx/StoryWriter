import XCTest
@testable import StoryWriter

final class MLXModelTests: XCTestCase {
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
        let issues = try await engine.review(text: "She go to the harbour yesterday.", language: "en", model: model, directory: directory,
            settings: MLXModelSettings(), context: WritingReviewContext(), includeStyle: false)
        XCTAssertFalse(issues.isEmpty, "The model should identify the verb error in this passage.")
        let german = try await engine.review(text: "Sie hat ein Brief bekommen.", language: "de", model: model, directory: directory,
            settings: MLXModelSettings(), context: WritingReviewContext(), includeStyle: false)
        XCTAssertFalse(german.isEmpty, "The model should identify the German article error.")
        await engine.unload()
    }
}
