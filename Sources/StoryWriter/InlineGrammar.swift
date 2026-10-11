import AppKit
import SwiftUI
import NaturalLanguage

enum GrammarScope: String, CaseIterable, Identifiable {
    case sentence = "Sentence", paragraph = "Paragraph", selection = "Selected passage", document = "Entire text"
    var id: String { rawValue }
}

enum WritingBackend: String, CaseIterable, Identifiable {
    case osaurus, apple
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple · on device" : "Osaurus · local server" }
}

struct LocatedCorrection: Identifiable, Equatable {
    var id = UUID()
    var issue: GrammarIssue
    var range: NSRange
}

struct CachedGrammarResult {
    var snapshot: String
    var corrections: [LocatedCorrection]
    var reviewed: Bool
    var context = WritingReviewContext()
}

private struct GrammarNamespaceKey: EnvironmentKey { static let defaultValue = "workspace" }
extension EnvironmentValues {
    var grammarNamespace: String {
        get { self[GrammarNamespaceKey.self] }
        set { self[GrammarNamespaceKey.self] = newValue }
    }
}
extension Notification.Name { static let grammarCacheChanged = Notification.Name("StoryWriter.grammarCacheChanged") }

enum GrammarText {
    static func range(for scope: GrammarScope, in text: String, selection: NSRange) -> NSRange {
        let string = text as NSString
        let safe = NSRange(location: min(selection.location, string.length), length: min(selection.length, max(0, string.length - selection.location)))
        switch scope {
        case .document: return NSRange(location: 0, length: string.length)
        case .selection: return safe
        case .paragraph: return string.paragraphRange(for: safe)
        case .sentence:
            guard !text.isEmpty else { return NSRange(location: 0, length: 0) }
            var result: NSRange?
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
                let candidate = NSRange(range, in: text)
                if NSLocationInRange(min(safe.location, max(0, string.length - 1)), candidate) { result = candidate; stop = true }
            }
            return result ?? string.paragraphRange(for: safe)
        }
    }

    static func chunks(_ text: String, range: NSRange, limit: Int = 4000) -> [(String, Int)] {
        let string = text as NSString
        guard NSMaxRange(range) <= string.length, range.length > 0 else { return [] }
        var result: [(String, Int)] = [], start = range.location
        while start < NSMaxRange(range) {
            let maximum = min(NSMaxRange(range), start + limit)
            var end = maximum
            if maximum < NSMaxRange(range) {
                let newline = string.range(of: "\n", options: .backwards, range: NSRange(location: start, length: maximum - start))
                if newline.location != NSNotFound && newline.location > start { end = newline.location + 1 }
                else {
                    let space = string.range(of: " ", options: .backwards, range: NSRange(location: start, length: maximum - start))
                    if space.location != NSNotFound && space.location > start { end = space.location + 1 }
                }
                // Never divide a surrogate pair or a composed character.
                let character = string.rangeOfComposedCharacterSequence(at: min(end, string.length - 1))
                if character.location < end { end = character.location }
            }
            if end <= start { end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: start)) }
            result.append((string.substring(with: NSRange(location: start, length: end - start)), start)); start = end
        }
        return result
    }

    static func locate(_ issues: [GrammarIssue], chunk: String, offset: Int) -> [LocatedCorrection] {
        issues.compactMap { issue in
            let range = (chunk as NSString).range(of: issue.original)
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            return LocatedCorrection(issue: issue, range: NSRange(location: range.location + offset, length: range.length))
        }
    }

    static func rebase(_ corrections: [LocatedCorrection], old: String, new: String) -> [LocatedCorrection] {
        guard old != new else { return corrections }
        let oldChars = Array(old.utf16), newChars = Array(new.utf16)
        var prefix = 0
        while prefix < min(oldChars.count, newChars.count), oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldChars.count - prefix, newChars.count - prefix), oldChars[oldChars.count - suffix - 1] == newChars[newChars.count - suffix - 1] { suffix += 1 }
        let oldEnd = oldChars.count - suffix, delta = newChars.count - oldChars.count
        func isWord(_ characters: [UInt16], _ index: Int) -> Bool {
            guard characters.indices.contains(index), let scalar = Unicode.Scalar(characters[index]) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
        }
        return corrections.compactMap { correction in
            var updated = correction
            if NSMaxRange(correction.range) <= prefix {
                // Appending letters to the quoted word invalidates its old suggestion.
                if NSMaxRange(correction.range) == prefix && isWord(oldChars, prefix - 1) && isWord(newChars, prefix) { return nil }
            }
            else if correction.range.location >= oldEnd {
                updated.range.location += delta
                if correction.range.location == oldEnd && isWord(newChars, updated.range.location - 1) && isWord(oldChars, correction.range.location) { return nil }
            }
            else { return nil }
            guard updated.range.location >= 0, NSMaxRange(updated.range) <= newChars.count,
                  (new as NSString).substring(with: updated.range) == updated.issue.original else { return nil }
            return updated
        }
    }

    static func replacement(_ source: NSAttributedString, with replacement: String) -> NSAttributedString {
        // Apply a character diff so emphasis, links, and styles on unchanged words survive.
        let originalCharacters = Array(source.string), newCharacters = Array(replacement)
        let difference = newCharacters.difference(from: originalCharacters)
        let result = NSMutableAttributedString(attributedString: source)
        var offsets = [0]
        for character in originalCharacters { offsets.append(offsets.last! + String(character).utf16.count) }
        for change in difference.removals.sorted(by: { $0.offset > $1.offset }) {
            if case .remove(let offset, _, _) = change { result.deleteCharacters(in: NSRange(location: offsets[offset], length: offsets[offset + 1] - offsets[offset])) }
        }
        for change in difference.insertions.sorted(by: { $0.offset < $1.offset }) {
            if case .insert(let offset, let character, _) = change {
                let current = Array(result.string)
                let location = current.prefix(offset).reduce(0) { $0 + String($1).utf16.count }
                var attributes = result.length > 0 ? result.attributes(at: min(location, result.length - 1), effectiveRange: nil) : source.length > 0 ? source.attributes(at: 0, effectiveRange: nil) : WritingStyle.attributes
                // A project link identifies specific words, not a style that
                // new prose may inherit from its nearest neighbour.
                if ProjectTagReference.from(attributes[.link]) != nil { attributes.removeValue(forKey: .link) }
                result.insert(NSAttributedString(string: String(character), attributes: attributes), at: location)
            }
        }
        restoreProjectTags(from: source, to: result)
        return result
    }

    private static func restoreProjectTags(from source: NSAttributedString, to result: NSMutableAttributedString) {
        var restored: [(NSRange, Any)] = []
        let original = source.string as NSString, revised = result.string as NSString
        source.enumerateAttribute(.link, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            guard let reference = ProjectTagReference.from(value), let value else { return }
            let label = original.substring(with: range)
            var search = NSRange(location: 0, length: revised.length)
            var matches: [NSRange] = []
            while search.length > 0 {
                let found = revised.range(of: label, options: [], range: search)
                guard found.location != NSNotFound else { break }
                matches.append(found)
                search = NSRange(location: NSMaxRange(found), length: revised.length - NSMaxRange(found))
            }
            // Surviving runs disambiguate repeated mentions. If a rewrite moves
            // the whole label, restore it only when both texts identify it uniquely.
            for match in matches {
                var survived = true
                result.enumerateAttribute(.link, in: match) { current, _, _ in
                    if ProjectTagReference.from(current) != reference { survived = false }
                }
                if survived || (matches.count == 1 && source.string.components(separatedBy: label).count == 2) {
                    restored.append((match, value))
                }
            }
        }
        var oldRuns: [NSRange] = []
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if ProjectTagReference.from(value) != nil { oldRuns.append(range) }
        }
        for range in oldRuns { result.removeAttribute(.link, range: range) }
        for (range, value) in restored { result.addAttribute(.link, value: value, range: range) }
    }
}

private extension CollectionDifference.Change {
    var offset: Int { switch self { case .insert(let offset, _, _), .remove(let offset, _, _): return offset } }
}

@MainActor
final class LocalGrammarService: ObservableObject {
    static let shared = LocalGrammarService()
    @Published var models: [LocalModel] = []
    @Published var connecting = false
    @Published var backend: WritingBackend {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "writingReviewBackend"); message = nil; cachedResults.removeAll() }
    }
    @Published var message: String?
    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "osaurusModel"); if modelID != oldValue { cachedResults.removeAll() } }
    }
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticGrammar") }
    }
    @Published var includeStyle: Bool {
        didSet { UserDefaults.standard.set(includeStyle, forKey: "reviewWritingStyle"); cachedResults.removeAll() }
    }
    var baseURL: String { UserDefaults.standard.string(forKey: "osaurusURL") ?? "http://127.0.0.1:1337/v1" }
    var language: String { UserDefaults.standard.string(forKey: "writingLanguage") ?? "auto" }
    var selectedModel: LocalModel? { models.first { $0.id == modelID } }
    var chunkLimit: Int { backend == .apple ? 1200 : 4000 }
    private var connectionTask: Task<Void, Never>?
    private var requestCache = WritingReviewRequestCache()
    var cachedResults: [String: CachedGrammarResult] = [:]

    init() {
        backend = WritingBackend(rawValue: UserDefaults.standard.string(forKey: "writingReviewBackend") ?? "") ?? .osaurus
        modelID = UserDefaults.standard.string(forKey: "osaurusModel") ?? ""
        automatic = UserDefaults.standard.object(forKey: "automaticGrammar") as? Bool ?? true
        includeStyle = UserDefaults.standard.object(forKey: "reviewWritingStyle") as? Bool ?? true
    }
    func connect() async {
        guard !connecting else { return }
        connecting = true; defer { connecting = false }
        do {
            models = try await OsaurusClient(baseURL: baseURL).models()
            if selectedModel == nil { modelID = models.first(where: \.isSmall)?.id ?? models.first?.id ?? "" }
            message = models.isEmpty ? "Download a local model in Osaurus, then refresh." : nil
        } catch { models = []; message = error.localizedDescription }
    }
    func ensureConnection() async {
        guard backend == .osaurus else { return }
        if selectedModel != nil { return }
        if let connectionTask { await connectionTask.value; return }
        let task = Task { await connect() }; connectionTask = task; await task.value; connectionTask = nil
    }
    func review(_ text: String, context: WritingReviewContext = WritingReviewContext()) async throws -> [GrammarIssue] {
        let selectedBackend = backend, style = includeStyle
        let actualLanguage: String
        if language == "auto" {
            let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
            actualLanguage = recognizer.dominantLanguage == .german ? "de" : "en"
        } else { actualLanguage = language }
        if selectedBackend == .apple { return try await AppleWritingModel.review(text, language: actualLanguage, context: context, includeStyle: style) }
        await ensureConnection()
        guard let model = selectedModel else { throw ProjectError.invalid(message ?? "Choose a local model in the proofreading panel.") }
        try Task.checkCancellation()
        let endpoint = baseURL
        let key = WritingReviewRequestCache.Key(text: text, language: actualLanguage, model: model, baseURL: endpoint, includeStyle: style, context: context)
        if let cached = requestCache.result(for: key) { return cached }
        let issues = try await OsaurusClient(baseURL: endpoint).review(text: text, language: actualLanguage, model: model, context: context, includeStyle: style)
        try Task.checkCancellation()
        requestCache.store(issues, for: key)
        return issues
    }
    func publishResult(_ result: CachedGrammarResult, key: String) {
        cachedResults[key] = result
        NotificationCenter.default.post(name: .grammarCacheChanged, object: key)
    }
}

@MainActor
final class InlineGrammarSession: NSObject, ObservableObject {
    weak var view: ManuscriptTextView?
    @Published var corrections: [LocatedCorrection] = []
    @Published var checking = false
    @Published var message: String?
    @Published var reviewed = false
    @Published private var selection = NSRange(location: 0, length: 0)
    private(set) var snapshot = ""
    private var task: Task<Void, Never>?
    private var applying = false
    private var popover: NSPopover?
    var popoverVisible: Bool { popover?.isShown == true }
    private var continuationTask: Task<Void, Never>?
    private var cacheObserver: NSObjectProtocol?
    let documentKey: String
    var documentLabel = "text"
    var context: WritingReviewContext {
        didSet {
            if context != oldValue {
                let resumeAutomaticReview = pending
                resetReview()
                if resumeAutomaticReview { textChanged() }
            }
        }
    }
    @Published var pending = false

    init(view: ManuscriptTextView, documentLabel: String = "text", documentKey: String = UUID().uuidString, context: WritingReviewContext = WritingReviewContext()) {
        self.view = view; self.documentLabel = documentLabel; self.documentKey = documentKey; snapshot = view.string
        self.context = context
        super.init()
        if let cached = LocalGrammarService.shared.cachedResults[documentKey], cached.context == context {
            corrections = GrammarText.rebase(cached.corrections, old: cached.snapshot, new: view.string); reviewed = cached.reviewed && cached.snapshot == view.string
        }
        cacheObserver = NotificationCenter.default.addObserver(forName: .grammarCacheChanged, object: nil, queue: .main) { [weak self] notification in
            guard let key = notification.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, key == self.documentKey, let view = self.view, let cached = LocalGrammarService.shared.cachedResults[key] else { return }
                guard cached.context == self.context else { self.resetReview(); return }
                self.corrections = GrammarText.rebase(cached.corrections, old: cached.snapshot, new: view.string)
                self.snapshot = view.string; self.reviewed = cached.reviewed && cached.snapshot == view.string; self.drawMarks()
            }
        }
    }
    deinit { task?.cancel(); continuationTask?.cancel(); if let cacheObserver { NotificationCenter.default.removeObserver(cacheObserver) } }

    func textChanged(automatic: Bool = true) {
        guard let view else { return }
        let latest = view.string
        if !applying && latest != snapshot { reviewed = false; message = nil }
        corrections = GrammarText.rebase(corrections, old: snapshot, new: latest); snapshot = latest
        drawMarks()
        guard !applying else { return }
        continuationTask?.cancel()
        task?.cancel(); checking = false; pending = false
        if automatic && LocalGrammarService.shared.automatic && latest.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 {
            let selection = view.selectedRange()
            pending = true
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ApplicationPreferences().reviewDelay * 1_000_000_000))
                guard !Task.isCancelled, LocalGrammarService.shared.automatic else { self?.pending = false; return }
                self?.review(.paragraph, selection: selection)
            }
        }
    }

    func review(_ scope: GrammarScope, selection: NSRange? = nil) {
        guard let view else { return }
        let current = view.string
        let scopeRange = GrammarText.range(for: scope, in: current, selection: selection ?? view.selectedRange())
        guard scopeRange.length > 0 else { message = "Select a passage to review."; return }
        task?.cancel(); checking = true; pending = false; message = nil
        let reviewContext = context
        let chunks = GrammarText.chunks(current, range: scopeRange, limit: LocalGrammarService.shared.chunkLimit)
        task = Task { [weak self] in
            do {
                var found: [LocatedCorrection] = []
                for (chunk, offset) in chunks {
                    try Task.checkCancellation()
                    if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    let issues = try await LocalGrammarService.shared.review(chunk, context: reviewContext)
                    try Task.checkCancellation()
                    found += GrammarText.locate(issues, chunk: chunk, offset: offset)
                }
                guard let self else { return }
                guard self.view?.string == current, self.context == reviewContext else { self.checking = false; return }
                self.corrections.removeAll { NSIntersectionRange($0.range, scopeRange).length > 0 }
                // Avoid conflicting replacements where model suggestions overlap.
                for correction in found.sorted(by: { $0.range.location < $1.range.location }) {
                    if !self.corrections.contains(where: { NSIntersectionRange($0.range, correction.range).length > 0 }) { self.corrections.append(correction) }
                }
                self.corrections.sort { $0.range.location < $1.range.location }
                self.snapshot = current; self.reviewed = true; self.checking = false; self.drawMarks()
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                self?.message = error.localizedDescription; self?.checking = false
            }
        }
    }

    func cancel() { task?.cancel(); continuationTask?.cancel(); checking = false; pending = false }
    func resetReview() { cancel(); popover?.close(); corrections = []; reviewed = false; message = nil; drawMarks() }
    func selectionChanged() {
        if let range = view?.selectedRange(), range != selection { selection = range }
    }
    func dismiss(_ id: UUID) { continuationTask?.cancel(); corrections.removeAll { $0.id == id }; popover?.close(); drawMarks() }
    func selectedCorrections(_ scope: GrammarScope, anchor: NSRange? = nil) -> [LocatedCorrection] {
        guard let view else { return [] }
        let range = GrammarText.range(for: scope, in: view.string, selection: anchor ?? view.selectedRange())
        return corrections.filter { $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range) }
    }
    func accept(_ id: UUID) { apply(corrections.filter { $0.id == id }, advance: true) }
    func accept(_ scope: GrammarScope, anchor: NSRange? = nil) { apply(selectedCorrections(scope, anchor: anchor), advance: popover?.isShown == true) }

    private func apply(_ accepted: [LocatedCorrection], advance: Bool) {
        guard let view, let storage = view.textStorage, !accepted.isEmpty else { return }
        continuationTask?.cancel()
        let acceptedIDs = Set(accepted.map(\.id))
        let lastLocation = accepted.map(\.range.location).max()!
        let remaining = corrections.filter { !acceptedIDs.contains($0.id) }.sorted { $0.range.location < $1.range.location }
        let nextIDs = (remaining.filter { $0.range.location > lastLocation } + remaining.filter { $0.range.location <= lastLocation }).map(\.id)
        task?.cancel(); checking = false; pending = false; popover?.close(); applying = true
        view.breakUndoCoalescing(); view.undoManager?.beginUndoGrouping()
        for correction in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(correction.range) <= storage.length, (view.string as NSString).substring(with: correction.range) == correction.issue.original else { continue }
            let original = storage.attributedSubstring(from: correction.range)
            let replacement = GrammarText.replacement(original, with: correction.issue.replacement)
            corrections.removeAll { $0.id == correction.id }
        view.replaceAttributedText(replacement, range: correction.range)
            textChanged(automatic: false)
        }
        view.undoManager?.endUndoGrouping(); view.undoManager?.setActionName(accepted.count == 1 ? "Grammar correction" : "Grammar corrections")
        applying = false; drawMarks(); view.window?.makeFirstResponder(view)
        if advance, let next = nextIDs.compactMap({ id in corrections.first { $0.id == id } }).first {
            let nextID = next.id
            // Wait until the Accept click and old popover finish closing, so
            // the same mouse event cannot dismiss the next card immediately.
            continuationTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self,
                      let correction = self.corrections.first(where: { $0.id == nextID }) else { return }
                self.show(correction)
            }
        }
    }

    func drawMarks() {
        LocalGrammarService.shared.cachedResults[documentKey] = CachedGrammarResult(snapshot: snapshot, corrections: corrections, reviewed: reviewed, context: context)
        guard let view, let manager = view.layoutManager else { return }
        let range = NSRange(location: 0, length: view.string.utf16.count)
        manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        manager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        for correction in corrections where NSMaxRange(correction.range) <= range.length {
            let color: NSColor = correction.issue.category == .style ? .systemBlue : .systemOrange
            manager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: color, .backgroundColor: color.withAlphaComponent(0.08)], forCharacterRange: correction.range)
        }
        view.needsDisplay = true
        view.objectNames?.drawMarks()
    }

    func correction(at point: NSPoint) -> LocatedCorrection? {
        guard let view, let manager = view.layoutManager, let container = view.textContainer else { return nil }
        let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        return corrections.first { correction in
            guard NSLocationInRange(index, correction.range) else { return false }
            let glyphs = manager.glyphRange(forCharacterRange: correction.range, actualCharacterRange: nil)
            return manager.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: -4, dy: -4).contains(local)
        }
    }

    func show(_ correction: LocatedCorrection) {
        view?.selectionActions?.close()
        continuationTask?.cancel()
        guard let view else { return }
        popover?.close()
        view.setSelectedRange(correction.range); view.scrollRangeToVisible(correction.range)
        guard view.window?.isVisible == true, let manager = view.layoutManager, let container = view.textContainer else { return }
        let range = manager.glyphRange(forCharacterRange: correction.range, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: range, in: container)
        rect.origin.x += view.textContainerOrigin.x; rect.origin.y += view.textContainerOrigin.y
        let popup = NSPopover(); popup.behavior = .transient
        popup.contentViewController = NSHostingController(rootView: InlineCorrectionCard(session: self, correction: correction))
        popover = popup; popup.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
    func next() {
        guard let view else { return }
        if let correction = corrections.first(where: { $0.range.location >= NSMaxRange(view.selectedRange()) }) ?? corrections.first { show(correction) }
    }
}

struct InlineCorrectionCard: View {
    @ObservedObject var session: InlineGrammarSession
    var correction: LocatedCorrection
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(correction.issue.category.label) suggestion", systemImage: "text.badge.checkmark").font(.headline).foregroundStyle(correction.issue.category.color)
            Text(correction.issue.original).strikethrough().foregroundStyle(.secondary)
            Text(correction.issue.replacement).foregroundStyle(AppTheme.accent)
            if !correction.issue.explanation.isEmpty { Text(correction.issue.explanation).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Accept") { session.accept(correction.id) }.buttonStyle(.borderedProminent)
                Button("Dismiss") { session.dismiss(correction.id) }
                Menu("Accept in…") {
                    Button("This sentence") { session.accept(.sentence, anchor: correction.range) }
                    Button("This paragraph") { session.accept(.paragraph, anchor: correction.range) }
                    Button("Entire \(session.documentLabel)") { session.accept(.document) }
                }
            }
        }.padding(20).frame(width: 350).tint(AppTheme.accent)
    }
}

struct InlineGrammarBar: View {
    @ObservedObject var session: InlineGrammarSession
    @ObservedObject private var service = LocalGrammarService.shared
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            if session.checking { ProgressView().controlSize(.small); Text(service.includeStyle ? "Reviewing writing…" : "Checking grammar…").foregroundStyle(.secondary) }
            else if session.pending { Text("Review pending…").foregroundStyle(.secondary) }
            else if !session.corrections.isEmpty {
                Button { session.next() } label: { Label("\(session.corrections.count) suggestion\(session.corrections.count == 1 ? "" : "s")", systemImage: "text.badge.checkmark") }.buttonStyle(.plain).foregroundStyle(.orange)
            } else if let message = session.message { Label("Review unavailable", systemImage: "exclamationmark.circle").foregroundStyle(.secondary).help(message) }
            else if session.reviewed { Text("No suggestions returned").foregroundStyle(.secondary).help("The model returned no suggestions for the reviewed text. This does not guarantee that the writing is error-free.") }
            else { Text(service.includeStyle ? "Grammar & style" : "Grammar").foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Menu {
                ForEach(GrammarScope.allCases) { scope in Button("Review \(scope.rawValue.lowercased())") { session.review(scope) } }
                if session.checking { Divider(); Button("Cancel check") { session.cancel() } }
                if let message = session.message { Divider(); Text(message) }
            } label: { Text("Review") }.menuStyle(.borderlessButton).tint(.primary).fixedSize()
            if !session.corrections.isEmpty {
                Menu("Accept") {
                    ForEach(GrammarScope.allCases) { scope in Button("All in \(scope.rawValue.lowercased())") { session.accept(scope) }.disabled(session.selectedCorrections(scope).isEmpty) }
                    Divider(); Button("Dismiss all") { for id in session.corrections.map(\.id) { session.dismiss(id) } }
                }.menuStyle(.borderlessButton).tint(.primary).fixedSize()
            }
            if !compact { Toggle("Auto", isOn: $service.automatic).toggleStyle(.switch).controlSize(.mini).fixedSize().help("Check the edited paragraph after a short pause") }
        }.font(.system(size: 11)).padding(.horizontal, compact ? 8 : 20).padding(.vertical, 7)
            .onChange(of: service.backend) { _, _ in session.resetReview() }
            .onChange(of: service.includeStyle) { _, _ in session.resetReview() }
            .onChange(of: service.modelID) { old, _ in if !old.isEmpty { session.resetReview() } }
    }
}
