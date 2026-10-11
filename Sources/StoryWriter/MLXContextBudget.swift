import Foundation

enum MLXContextBudget {
    static func contextLimit(config: [String: Any]) -> Int {
        // Qwen 3.5 and other composite configs keep text limits in text_config.
        let text = config["text_config"] as? [String: Any] ?? config
        let limit = text["max_position_embeddings"] as? Int ?? text["n_positions"] as? Int ?? 8192
        return max(1, limit)
    }

    static func inputLimit(contextLimit: Int, maxTokens: Int) throws -> Int {
        guard contextLimit > maxTokens else {
            throw ProjectError.invalid("Maximum output (\(maxTokens) tokens) leaves no room for a review in this model's \(contextLimit)-token context. Lower Maximum output in MLX settings or choose a model with a larger context.")
        }
        // Keep the existing memory cap even for models advertising huge contexts.
        return min(8192, contextLimit - maxTokens)
    }
}
