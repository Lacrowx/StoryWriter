import XCTest
@testable import StoryWriter

final class OsaurusReviewTests: XCTestCase {
    func testSparseCorrectionsWithoutExplanationsPreserveUnicodeAndCategories() throws {
        let passage = "Grüße 🌊. Sie hat ein Brief. She felt tired and she was tired."
        let response = #"{"issues":[{"original":"Sie hat ein Brief.","replacement":"Sie hat einen Brief.","kind":"grammar"},{"original":"She felt tired and she was tired.","replacement":"She was tired.","kind":"style"}]}"#
        let issues = try OsaurusClient.parseIssues(response, passage: passage)
        XCTAssertEqual(issues.map(\.category), [.grammar, .style])
        XCTAssertTrue(issues.allSatisfy { $0.explanation.isEmpty })
        let corrections = GrammarText.locate(issues, chunk: passage, offset: 0)
        var result = passage as NSString
        for correction in corrections.sorted(by: { $0.range.location > $1.range.location }) {
            result = result.replacingCharacters(in: correction.range, with: correction.issue.replacement) as NSString
        }
        XCTAssertEqual(result as String, "Grüße 🌊. Sie hat einen Brief. She was tired.")
        XCTAssertTrue(try OsaurusClient.parseIssues(#"{"issues":[]}"#, passage: passage).isEmpty)
    }

    func testSparseResponsesStillRejectAmbiguousQuotesAndIgnoreWhitespace() throws {
        XCTAssertThrowsError(try OsaurusClient.parseIssues(#"{"issues":[{"original":"Go home.","replacement":"Head home.","kind":"style"}]}"#, passage: "Go home. Go home."))
        XCTAssertThrowsError(try OsaurusClient.parseIssues(#"{"issues":[{"original":"Not in input","replacement":"New text"}]}"#, passage: "Hello."))
        XCTAssertTrue(try OsaurusClient.parseIssues(#"{"issues":[{"original":"Hello. ","replacement":"Hello.","kind":"style"}]}"#, passage: "Hello. ").isEmpty)
        let extended = try OsaurusClient.parseIssues(#"{"issues":[{"original":"Go home. Go home.","replacement":"Go home. Head home.","kind":"style"}]}"#, passage: "Go home. Go home.")
        XCTAssertEqual(extended.count, 1)
        let rename = try OsaurusClient.parseIssues(#"{"issues":[{"original":"Elisa waits.","replacement":"Elias waits.","kind":"grammar"}]}"#, passage: "Elisa waits.")
        XCTAssertTrue(WritingIdentityGuard.protect(rename, names: ["Elisa", "Elias"], language: "en").isEmpty)
    }

    func testRequestsUseSparseFormatBoundedOutputAndKeepAuthorContext() throws {
        let context = WritingReviewContext(brief: "Use spare prose.", background: "Elisa lives alone.", document: "chapter prose", characters: [WritingCharacterRecord(name: "Elisa", pronouns: "sie/ihr", summary: "At the harbour")]).forPassage("Elisa wartet.")
        for language in ["en", "de"] {
            let request = try OsaurusClient.reviewRequest(baseURL: "http://127.0.0.1:1337/v1", text: "Elisa wartet.", language: language, model: LocalModel(id: "local-model", owned_by: "osaurus"), context: context, includeStyle: false)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(messages[1]["content"], "Elisa wartet.")
            let system = try XCTUnwrap(messages[0]["content"])
            XCTAssertTrue(system.contains(#"{"issues":[]}"#))
            XCTAssertFalse(system.contains("revisedText"))
            XCTAssertFalse(system.contains(#""explanation":""#))
            for detail in ["Use spare prose.", "Elisa lives alone.", "sie/ihr", "At the harbour"] { XCTAssertTrue(system.contains(detail)) }
            XCTAssertTrue(system.contains(language == "de" ? "keine optionalen Stiländerungen" : "no optional style changes"))
            XCTAssertEqual(body["max_tokens"] as? Int, 1024)
            XCTAssertEqual(body["reasoning_effort"] as? String, "none")
            XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        }
        let empty = WritingReviewContext()
        XCTAssertEqual(empty.osaurusSystemMessage, "Field: writing")
        let large = WritingReviewContext(brief: String(repeating: "b", count: 4000), background: String(repeating: "c", count: 5000))
        XCTAssertFalse(large.osaurusSystemMessage.contains(String(repeating: "b", count: 3001)))
        XCTAssertFalse(large.osaurusSystemMessage.contains(String(repeating: "c", count: 3501)))
        let request = try OsaurusClient.reviewRequest(baseURL: "http://localhost:1337/v1", text: String(repeating: "Grüße 🌊. ", count: 500), language: "de", model: LocalModel(id: "local-model"), context: empty, includeStyle: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
    }

    func testCachedReviewsRequireIdenticalTextSettingsAndContext() {
        let key = WritingReviewRequestCache.Key(text: "She go home.", language: "en", model: LocalModel(id: "local-model", owned_by: "osaurus"), baseURL: "http://localhost:1337/v1", includeStyle: true, context: WritingReviewContext())
        let issues = [GrammarIssue(original: key.text, replacement: "She goes home.", kind: .grammar)]
        var cache = WritingReviewRequestCache()
        cache.store(issues, for: key)
        XCTAssertEqual(cache.result(for: key), issues)
        var variants: [WritingReviewRequestCache.Key] = []
        var changed = key; changed.text += " "; variants.append(changed)
        changed = key; changed.language = "de"; variants.append(changed)
        changed = key; changed.model.id = "another-model"; variants.append(changed)
        changed = key; changed.baseURL = "http://localhost:1338/v1"; variants.append(changed)
        changed = key; changed.includeStyle = false; variants.append(changed)
        changed = key; changed.context.brief = "Another voice"; variants.append(changed)
        changed = key; changed.context.characters = [WritingCharacterRecord(name: "Elisa", pronouns: "she/her", summary: "New profile")]; variants.append(changed)
        changed = key; changed.context.projectKey = "other-project"; variants.append(changed)
        for variant in variants { XCTAssertNil(cache.result(for: variant)) }
        cache.store([], for: key)
        XCTAssertEqual(cache.result(for: key), [], "Clean results also avoid another model request")
    }

    func testCacheEvictsLeastRecentlyUsedReview() {
        var cache = WritingReviewRequestCache(capacity: 2)
        let first = WritingReviewRequestCache.Key(text: "First", language: "en", model: LocalModel(id: "local-model"), baseURL: "http://localhost:1337/v1", includeStyle: true, context: WritingReviewContext())
        var second = first; second.text = "Second"
        var third = first; third.text = "Third"
        cache.store([], for: first); cache.store([], for: second)
        XCTAssertNotNil(cache.result(for: first))
        cache.store([], for: third)
        XCTAssertNil(cache.result(for: second))
        XCTAssertNotNil(cache.result(for: first))
        XCTAssertNotNil(cache.result(for: third))
    }
}
