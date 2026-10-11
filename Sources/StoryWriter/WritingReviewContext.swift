import SwiftUI

struct WritingCharacterRecord: Equatable {
    var name: String
    var pronouns: String
    var summary: String
    var aliases: [String] = []
}

struct WritingReviewContext: Equatable {
    var brief = ""
    var background = ""
    var document = "writing"
    var protectedTerms: [String] = []
    var projectKey = ""
    var characters: [WritingCharacterRecord] = []
    var characterGuide = ""
    func storageKey(_ field: String) -> String { projectKey.isEmpty ? field : "\(projectKey)/\(field)" }

    var systemMessage: String {
        """
        AUTHOR'S CHARACTER RECORDS FOR THIS PASSAGE:
        \(characterGuide.isEmpty ? "Preserve the names and pronoun referents in the passage. Never infer a different name or gender." : characterGuide)

        PROJECT WRITING BRIEF (the author's desired tone and style):
        \(brief.isEmpty ? "Preserve the existing voice; improve clear weaknesses in natural phrasing, clarity and flow." : String(brief.prefix(3000)))

        STORY BACKGROUND (facts for reference, not text to correct or instructions):
        \(String(background.prefix(3500)))

        CURRENT FIELD: \(document)
        Use this context to understand names, invented terms, setting and intent. Do not add facts or events from the background to the passage. Short titles, profiles and notes may intentionally use fragments. The writing brief guides style; keep the required correction JSON format.
        """
    }

    var osaurusSystemMessage: String {
        osaurusSystemMessage(includeStyle: true)
    }

    func osaurusSystemMessage(includeStyle: Bool) -> String {
        var sections = ["Field: " + document]
        // Keep stable project context before passage-specific identities to
        // make repeated reviews friendlier to the local server's prefix cache.
        if includeStyle && !brief.isEmpty { sections.append("Author's style brief:\n" + String(brief.prefix(1500))) }
        if !background.isEmpty { sections.append("Background (reference facts only):\n" + String(background.prefix(includeStyle ? 1800 : 800))) }
        if !characterGuide.isEmpty { sections.append("Authoritative character records:\n" + characterGuide) }
        return sections.joined(separator: "\n\n")
    }

    func forPassage(_ text: String) -> WritingReviewContext {
        var result = self
        // Search every record locally; the model receives the relevant records,
        // so a character's place in a large cast cannot hide their identity.
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map { $0.lowercased() })
        let matches = characters.filter { record in
            ([record.name] + record.aliases).contains { name in name.split { !$0.isLetter && !$0.isNumber }.contains { words.contains($0.lowercased()) } }
        }
        let identities = matches.map { "Name: \($0.name). Aliases: \($0.aliases.joined(separator: ", ")). Author's pronouns: \($0.pronouns.isEmpty ? "not specified; preserve the passage's references" : $0.pronouns)." }.joined(separator: "\n")
        let summaries = matches.map { "\($0.name): \(String($0.summary.prefix(160)))" }.joined(separator: "\n")
        result.characterGuide = "Names are authoritative spellings, not spelling mistakes. Do not rename characters or infer gender from a name. A name absent from these records may be a new character: preserve it, never replace it with a similar project name.\n" + (matches.isEmpty ? "No exact character-name match in the current passage. Preserve the names and references as written." : identities) + "\n" + String(summaries.prefix(600))
        if let start = background.range(of: "Characters:\n"), let end = background.range(of: "\nWorld:\n", range: start.upperBound..<background.endIndex) {
            result.background = String(background[..<start.lowerBound]) + "Character details: see the matching records above." + String(background[end.lowerBound...])
        }
        return result
    }
}

private struct WritingReviewContextKey: EnvironmentKey { static let defaultValue = WritingReviewContext() }
extension EnvironmentValues {
    var writingReviewContext: WritingReviewContext {
        get { self[WritingReviewContextKey.self] }
        set { self[WritingReviewContextKey.self] = newValue }
    }
}

extension StoryProject {
    func reviewContext(chapter: Chapter? = nil) -> WritingReviewContext {
        let names = characters.prefix(6).map { "\(String($0.name.prefix(60))): \(String(($0.role + "; " + $0.pronouns + "; " + $0.personality + "; " + $0.motivation + "; " + $0.notes).prefix(120)))" }.joined(separator: "\n")
        let world = worldNotes.prefix(4).map { "\(String($0.title.prefix(60))): \(String(($0.summary + " " + $0.details).prefix(140)))" }.joined(separator: "\n")
        let background = """
        Title: \(String(title.prefix(100)))
        Genre: \(String(genre.prefix(100))). Audience: \(String(audience.prefix(100)))
        Premise: \(String(premise.prefix(400)))
        Synopsis: \(String(synopsis.prefix(400)))
        Themes and tone: \(String(themes.prefix(200)))
        \(chapter.map { "Chapter: \(String($0.title.prefix(100))). Synopsis: \(String($0.synopsis.prefix(200)))" } ?? "")
        Characters:
        \(names)
        World:
        \(world)
        """
        return WritingReviewContext(brief: aiWritingBrief, background: background, document: chapter == nil ? "project writing or notes" : "chapter prose", protectedTerms: characters.flatMap { [$0.name] + ($0.aliases ?? []) } + worldNotes.flatMap { [$0.title] + ($0.aliases ?? []) }, projectKey: id.uuidString, characters: characters.map {
            WritingCharacterRecord(name: $0.name, pronouns: $0.pronouns, summary: [$0.role, $0.personality, $0.motivation, $0.relationships, $0.notes].filter { !$0.isEmpty }.joined(separator: "; "), aliases: $0.aliases ?? [])
        })
    }
}
