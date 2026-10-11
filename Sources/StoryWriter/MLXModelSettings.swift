import Foundation

struct MLXModelSettings: Codable, Equatable, Sendable {
    var temperature: Double = 0
    var topP: Double = 1
    var maxTokens: Int = 2048
    var repetitionPenalty: Double = 1
    var keepLoadedMinutes: Int = 5

    var validated: Self {
        var copy = self
        copy.temperature = temperature.isFinite ? min(1.5, max(0, temperature)) : 0
        copy.topP = topP.isFinite ? min(1, max(0.05, topP)) : 1
        copy.maxTokens = min(8192, max(256, maxTokens))
        copy.repetitionPenalty = repetitionPenalty.isFinite ? min(1.3, max(1, repetitionPenalty)) : 1
        copy.keepLoadedMinutes = [0, 5, 15, 30].contains(keepLoadedMinutes) ? keepLoadedMinutes : 5
        return copy
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "mlxModelSettings"), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings.validated
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(validated), forKey: "mlxModelSettings")
    }
}

struct InstalledMLXModel: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var source: String
    var bytes: Int64
    // Relative managed folder only; local machine paths stay out of metadata.
    var folder: String { id.uuidString }
}

struct MLXDownloadPlan: Sendable {
    struct File: Sendable { var name: String; var bytes: Int64 }
    var repository: String
    var revision: String
    var files: [File]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static func validatedRepository(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ProjectError.invalid("Enter a public Hugging Face model ID, such as mlx-community/Qwen3-4B-4bit.")
        }
        return value
    }
    static func from(data: Data, repository: String) throws -> Self {
        struct Info: Decodable {
            struct Sibling: Decodable {
                struct LFS: Decodable { var size: Int64 }
                var rfilename: String; var size: Int64?; var lfs: LFS?
            }
            var sha: String; var siblings: [Sibling]
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { throw ProjectError.invalid("The model repository has no valid revision.") }
        let files = info.siblings.compactMap { file -> File? in
            // MLX consumes top-level weights and tokenizer assets. Never import
            // remote code, arbitrary paths, or another format's large weights.
            guard !file.rfilename.contains("/"), !file.rfilename.contains("\\"), !file.rfilename.hasPrefix("."),
                  ["json", "safetensors", "model", "txt", "jinja", "tiktoken", "md"].contains((file.rfilename as NSString).pathExtension.lowercased()) else { return nil }
            return File(name: file.rfilename, bytes: max(0, file.lfs?.size ?? file.size ?? 0))
        }
        guard Set(files.map(\.name)).count == files.count,
              ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy({ required in files.contains { $0.name == required } }),
              files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
            throw ProjectError.invalid("Choose an MLX text model with safetensors weights and tokenizer files. GGUF models cannot run in MLX.")
        }
        return Self(repository: try validatedRepository(repository), revision: info.sha, files: files)
    }
}

struct MLXModelStore: Sendable {
    var root: URL
    static var standard: Self {
        let override = ProcessInfo.processInfo.environment["STORYWRITER_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return Self(root: override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StoryWriter/Models", isDirectory: true))
    }
    func directory(for model: InstalledMLXModel) -> URL { root.appendingPathComponent(model.folder, isDirectory: true) }
    func load() throws -> [InstalledMLXModel] {
        let manifest = root.appendingPathComponent("models.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        return try JSONDecoder().decode([InstalledMLXModel].self, from: Data(contentsOf: manifest))
    }
    func save(_ models: [InstalledMLXModel]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(models).write(to: root.appendingPathComponent("models.json"), options: .atomic)
    }
    static func validateDirectory(_ directory: URL) throws -> Int64 {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        var bytes: Int64 = 0
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ProjectError.invalid("Import a model folder containing actual files, rather than symbolic links.") }
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            let file = directory.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ProjectError.invalid("The model folder needs \(name).") }
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        guard config?["model_type"] is String, entries.contains(where: { $0.pathExtension == "safetensors" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }) else {
            throw ProjectError.invalid("Choose an MLX model folder with config.json, tokenizer files, and nonempty safetensors weights.")
        }
        return bytes
    }
    func importFolder(_ source: URL) throws -> InstalledMLXModel {
        _ = try Self.validateDirectory(source)
        let model = InstalledMLXModel(id: UUID(), name: source.lastPathComponent, source: "Imported folder", bytes: 0)
        let destination = directory(for: model)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            // Only copy flat runtime assets; no caches, nested repositories,
            // executable code, or external links from an imported folder.
            for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey]) {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                   ["json", "safetensors", "model", "txt", "jinja", "tiktoken", "md"].contains(file.pathExtension.lowercased()) {
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
                }
            }
            var installed = model
            installed.bytes = try Self.validateDirectory(destination)
            return installed
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
