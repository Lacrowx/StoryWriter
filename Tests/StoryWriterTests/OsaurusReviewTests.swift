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
            for detail in ["Elisa lives alone.", "sie/ihr", "At the harbour"] { XCTAssertTrue(system.contains(detail)) }
            XCTAssertFalse(system.contains("Use spare prose."), "A style brief must not steer a grammar-only review")
            XCTAssertTrue(system.contains(language == "de" ? "keine optionalen Stiländerungen" : "no optional style changes"))
            XCTAssertEqual(body["max_tokens"] as? Int, 512)
            XCTAssertEqual(body["temperature"] as? Int, 0)
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
        let style = try OsaurusClient.reviewRequest(baseURL: "http://localhost:1337/v1", text: "Elisa wartet.", language: "de", model: LocalModel(id: "local-model"), context: context, includeStyle: true)
        let styleBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(style.httpBody)) as? [String: Any])
        let styleMessages = try XCTUnwrap(styleBody["messages"] as? [[String: String]])
        XCTAssertTrue(styleMessages[0]["content"]?.contains("Use spare prose.") == true)
    }

    func testCommonWrappersAndTrailingCommasPreserveLiteralStrings() throws {
        let passage = #"She go home. He wrote "{bracket,}". Grüße 🌊."#
        let rows = #"[{"original":"She go home.","replacement":"She goes home.","kind":"GRAMMAR",}, {"original":"He wrote \"{bracket,}\".","replacement":"He wrote \"{brackets,}\".","explanation":null,"kind":"style",},]"#
        for content in [rows, "Here is the review:\n```json\n{\"issues\":\(rows),}\n```", "{\"corrections\":\(rows)}"] {
            let issues = try OsaurusClient.parseIssues(content, passage: passage)
            XCTAssertEqual(issues.count, 2)
            XCTAssertEqual(issues[0].replacement, "She goes home.")
            XCTAssertEqual(issues[1].replacement, #"He wrote "{brackets,}"."#)
        }
        let single = #"{"original":"She go home.","replacement":"She goes home."}"#
        XCTAssertEqual(try OsaurusClient.parseIssues(single, passage: passage).count, 1)
        XCTAssertTrue(try OsaurusClient.parseIssues("[]", passage: passage).isEmpty)
    }

    func testReasoningAndExamplesDoNotBecomeSuggestions() throws {
        let correction = #"{"issues":[{"original":"She go home.","replacement":"She goes home."}]}"#
        let passage = "She go home."
        XCTAssertEqual(try OsaurusClient.parseIssues("<think>Example {\"issues\":[]} with braces</think>\n" + correction, passage: passage).count, 1)
        XCTAssertEqual(try OsaurusClient.parseIssues("Example: {\"issues\":[]}\nActual review: " + correction, passage: passage).count, 1)
        XCTAssertTrue(try OsaurusClient.parseIssues(correction + "\nFinal: {\"issues\":[]}", passage: passage).isEmpty)
        for response in ["<think>" + correction, "{\"result\":" + correction + "}", "{\"issues\":[{\"original\":\"She go home.\",\"replacement\":\"She goes home.\"}", "{\"issues\":null}", "No changes needed."] {
            XCTAssertThrowsError(try OsaurusClient.parseIssues(response, passage: passage))
        }
    }

    func testMalformedEntriesDoNotDiscardIndependentValidCorrections() throws {
        let response = #"{"issues":[null, {"original":"She go home.","replacement":42}, {"original":"She go home.","replacement":"She goes home.","kind":null,"explanation":[]}, {"original":"Not in the input","replacement":"Invented text"}, {"original":"She go home.","replacement":"She goes home."}]}"#
        let issues = try OsaurusClient.parseIssues(response, passage: "She go home.")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].category, .grammar)
        XCTAssertThrowsError(try OsaurusClient.parseIssues(#"{"issues":[{"original":"She go home.","replacement":null}]}"#, passage: "She go home."))
        XCTAssertThrowsError(try OsaurusClient.parseIssues(#"{"issues":[{}]}"#, passage: "She go home."))
    }

    func testGrammarOnlyFilteringAndOverlapsKeepTargetedCorrections() throws {
        let passage = "She go home. It was very quiet."
        let response = #"{"issues":[{"original":"She go home. It was very quiet.","replacement":"She goes home. Silence fell.","kind":"style"},{"original":"She go","replacement":"She goes","kind":"grammar"},{"original":"It was very quiet.","replacement":"It was quiet.","kind":"style"}]}"#
        let all = try OsaurusClient.parseIssues(response, passage: passage)
        XCTAssertEqual(all.map(\.original), ["She go", "It was very quiet."])
        let grammar = try OsaurusClient.parseIssues(response, passage: passage, includeStyle: false)
        XCTAssertEqual(grammar.map(\.replacement), ["She goes"])
        XCTAssertTrue(try OsaurusClient.parseIssues(#"{"issues":[{"original":"It was very quiet.","replacement":"It was quiet.","kind":"style"}]}"#, passage: passage, includeStyle: false).isEmpty)
        XCTAssertThrowsError(try OsaurusClient.parseIssues(#"{"issues":[{"original":"ana","replacement":"anna"}]}"#, passage: "banana"), "Even overlapping repeated quotes are ambiguous")
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
