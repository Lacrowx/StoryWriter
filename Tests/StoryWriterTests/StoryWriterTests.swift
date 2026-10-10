import XCTest
import AppKit
import PDFKit
@testable import StoryWriter

final class StoryWriterTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoryWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor func testRichTextAndMediaSurvivePortableRoundTrip() async throws {
        let root = try temporaryDirectory()
        let store = ProjectStore(root: root.appendingPathComponent("library"), createExample: false)
        let id = store.create(title: "Test story", kind: .story)
        let text = NSMutableAttributedString(string: "Hello Welt.\nA second paragraph.", attributes: WritingStyle.attributes)
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: 5))
        var chapter = store.project(id)!.chapters[0]; try chapter.setText(text)
        store.update(id) { $0.chapters[0] = chapter; $0.characters.append(Character(name: "Ada")); $0.worldNotes.append(WorldNote(title: "Harbor")); $0.aiWritingBrief = "Close third person. Natural German, restrained tone, no invented details." }
        let reference = root.appendingPathComponent("reference.txt")
        try "Reference content".write(to: reference, atomically: true, encoding: .utf8)
        store.importFiles([reference], projectID: id)
        try FileManager.default.removeItem(at: reference)
        XCTAssertTrue(store.saveNow())
        let portable = root.appendingPathComponent("Test.storywriter")
        try store.exportPackage(id, to: portable)
        let reopened = ProjectStore(root: root.appendingPathComponent("another-library"), createExample: false)
        reopened.importPackage(portable)
        let restored = try XCTUnwrap(reopened.selectedProject)
        XCTAssertNotEqual(restored.id, id)
        XCTAssertEqual(restored.chapters[0].plainText, text.string)
        let font = try XCTUnwrap(restored.chapters[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(restored.characters[0].name, "Ada")
        XCTAssertEqual(restored.worldNotes[0].title, "Harbor")
        XCTAssertEqual(restored.aiWritingBrief, "Close third person. Natural German, restrained tone, no invented details.")
        let media = try XCTUnwrap(reopened.mediaURL(restored.sources[0], projectID: restored.id))
        XCTAssertEqual(try String(contentsOf: media), "Reference content")
        let reloaded = ProjectStore(root: root.appendingPathComponent("another-library"), createExample: false)
        XCTAssertEqual(reloaded.selectedProject?.chapters[0].plainText, text.string)
        XCTAssertNil(reloaded.errorMessage)
    }

    @MainActor func testRevisionRestoreKeepsCurrentWorkRecoverable() async throws {
        let store = ProjectStore(root: try temporaryDirectory(), createExample: false)
        let id = store.create(title: "Original", kind: .story)
        store.update(id) { $0.title = "Second draft" }; XCTAssertTrue(store.saveNow())
        let old = try XCTUnwrap(store.revisions(id).first)
        store.restore(old, projectID: id)
        XCTAssertEqual(store.project(id)?.title, "Original")
        let revisions = try store.revisions(id).map { try ProjectStore.decode(Data(contentsOf: $0.url)).title }
        XCTAssertTrue(revisions.contains("Second draft"))
    }

    @MainActor func testEditorFormattingAndCorrectionUndo() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ManuscriptTextView(frame: window.contentView!.bounds)
        view.isRichText = true; view.allowsUndo = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "She go home.", attributes: WritingStyle.attributes))
        window.contentView?.addSubview(view); window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.toggleBoldface(nil)
        let bold = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        view.undoManager?.undo()
        let afterUndo = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: afterUndo).contains(.boldFontMask))
        let controller = EditorController(); let chapterID = UUID()
        controller.textView = view; controller.chapterID = chapterID
        XCTAssertTrue(controller.replaceUnique(original: "She go home.", replacement: "She goes home.", expectedChapter: chapterID))
        XCTAssertEqual(view.string, "She goes home.")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "She go home.")
        XCTAssertFalse(controller.replaceUnique(original: "She go home.", replacement: "Oops", expectedChapter: UUID()))
        window.orderOut(nil)
    }

    @MainActor func testSourceOnlyCollectionAndAutosave() async throws {
        let root = try temporaryDirectory()
        let store = ProjectStore(root: root, createExample: false)
        let id = store.create(title: "Research", kind: .research)
        XCTAssertEqual(store.project(id)?.chapters.count, 0)
        try store.addLink("example.com", title: "Reference", projectID: id)
        store.update(id) { $0.sources[0].notes = "A useful detail" }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let reopened = ProjectStore(root: root, createExample: false)
        XCTAssertEqual(reopened.project(id)?.sources[0].notes, "A useful detail")
        XCTAssertEqual(reopened.project(id)?.sources[0].webURL, "https://example.com")
    }

    @MainActor func testCorruptProjectIsNotOverwritten() async throws {
        let root = try temporaryDirectory(), id = UUID()
        let package = root.appendingPathComponent("\(id.uuidString).storywriter")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = package.appendingPathComponent("project.json")
        try "not json".write(to: manifest, atomically: true, encoding: .utf8)
        let store = ProjectStore(root: root)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try String(contentsOf: manifest), "not json")
    }

    @MainActor func testEveryPublicationFormatExportsReadableContent() async throws {
        let root = try temporaryDirectory()
        var project = StoryProject.new(title: "A story & its world", kind: .story)
        var chapter = Chapter(title: "An opening <chapter>")
        try chapter.setText(NSAttributedString(string: "A beautiful beginning.\nGrüße aus dem Hafen.", attributes: [.font: NSFont.boldSystemFont(ofSize: 17)]))
        project.chapters = [chapter]
        for format in ExportFormat.allCases {
            let file = root.appendingPathComponent("export.\(format.fileExtension)")
            try ExportService.export(project: project, chapters: project.chapters, format: format, to: file)
            XCTAssertGreaterThan(try Data(contentsOf: file).count, 30)
            switch format {
            case .docx, .rtf:
                let restored = try NSAttributedString(url: file, options: [:], documentAttributes: nil)
                XCTAssertTrue(restored.string.contains("A beautiful beginning."))
                XCTAssertTrue(restored.string.contains("Grüße"))
            case .pdf:
                let document = try XCTUnwrap(PDFDocument(url: file))
                XCTAssertGreaterThan(document.pageCount, 0)
                XCTAssertTrue(document.string?.contains("beautiful beginning") == true)
            case .html:
                let html = try String(contentsOf: file)
                XCTAssertTrue(html.contains("<strong>"))
                XCTAssertTrue(html.contains("&lt;chapter&gt;"))
            case .markdown:
                XCTAssertTrue(try String(contentsOf: file).contains("**A beautiful beginning."))
            case .epub:
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-p", file.path, "OEBPS/chapter-1.xhtml"]
                let pipe = Pipe(); process.standardOutput = pipe; try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
                XCTAssertTrue(xml.contains("A beautiful beginning."))
                XCTAssertTrue(xml.contains("&lt;chapter&gt;"))
                let parser = XMLParser(data: data); XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "Invalid EPUB XHTML")
            case .txt: XCTAssertTrue(try String(contentsOf: file).contains("Grüße"))
            }
        }
    }

    func testUnsafePathsAndNonLocalAIEndpointsAreRejected() throws {
        for path in ["../secret", "/absolute", "Media/../../secret", "Media\\secret"] { XCTAssertFalse(ProjectStore.isSafeRelativePath(path)) }
        XCTAssertTrue(ProjectStore.isSafeRelativePath("Media/id/photo.png"))
        for url in ["https://example.com/v1", "http://127.0.0.1.evil.com:1337/v1", "file:///tmp", "http://user:password@localhost:1337/v1", "http://localhost:1337/v1?redirect=other"] { XCTAssertThrowsError(try OsaurusClient.validatedURL(url)) }
        XCTAssertNoThrow(try OsaurusClient.validatedURL("http://127.0.0.1:1337/v1"))
        XCTAssertFalse(LocalModel(id: "cloud-model", owned_by: "openai").isLocal)
        XCTAssertTrue(LocalModel(id: "local-model", owned_by: "osaurus").isLocal)
    }

    func testGrammarSuggestionsRequireExactUniqueOriginals() throws {
        let content = "```json\n{\"issues\":[{\"original\":\"She go home.\",\"replacement\":\"She goes home.\",\"explanation\":\"Subject–verb agreement\"},{\"original\":\"Missing text\",\"replacement\":\"New text\",\"explanation\":\"Hallucinated\"},{\"original\":\"the\",\"replacement\":\"a\",\"explanation\":\"Ambiguous\"}]}\n```"
        let issues = try OsaurusClient.parseIssues(content, passage: "She go home. In the house, by the door.")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].replacement, "She goes home.")
        XCTAssertThrowsError(try OsaurusClient.parseIssues("unstructured advice", passage: "Hello"))
        XCTAssertThrowsError(try OsaurusClient.parseIssues("{\"issues\":[{\"original\":\"not in the passage\",\"replacement\":\"replacement\",\"explanation\":\"Mismatch\"}]}", passage: "Hello"))
        let revision = try OsaurusClient.parseRevision("```json\n{\"revisedText\":\"She goes home.\",\"explanation\":\"Subject–verb agreement\",\"kind\":\"grammar\"}\n```", passage: "She go home.")
        XCTAssertEqual(revision.first?.replacement, "She goes home.")
        XCTAssertThrowsError(try OsaurusClient.parseRevision("{\"revisedText\":\"\",\"explanation\":\"Empty\",\"kind\":\"grammar\"}", passage: "Hello"))
    }

    func testWritingBriefIsBackwardCompatibleAndContextIsBounded() throws {
        var project = StoryProject.example()
        project.aiWritingBrief = "Use spare, tense prose and natural dialogue."
        let context = project.reviewContext(chapter: project.chapters[0])
        XCTAssertEqual(context.brief, project.aiWritingBrief)
        var other = project; other.id = UUID(); other.aiWritingBrief = "A different voice."
        XCTAssertNotEqual(context.storageKey("chapter/body"), other.reviewContext().storageKey("chapter/body"))
        for detail in ["Mara Vale", "Bellweather Island", project.premise, project.chapters[0].title] { XCTAssertTrue(context.background.contains(detail)) }
        XCTAssertTrue(context.systemMessage.contains(project.aiWritingBrief))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        object.removeValue(forKey: "writingBrief")
        let legacy = try JSONDecoder().decode(StoryProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.aiWritingBrief, "")
        XCTAssertEqual(legacy.chapters, project.chapters)
        let large = WritingReviewContext(brief: String(repeating: "b", count: 4000), background: String(repeating: "c", count: 5000))
        XCTAssertFalse(large.systemMessage.contains(String(repeating: "b", count: 3001)))
        XCTAssertFalse(large.systemMessage.contains(String(repeating: "c", count: 3501)))
        let styleJSON = "{\"issues\":[{\"kind\":\"style\",\"original\":\"She felt tired and she was tired.\",\"replacement\":\"She was tired.\",\"explanation\":\"Remove redundant phrasing\"}]}"
        let issues = try OsaurusClient.parseIssues(styleJSON, passage: "She felt tired and she was tired.")
        XCTAssertEqual(issues.first?.category, .style)
        for index in 0..<25 {
            project.characters.append(Character(name: "Person\(index)", pronouns: "they/them", notes: "Unrelated profile"))
        }
        project.characters.append(Character(name: "Elisa", role: "Ben's friend", pronouns: "sie/ihr", notes: "She lives alone."))
        let lookup = project.reviewContext().forPassage("Für Elisa bedeutete das nun, dass sie allein zu Hause war.")
        XCTAssertEqual(lookup.characters.count, project.characters.count)
        XCTAssertTrue(lookup.characterGuide.contains("Elisa"))
        XCTAssertTrue(lookup.characterGuide.contains("sie/ihr"))
        XCTAssertTrue(lookup.characterGuide.contains("Ben's friend"))
        XCTAssertFalse(lookup.characterGuide.contains("Person0"))
        XCTAssertTrue(lookup.systemMessage.contains("Author's pronouns: sie/ihr"))
    }

    func testLiveOsaurusEnglishAndGerman() async throws {
        guard ProcessInfo.processInfo.environment["STORYWRITER_TEST_OSAURUS"] == "1" else { throw XCTSkip("Set STORYWRITER_TEST_OSAURUS=1 to verify a running local model.") }
        let client = OsaurusClient(baseURL: "http://127.0.0.1:1337/v1")
        let models = try await client.models()
        let requestedModel = ProcessInfo.processInfo.environment["STORYWRITER_TEST_MODEL"] ?? "nanbeige4.2-3b-jang_4m"
        let model = try XCTUnwrap(models.first { $0.id == requestedModel })
        let german = "Sie geht jeden Morgen zum Hafen. Gestern hat sie ein Brief gefunden. Der alte Fischer haben ihr geholfen."
        let germanIssues = try await client.review(text: german, language: "de", model: model)
        let correctedGerman = germanIssues.reduce(german) { $0.replacingOccurrences(of: $1.original, with: $1.replacement) }
        XCTAssertTrue(correctedGerman.contains("einen Brief"), "German accusative correction was missing")
        XCTAssertTrue(correctedGerman.contains("Fischer hat"), "German subject–verb correction was missing")
        let english = "She go to the harbour every morning. Yesterday she find a letter. The old fisherman were waiting."
        let englishIssues = try await client.review(text: english, language: "en", model: model)
        let correctedEnglish = englishIssues.reduce(english) { $0.replacingOccurrences(of: $1.original, with: $1.replacement) }
        XCTAssertTrue(correctedEnglish.contains("She goes"))
        XCTAssertTrue(correctedEnglish.contains("found a letter"))
        XCTAssertTrue(correctedEnglish.contains("fisherman was"))
    }

    @MainActor func testLiveAppleOnDeviceWritingReview() async throws {
        guard ProcessInfo.processInfo.environment["STORYWRITER_TEST_APPLE"] == "1" else { throw XCTSkip("Enable the optional Apple on-device check.") }
        if let reason = AppleWritingModel.unavailabilityReason { throw XCTSkip(reason) }
        let passage = "Mara setzt sich auf Tisch, den hatte sie als Kindd immer so gemacht. Für ihren Vater war es ihr nichts zu schade."
        let context = StoryProject.example().reviewContext()
        let issues = try await AppleWritingModel.review(passage, language: "de", context: context, includeStyle: true)
        print("Apple corrections:", issues.map { ($0.original, $0.replacement) })
        let corrected = issues.sorted { passage.range(of: $0.original)!.lowerBound > passage.range(of: $1.original)!.lowerBound }.reduce(passage) { $0.replacingOccurrences(of: $1.original, with: $1.replacement) }
        XCTAssertFalse(corrected.contains("Kindd"))
        XCTAssertFalse(corrected.contains("auf Tisch"))
        XCTAssertFalse(corrected.contains("war es"))
        XCTAssertTrue(corrected.contains("auf den Tisch") || corrected.contains("auf einen Tisch"), "Keep Mara sitting ON the table")
        XCTAssertFalse(corrected.contains("war es ihm"), "Do not change the pronoun referent")
        let style = try await AppleWritingModel.review("She was very tired and she felt very tired.", language: "en", context: WritingReviewContext(brief: "Use concise direct wording. Remove unnecessary repetition."), includeStyle: true)
        XCTAssertTrue(style.contains { $0.category == .style && $0.replacement.count < $0.original.count })
    }

    func testLiveGermanScreenshotAndWritingStyle() async throws {
        guard ProcessInfo.processInfo.environment["STORYWRITER_TEST_OSAURUS"] == "1" else { throw XCTSkip("Requires a running local Osaurus model.") }
        let client = OsaurusClient(baseURL: "http://127.0.0.1:1337/v1")
        let models = try await client.models()
        let model = try XCTUnwrap(models.first { $0.id == (ProcessInfo.processInfo.environment["STORYWRITER_TEST_MODEL"] ?? "nanbeige4.2-3b-jang_4m") })
        let passage = "Mara setzt sich auf Tisch, den hatte sie als Kindd immer so gemacht. Für ihren Vater war es ihr nichts zu schade."
        let issues = try await client.review(text: passage, language: "de", model: model)
        print("Screenshot corrections:", issues.map { ($0.original, $0.replacement) })
        let corrected = issues.sorted { passage.range(of: $0.original)!.lowerBound > passage.range(of: $1.original)!.lowerBound }.reduce(passage) { $0.replacingOccurrences(of: $1.original, with: $1.replacement) }
        XCTAssertFalse(corrected.contains("Kindd"), "Repeated-letter typo must be suggested")
        XCTAssertFalse(corrected.contains("auf Tisch"), "Missing article must be suggested")
        XCTAssertFalse(corrected.contains("war es"), "Broken idiom must be suggested")
        XCTAssertTrue(corrected.contains("auf den Tisch") || corrected.contains("auf einen Tisch"), "Keep the action of sitting ON the table")
        XCTAssertFalse(corrected.contains("den hatte sie"), "Awkward relative clause must be suggested")
        XCTAssertFalse(corrected.contains("Wichtiges zu schaden"), "Do not replace the idiom with nonsensical wording")
        let stylePassage = "She was very tired and she felt very tired."
        let context = WritingReviewContext(brief: "Use concise, direct sentences. Remove needless repetition. Keep the same facts and emotions.")
        let styleIssues = try await client.review(text: stylePassage, language: "en", model: model, context: context)
        XCTAssertTrue(styleIssues.contains { $0.category == .style && $0.replacement.count < $0.original.count }, "Grammatically valid but redundant writing should receive a style suggestion")
    }
}
