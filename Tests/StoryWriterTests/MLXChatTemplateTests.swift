import XCTest
@testable import StoryWriter
#if canImport(Tokenizers) && arch(arm64)
import Tokenizers
#endif

final class MLXChatTemplateTests: XCTestCase {
    func testLiveMLXChatTemplatePreservesCompleteGermanPassage() async throws {
        #if canImport(Tokenizers) && arch(arm64)
        guard let path = ProcessInfo.processInfo.environment["STORYWRITER_TEST_MLX_MODEL"] else {
            throw XCTSkip("Set STORYWRITER_TEST_MLX_MODEL to a local tokenizer folder.")
        }
        let directory = URL(fileURLWithPath: path)
        let passage = "Sie blieb im Flur stehen. Der Brief, den sie zwischen den alten Karten gefunden hatte, lag noch auf dem Tisch. Sie wollte ihn lesen, obwohl ihre Hände vor Kälte zitterten."
        let context = WritingReviewContext(document: "chapter prose").forPassage(passage)
        let system = WritingReviewPrompt.system(language: "de", context: context, includeStyle: false)
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        let tokens = try tokenizer.applyChatTemplate(messages: [
            ["role": "system", "content": system], ["role": "user", "content": passage]
        ], tools: nil, additionalContext: ["enable_thinking": false])
        let decoded = tokenizer.decode(tokens: tokens, skipSpecialTokens: false)
        XCTAssertTrue(decoded.contains(system.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(decoded.contains(passage), "Every clause and the final sentence must survive templating and tokenization")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        if (config?["model_type"] as? String)?.hasPrefix("gemma4") == true {
            XCTAssertTrue(decoded.hasPrefix("<bos><|turn>system\n"))
            XCTAssertTrue(decoded.contains("<turn|>\n<|turn>user\n"))
            XCTAssertTrue(decoded.hasSuffix("<|turn>model\n"))
            XCTAssertFalse(decoded.contains("<|think|>"))
        }
        #else
        throw XCTSkip("The local tokenizer requires the Apple Silicon MLX build.")
        #endif
    }
}
