import AppKit

/// Links names already in the manuscript when a profile gains a name or alias.
struct ObjectMentionLinker {
    struct Match {
        var range: NSRange
        var reference: ProjectTagReference
    }
    private var patterns: [(NSRegularExpression, ProjectTagReference)] = []

    static func names(in project: StoryProject) -> [ProjectTagReference: [String]] {
        var result: [ProjectTagReference: [String]] = [:]
        for character in project.characters where character.name != "New character" {
            let reference = ProjectTagReference(kind: .character, objectID: character.id)
            let object = TaggedProjectObject(reference: reference, title: character.name, group: "", symbol: "", summary: "", aliases: character.aliases ?? [])
            result[reference] = ObjectTags.nameChoices(object)
        }
        for note in project.worldNotes where note.title != "New world note" {
            let reference = ProjectTagReference(kind: .world, objectID: note.id)
            let object = TaggedProjectObject(reference: reference, title: note.title, group: "", symbol: "", summary: "", aliases: note.aliases ?? [])
            result[reference] = ObjectTags.nameChoices(object)
        }
        return result
    }

    init(names: [ProjectTagReference: [String]]) {
        for (reference, choices) in names {
            for name in choices where name.count >= 2 {
                let words = name.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                // Match profile spelling, as with tagging while typing. In particular,
                // a character named Will must not claim ordinary lowercase "will".
                let pattern = "(?<![\\p{L}\\p{M}\\p{N}_@])" + words.joined(separator: "[ \\t\\u00a0]+") + "(?![\\p{L}\\p{M}\\p{N}_@])"
                if let regex = try? NSRegularExpression(pattern: pattern) { patterns.append((regex, reference)) }
            }
        }
    }

    func matches(in text: NSAttributedString, references: Set<ProjectTagReference>) -> [Match] {
        var candidates: [NSRange: Set<ProjectTagReference>] = [:]
        for (regex, reference) in patterns {
            for match in regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
                candidates[match.range, default: []].insert(reference)
            }
        }
        let ranges = candidates.keys.sorted { $0.length == $1.length ? $0.location < $1.location : $0.length > $1.length }
        var claimed: [NSRange] = [], matches: [Match] = []
        for range in ranges {
            guard !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            // A longer name, including an ambiguous one, blocks shorter names inside it.
            claimed.append(range)
            guard let owners = candidates[range], owners.count == 1, let reference = owners.first,
                  references.contains(reference) else { continue }
            var conflict = false, unlinked = false
            text.enumerateAttribute(.link, in: range) { value, _, _ in
                if value == nil { unlinked = true }
                else if ProjectTagReference.from(value) != reference { conflict = true }
            }
            if !conflict && unlinked { matches.append(Match(range: range, reference: reference)) }
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }

    func link(in project: inout StoryProject, references: Set<ProjectTagReference>) {
        for index in project.chapters.indices {
            let text = project.chapters[index].attributedText
            let matches = matches(in: text, references: references)
            guard !matches.isEmpty else { continue }
            let linked = NSMutableAttributedString(attributedString: text)
            for match in matches { linked.addAttribute(.link, value: match.reference.url, range: match.range) }
            project.chapters[index].setEditingText(linked)
        }
    }
}
