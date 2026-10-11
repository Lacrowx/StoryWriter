import XCTest
import Foundation
@testable import StoryWriter

private final class ReviewProtocol: URLProtocol {
    struct Reply {
        var content: String
        var finish = "stop"
        var status = 200
        var error: URLError? = nil
    }
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    private static let lock = NSLock()
    static func reset(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(captured)
        let reply = Self.replies.isEmpty ? Reply(content: "Unexpected extra request", status: 500) : Self.replies.removeFirst()
        Self.lock.unlock()
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let body: [String: Any] = ["choices": [["message": ["content": reply.content], "finish_reason": reply.finish]]]
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OsaurusRecoveryTests: XCTestCase {
    private let passage = "She go home."
    private let valid = #"{"issues":[{"original":"She go home.","replacement":"She goes home.","kind":"grammar"}]}"#
    private let model = LocalModel(id: "fixture-model", owned_by: "osaurus")

    private func client() -> OsaurusClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewProtocol.self]
        return OsaurusClient(baseURL: "http://127.0.0.1:1337/v1", session: URLSession(configuration: configuration))
    }
    private func body(_ index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(ReviewProtocol.requests[index].httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor func testUnusableFormatOrQuotesRetryOnceWithOriginalPassageAndContext() async throws {
        for bad in ["Unstructured advice", #"{"issues":[{"original":"She gone home.","replacement":"She goes home."}]}"#] {
            ReviewProtocol.reset([.init(content: bad), .init(content: valid)])
            let issues = try await client().review(text: passage, language: "en", model: model, context: WritingReviewContext(brief: "Keep my voice."))
            XCTAssertEqual(issues.map(\.replacement), ["She goes home."])
            XCTAssertEqual(ReviewProtocol.requests.count, 2)
            let first = try body(0), second = try body(1)
            let messages = try XCTUnwrap(second["messages"] as? [[String: String]])
            XCTAssertEqual(messages[1]["content"], passage)
            XCTAssertTrue(messages[0]["content"]?.contains("previous attempt was unusable") == true)
            XCTAssertTrue(messages[0]["content"]?.contains("Keep my voice.") == true)
            XCTAssertEqual(second["max_tokens"] as? Int, (first["max_tokens"] as? Int).map { $0 * 2 })
        }
    }

    @MainActor func testTruncatedResponseRetriesInsteadOfReturningPartialResults() async throws {
        ReviewProtocol.reset([.init(content: valid, finish: "length"), .init(content: valid)])
        let issues = try await client().review(text: passage, language: "en", model: model)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(ReviewProtocol.requests.count, 2)
    }

    @MainActor func testValidAndCleanRepliesNeedOnlyOneRequest() async throws {
        for reply in [valid, #"{"issues":[]}"#] {
            ReviewProtocol.reset([.init(content: reply)])
            let issues = try await client().review(text: passage, language: "en", model: model)
            XCTAssertEqual(issues.count, reply == valid ? 1 : 0)
            XCTAssertEqual(ReviewProtocol.requests.count, 1)
        }
    }

    @MainActor func testRecoveryIsBoundedAndDoesNotRetryConnectionErrors() async {
        for replies in [
            [ReviewProtocol.Reply(content: "Bad"), .init(content: "Still bad")],
            [.init(content: "", status: 503)],
            [.init(content: "", error: URLError(.cannotConnectToHost))],
            [.init(content: "", error: URLError(.cancelled))]
        ] {
            ReviewProtocol.reset(replies)
            do {
                _ = try await client().review(text: passage, language: "en", model: model)
                XCTFail("Expected review to fail")
            } catch {
                XCTAssertEqual(ReviewProtocol.requests.count, replies.count)
                if replies.first?.error?.code == .cancelled { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    @MainActor func testRecoveredEditsStillProtectIdentityAndHonorStyleToggle() async throws {
        let response = #"{"issues":[{"original":"Elisa go home.","replacement":"Elias goes home.","kind":"grammar"},{"original":"It was very quiet.","replacement":"It was quiet.","kind":"style"}]}"#
        ReviewProtocol.reset([.init(content: "Bad"), .init(content: response)])
        let issues = try await client().review(text: "Elisa go home. It was very quiet.", language: "en", model: model, context: WritingReviewContext(protectedTerms: ["Elisa", "Elias"]), includeStyle: false)
        XCTAssertEqual(issues.map(\.replacement), ["Elisa goes home."])
        XCTAssertEqual(ReviewProtocol.requests.count, 2)
    }

    @MainActor func testCancelledReviewSendsNoRequest() async {
        ReviewProtocol.reset([.init(content: valid)])
        let task = Task { try await client().review(text: passage, language: "en", model: model) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(ReviewProtocol.requests.isEmpty)
    }
}
