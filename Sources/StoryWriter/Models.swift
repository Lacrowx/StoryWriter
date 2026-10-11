import Foundation
import AppKit

enum ProjectKind: String, Codable, CaseIterable, Identifiable {
    case story, research
    var id: String { rawValue }
    var label: String { self == .story ? "Story" : "Reference collection" }
    var symbol: String { self == .story ? "book.closed" : "tray.full" }
}

enum DraftStatus: String, Codable, CaseIterable, Identifiable {
    case planned = "Planned", drafting = "Drafting", revising = "Revising", ready = "Ready"
    var id: String { rawValue }
}

struct Chapter: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Untitled chapter"
    var synopsis = ""
    var status: DraftStatus = .planned
    var richText = ChapterText()
    var plainText = ""
    var scenes: [StoryScene]?
    var comments: [PassageComment]?
    var continuityEvents: [ContinuityEvent]?
    var wordCount: Int { WordCountCache.shared.count(plainText, id: id) }
    var attributedText: NSAttributedString {
        (try? richText.attributedText())
        ?? NSAttributedString(string: plainText, attributes: plainText.isEmpty ? WritingStyle.attributes : WritingStyle.legacyAttributes)
    }
    mutating func setText(_ text: NSAttributedString) throws {
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        rebaseAnnotations(from: plainText, to: text.string)
        richText = ChapterText(data: data)
        plainText = text.string
    }
    /// Keep edits current in the project without archiving the entire chapter per key.
    mutating func setEditingText(_ text: NSAttributedString) {
        richText = ChapterText(text: text)
        let string = String(copyingUTF16: text.string as NSString)
        rebaseAnnotations(from: plainText, to: string)
        plainText = string
    }
}

struct Character: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New character"
    var role = ""
    var pronouns = ""
    var appearance = ""
    var personality = ""
    var motivation = ""
    var conflict = ""
    var arc = ""
    var relationships = ""
    var notes = ""
    var aliases: [String]?
}

enum WorldCategory: String, Codable, CaseIterable, Identifiable {
    case location = "Location", culture = "Culture", history = "History", rules = "Rules & systems", object = "Object", other = "Other"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .location: return "map"; case .culture: return "person.3"; case .history: return "clock"; case .rules: return "sparkles"; case .object: return "shippingbox"; case .other: return "note.text" }
    }
}

struct WorldNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New world note"
    var category: WorldCategory = .location
    var summary = ""
    var details = ""
    var connections = ""
    var aliases: [String]?
}

struct ReferenceSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var relativePath: String?
    var webURL: String?
    var snapshotPath: String?
    var notes = ""
    var tags = ""
    var addedAt = Date()
    var fileExtension: String { (relativePath as NSString?)?.pathExtension.lowercased() ?? "" }
    var symbol: String {
        if webURL != nil { return "link" }
        switch fileExtension {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": return "photo"
        case "mp3", "m4a", "wav", "aiff", "flac", "ogg": return "waveform"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

struct StoryProject: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var kind: ProjectKind = .story
    var title = "Untitled story"
    var author = ""
    var genre = ""
    var premise = ""
    var synopsis = ""
    var themes = ""
    var audience = ""
    var publishingNotes = ""
    var writingBrief: String?
    var ignoredObjectNames: [String]?
    var continuityItems: [ContinuityItem]?
    var initialContinuity: [ContinuityEvent]?
    var aiWritingBrief: String {
        get { writingBrief ?? "" }
        set { writingBrief = newValue }
    }
    var targetWords = 50000
    var chapters: [Chapter] = []
    var characters: [Character] = []
    var worldNotes: [WorldNote] = []
    var sources: [ReferenceSource] = []
    var createdAt = Date()
    var modifiedAt = Date()
    var archived = false
    var wordCount: Int { chapters.reduce(0) { $0 + $1.wordCount } }

    static func new(title: String, kind: ProjectKind) -> StoryProject {
        var project = StoryProject(kind: kind, title: title)
        if kind == .story { project.chapters = [Chapter(title: "Chapter 1")] }
        return project
    }

    static func example() -> StoryProject {
        var story = new(title: "The House at Low Tide", kind: .story)
        story.genre = "Mystery · Coastal fiction"
        story.premise = "A cartographer returns to her island home to find a house that appears on none of her maps."
        story.synopsis = "Mara follows a trail of missing landmarks, old letters, and the tide itself to uncover what her family chose to forget."
        story.themes = "Memory, belonging, the stories places keep"
        story.targetWords = 30000
        var chapter = Chapter(title: "The return", synopsis: "Mara arrives on the last ferry and notices an unfamiliar light across the bay.", status: .drafting)
        let text = NSAttributedString(string: "The ferry left her at the end of the pier with a suitcase, a rolled map, and the uncomfortable feeling that the island had moved.\n\nIt was a ridiculous thought. Islands did not move. But the house across the bay had never been there before.\n\nMara knew every roof along that shoreline. She had drawn them herself.\n\nAbove the dark windows, a single light burned. Someone was waiting.", attributes: WritingStyle.attributes)
        try? chapter.setText(text)
        story.chapters = [chapter, Chapter(title: "A missing landmark", synopsis: "The old maps disagree. Mara asks the lighthouse keeper what changed."), Chapter(title: "Letters from the shore", synopsis: "A letter arrives with a date that should be impossible.")]
        story.characters = [Character(name: "Mara Vale", role: "Protagonist · Cartographer", pronouns: "She / her", motivation: "Find out why her mother's maps were destroyed.", conflict: "She trusts records more than people.", arc: "Learns which memories deserve to be kept."), Character(name: "Elias Reed", role: "Lighthouse keeper", motivation: "Keep the island's secret through one more winter.")]
        story.worldNotes = [WorldNote(title: "Bellweather Island", category: .location, summary: "A small island connected to the mainland by a twice-daily ferry.", details: "At low tide, a narrow stone path appears between the old harbor and the northern shore."), WorldNote(title: "The winter tide", category: .rules, summary: "Once each winter, the sea reveals what it has taken.")]
        return story
    }
}

enum WritingStyle {
    static var attributes: [NSAttributedString.Key: Any] { attributes(preferences: ApplicationPreferences()) }
    static func attributes(preferences: ApplicationPreferences) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = preferences.defaultLineSpacing
        paragraph.paragraphSpacing = 12
        return [.font: preferences.defaultFont, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
    }
    static var legacyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 12
        return [.font: NSFont(name: "Georgia", size: 18) ?? NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
    }
}

extension String {
    /// Runs between whitespace and attachments that contain a letter or digit, counted in one pass.
    var wordCount: Int {
        var count = 0, inRun = false, runHasText = false
        for scalar in unicodeScalars {
            let separator: Bool, text: Bool
            if scalar.isASCII {
                let value = scalar.value
                separator = value == 0x20 || (0x09...0x0D).contains(value)
                text = (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
            } else {
                separator = scalar.properties.isWhitespace || scalar == "\u{FFFC}"
                text = !separator && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
            }
            if separator {
                if inRun && runHasText { count += 1 }
                inRun = false; runHasText = false
            } else {
                inRun = true; runHasText = runHasText || text
            }
        }
        return inRun && runHasText ? count + 1 : count
    }
    var safeFilename: String {
        let value = components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Untitled" : String(value.prefix(100))
    }
    var xmlEscaped: String { replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
}

/// Chapter counts are read on every render; unchanged text matches its cached
/// entry by identity, so only an edited chapter is counted again.
final class WordCountCache: @unchecked Sendable {
    static let shared = WordCountCache()
    private let lock = NSLock()
    private var entries: [UUID: (text: String, count: Int)] = [:]
    func count(_ text: String, id: UUID) -> Int {
        if let entry = lock.withLock({ entries[id] }), entry.text == text { return entry.count }
        let count = text.wordCount
        lock.withLock { entries[id] = (text, count) }
        return count
    }
}
