import Foundation
import SwiftUI

enum SuggestionKind: String, Codable { case spelling, grammar, style
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SuggestionKind(rawValue: raw.lowercased()) ?? .grammar
    }
    var label: String { switch self { case .spelling: return "Spelling"; case .grammar: return "Grammar"; case .style: return "Style" } }
    var color: Color { self == .style ? .blue : .orange }
}

struct LocalModel: Codable, Identifiable, Equatable {
    var id: String
    var owned_by: String?
    var isLocal: Bool {
        ["osaurus", "local", "mlx", "apple", "apple-intelligence"].contains(owned_by?.lowercased() ?? "") && !id.hasPrefix("remote:")
    }
    var isSmall: Bool { id.range(of: "(^|[-_])[1-4](\\.[0-9]+)?b([_-]|$)", options: .regularExpression) != nil }
}

struct GrammarIssue: Codable, Identifiable, Equatable {
    var id: String { original + "→" + replacement }
    var original: String
    var replacement: String
    var explanation: String = ""
    var kind: SuggestionKind? = nil
    var category: SuggestionKind { kind ?? .grammar }

    private enum CodingKeys: String, CodingKey { case original, replacement, explanation, kind }
    init(original: String, replacement: String, explanation: String = "", kind: SuggestionKind? = nil) {
        self.original = original; self.replacement = replacement; self.explanation = explanation; self.kind = kind
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        original = try values.decode(String.self, forKey: .original)
        replacement = try values.decode(String.self, forKey: .replacement)
        explanation = try values.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        kind = try values.decodeIfPresent(SuggestionKind.self, forKey: .kind)
    }
}

struct ProofreadingResult: Codable { var issues: [GrammarIssue] }
struct ModelList: Codable { var data: [LocalModel] }
struct CompletionResponse: Codable {
    struct Choice: Codable { struct Message: Codable { var content: String? }; var message: Message; var finish_reason: String? }
    var choices: [Choice]
}

final class LoopbackSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OsaurusClient {
    var baseURL: String
    private var urlSession: URLSession
    private static let delegate = LoopbackSessionDelegate()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer osaurus-local"]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    init(baseURL: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.urlSession = session ?? Self.session
    }

    static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""),
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ProjectError.invalid("Use Osaurus's local address, for example http://127.0.0.1:1337/v1.")
        }
        return url
    }

    func models() async throws -> [LocalModel] {
        let endpoint = try Self.validatedURL(baseURL).appendingPathComponent("models")
        var request = URLRequest(url: endpoint); request.timeoutInterval = 8
        let data = try await requestData(request)
        return try JSONDecoder().decode(ModelList.self, from: data).data.filter(\.isLocal).sorted { $0.id < $1.id }
    }

    func review(text: String, language: String, model: LocalModel, context: WritingReviewContext = WritingReviewContext(), includeStyle: Bool = true) async throws -> [GrammarIssue] {
        guard model.isLocal else { throw ProjectError.invalid("Choose a local Osaurus model.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard text.count <= 6000 else { throw ProjectError.invalid("Select a passage of up to 6,000 characters for a small local model.") }
        let context = context.forPassage(text)
        let protectedNames = context.protectedTerms + WritingIdentityGuard.detectedNames(in: text, language: language)
        try Task.checkCancellation()
        let spelling = await SpellingReview.candidates(text, language: language, protectedTerms: protectedNames)
        try Task.checkCancellation()
        // A fresh, stricter request repairs unusable output once. Network and
        // HTTP failures are not formatting failures and are never retried here.
        for attempt in 0...1 {
            try Task.checkCancellation()
            let request = try Self.reviewRequest(baseURL: baseURL, text: text, language: language, model: model, context: context, includeStyle: includeStyle, spelling: spelling, retry: attempt == 1)
            let data = try await requestData(request)
            try Task.checkCancellation()
            do {
                guard let response = try? JSONDecoder().decode(CompletionResponse.self, from: data),
                      let choice = response.choices.first, let content = choice.message.content else { throw WritingReviewResponseError.format }
                guard choice.finish_reason != "length" else { throw WritingReviewResponseError.truncated }
                let issues = try Self.parseIssues(content, passage: text, includeStyle: includeStyle)
                let safe = WritingIdentityGuard.protect(issues, names: protectedNames, language: language)
                return SpellingReview.supplement(safe, with: spelling, passage: text)
            } catch is WritingReviewResponseError where attempt == 0 { continue }
        }
        throw WritingReviewResponseError.format
    }

    static func reviewRequest(baseURL: String, text: String, language: String, model: LocalModel, context: WritingReviewContext, includeStyle: Bool, spelling: [GrammarIssue] = [], retry: Bool = false) throws -> URLRequest {
        let system = WritingReviewPrompt.system(language: language, context: context, includeStyle: includeStyle, spelling: spelling, retry: retry)
        let tokenLimit = min(4096, max(512, text.utf8.count + 256))
        let body: [String: Any] = ["model": model.id, "messages": [["role": "system", "content": system], ["role": "user", "content": text]], "temperature": 0, "max_tokens": retry ? min(8192, tokenLimit * 2) : tokenLimit, "stream": false, "reasoning_effort": "none", "chat_template_kwargs": ["enable_thinking": false]]
        var request = URLRequest(url: try validatedURL(baseURL).appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }


    static func parseRevision(_ content: String, passage: String) throws -> [GrammarIssue] {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start <= end,
              let data = String(content[start...end]).data(using: .utf8) else { throw ProjectError.invalid("The model did not return a usable writing review.") }
        let revision: RevisedWritingResult
        do { revision = try JSONDecoder().decode(RevisedWritingResult.self, from: data) }
        catch { throw ProjectError.invalid("The model's review format was invalid. Your writing has not been changed.") }
        guard !revision.revisedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError.invalid("The model returned an empty revision. Your writing has not been changed.") }
        return WritingReviewDiff.issues(original: passage, revision: revision)
    }

    static func parseIssues(_ content: String, passage: String, includeStyle: Bool = true) throws -> [GrammarIssue] {
        try WritingReviewResponse.issues(content, passage: passage, includeStyle: includeStyle)
    }

    private func requestData(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProjectError.invalid("Osaurus returned an invalid response.") }
            guard (200...299).contains(http.statusCode) else { throw ProjectError.invalid("Osaurus returned HTTP \(http.statusCode). Check that its server is running and the local model is available.") }
            return data
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw ProjectError.invalid("Could not reach Osaurus. Open Osaurus, start its local server, then refresh the models. \(error.localizedDescription)")
        }
    }
}

struct ProofreadingPanel: View {
    @ObservedObject var editor: EditorController
    var chapter: Chapter
    var body: some View {
        if let session = editor.grammar { InlineReviewPanel(session: session) }
        else { ProgressView().frame(width: 310) }
    }
}

struct InlineReviewPanel: View {
    @ObservedObject var session: InlineGrammarSession
    @ObservedObject private var service = LocalGrammarService.shared
    @AppStorage("writingLanguage") private var language = "auto"
    @State private var scope: GrammarScope = .paragraph
    @Environment(\.writingReviewContext) private var writingContext
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("Writing review", systemImage: "text.badge.checkmark").font(.headline); Spacer(); Text(service.backend.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
            Text("Corrections appear in your text. Click a marked passage to accept or dismiss it.").font(.caption).foregroundStyle(.secondary)
            Picker("Language", selection: $language) { Text("Automatic").tag("auto"); Text("English").tag("en"); Text("Deutsch").tag("de") }
            WritingBackendControls()
            Toggle("Check automatically while editing", isOn: $service.automatic)
            Toggle("Suggest style improvements", isOn: $service.includeStyle)
            Text(service.backend == .osaurus ? "The changed paragraph is reviewed on your local Osaurus server. Your project's brief guides tone and style." : "The changed paragraph is reviewed on this Mac. Your project's brief guides tone and style.").font(.caption2).foregroundStyle(.secondary)
            Text("Name lookup searches all \(writingContext.characters.count) project character records and includes matching profiles and pronouns.").font(.caption2).foregroundStyle(.secondary)
            Picker("Scope", selection: $scope) { ForEach(GrammarScope.allCases) { Text($0.rawValue).tag($0) } }
            Button { session.review(scope) } label: { HStack { if session.checking { ProgressView().controlSize(.small) }; Text(session.checking ? "Checking…" : "Review text") }.frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(session.checking)
            if session.checking { Button("Cancel") { session.cancel() }.font(.caption) }
            if !session.selectedCorrections(scope).isEmpty {
                Button("Accept all in \(scope.rawValue.lowercased())") { session.accept(scope) }.frame(maxWidth: .infinity)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = session.message ?? service.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if session.reviewed && session.corrections.isEmpty && session.message == nil { Text("No suggestions returned for the reviewed text.").foregroundStyle(.secondary) }
                    ForEach(session.corrections) { correction in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(correction.issue.category.label).font(.caption.weight(.semibold)).foregroundStyle(correction.issue.category.color)
                            Button { session.show(correction) } label: { Text(correction.issue.original).strikethrough().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                            Text(correction.issue.replacement).foregroundStyle(AppTheme.accent)
                            if !correction.issue.explanation.isEmpty { Text(correction.issue.explanation).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("Accept") { session.accept(correction.id) }
                                Button("Dismiss") { session.dismiss(correction.id) }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Text("Accepting a group is one undo action (⌘Z). Changed suggestions are removed before rechecking.").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(width: 310).background(.thinMaterial)
        .task(id: service.backend) { await service.ensureConnection() }
    }
}

struct WritingBackendControls: View {
    @ObservedObject private var service = LocalGrammarService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Review with", selection: $service.backend) { ForEach(WritingBackend.allCases) { Text($0.label).tag($0) } }
            if service.backend == .osaurus {
                HStack {
                    Picker("Local model", selection: $service.modelID) { Text("Choose a model").tag(""); ForEach(service.models) { Text($0.id).tag($0.id) } }
                    Button { Task { await service.connect() } } label: { Image(systemName: "arrow.clockwise") }.disabled(service.connecting)
                }
            } else if service.backend == .mlx {
                MLXModelPicker()
            } else {
                Text(AppleWritingModel.unavailabilityReason ?? "Apple's on-device model is ready. No server is needed.").font(.caption).foregroundStyle(.secondary)
            }
        }.task(id: service.backend) { await service.ensureConnection() }
    }
}
