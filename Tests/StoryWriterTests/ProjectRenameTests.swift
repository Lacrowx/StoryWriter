import AppKit
import XCTest
@testable import StoryWriter

final class ProjectRenameTests: XCTestCase {
    private func chapter(_ text: String, tagged: [String] = [], bold: String? = nil, reference: ProjectTagReference) throws -> Chapter {
        let string = NSMutableAttributedString(string: text, attributes: WritingStyle.attributes)
        var search = NSRange(location: 0, length: string.length)
        for phrase in tagged {
            let range = (text as NSString).range(of: phrase, options: [], range: search)
            string.addAttribute(.link, value: reference.url, range: range)
            search = NSRange(location: NSMaxRange(range), length: string.length - NSMaxRange(range))
        }
        if let bold { string.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: (text as NSString).range(of: bold)) }
        var chapter = Chapter()
        try chapter.setText(string)
        return chapter
    }

    /// A project whose character was renamed from "Cole Marsh" to "Class Marsh".
    private func renamedProject() throws -> (StoryProject, ProjectTagReference) {
        var project = StoryProject()
        var cole = Character(name: "Class Marsh"); cole.aliases = ["the Captain"]
        project.characters = [cole]
        let reference = ProjectTagReference(kind: .character, objectID: cole.id)
        var first = try chapter("Cole Marsh arrived. Later Cole smiled at the Captain. Coles Hut stood empty.", tagged: ["Cole Marsh", "Cole", "the Captain"], bold: "Cole smiled", reference: reference)
        first.synopsis = "Cole returns home."
        let quote = "stood empty"
        let start = (first.plainText as NSString).range(of: quote).location
        first.comments = [PassageComment(start: start, length: quote.utf16.count, quote: quote, note: "Does Cole know?")]
        let second = try chapter("Nobody had seen Cole for years.", reference: reference)
        project.chapters = [first, second]
        return (project, reference)
    }

    func testPlanGroupsOutdatedSpellingsAndGuessesReplacements() throws {
        let (project, reference) = try renamedProject()
        let plan = try XCTUnwrap(ProjectRename.plan(project: project, reference: reference))
        XCTAssertEqual(plan.groups.map(\.spelling), ["Cole Marsh", "Cole"])
        XCTAssertEqual(plan.groups.map(\.replacement), ["Class Marsh", "Class"])
        let cole = try XCTUnwrap(plan.groups.first { $0.spelling == "Cole" })
        XCTAssertEqual(cole.mentions.filter(\.tagged).count, 1)
        XCTAssertEqual(cole.mentions.filter(\.selected).count, 1, "Only tagged mentions are ticked by default")
        XCTAssertEqual(Set(cole.mentions.map(\.place)), [.text, .synopsis, .comment])
        XCTAssertTrue(cole.mentions.contains { $0.place == .text && !$0.tagged && $0.chapterID == project.chapters[1].id })
        XCTAssertEqual(plan.taggedCount, 2)
        XCTAssertEqual(plan.manualChecks.map(\.spelling), ["Coles"], "Fused forms need a manual look")
        XCTAssertFalse(plan.groups.contains { $0.spelling == "the Captain" }, "Current aliases are not outdated")
    }

    func testNoPlanWhenTagsMatchCurrentNames() throws {
        var project = StoryProject()
        let mara = Character(name: "Mara Vale"); project.characters = [mara]
        let reference = ProjectTagReference(kind: .character, objectID: mara.id)
        project.chapters = [try chapter("Mara Vale waited for Mara.", tagged: ["Mara Vale", "Mara"], reference: reference)]
        XCTAssertNil(ProjectRename.plan(project: project, reference: reference))
    }

    func testApplyingReplacesTaggedMentionsKeepingFormattingTagsAndComments() throws {
        let (original, reference) = try renamedProject()
        var project = original
        var plan = try XCTUnwrap(ProjectRename.plan(project: project, reference: reference))
        let changed = try ProjectRename.apply(plan, to: &project)
        XCTAssertEqual(changed, 2)
        let first = project.chapters[0]
        XCTAssertEqual(first.plainText, "Class Marsh arrived. Later Class smiled at the Captain. Coles Hut stood empty.")
        let text = first.attributedText
        for name in ["Class Marsh", "Class"] {
            let range = (first.plainText as NSString).range(of: name, options: name == "Class" ? .backwards : [])
            var effective = NSRange()
            XCTAssertEqual(ProjectTagReference.from(text.attribute(.link, at: range.location, longestEffectiveRange: &effective, in: NSRange(location: 0, length: text.length))), reference)
            XCTAssertEqual(effective, range, "\(name) is tagged exactly")
        }
        let classSmiled = (first.plainText as NSString).range(of: "Class smiled")
        XCTAssertTrue(NSFontManager.shared.traits(of: text.attribute(.font, at: classSmiled.location, effectiveRange: nil) as! NSFont).contains(.boldFontMask))
        XCTAssertEqual(first.synopsis, "Cole returns home.", "Unticked mentions are unchanged")
        let comment = try XCTUnwrap(first.comments?.first)
        XCTAssertEqual((first.plainText as NSString).substring(with: comment.range), "stood empty", "Comments stay anchored")
        XCTAssertEqual(project.chapters[1], original.chapters[1])

        // Ticking the untagged mentions updates and tags them too.
        project = original
        plan = try XCTUnwrap(ProjectRename.plan(project: project, reference: reference))
        for group in plan.groups.indices { for mention in plan.groups[group].mentions.indices { plan.groups[group].mentions[mention].selected = true } }
        XCTAssertEqual(try ProjectRename.apply(plan, to: &project), 5)
        XCTAssertEqual(project.chapters[1].plainText, "Nobody had seen Class for years.")
        XCTAssertEqual(ProjectTagReference.from(project.chapters[1].attributedText.attribute(.link, at: 16, effectiveRange: nil)), reference)
        XCTAssertEqual(project.chapters[0].synopsis, "Class returns home.")
        XCTAssertEqual(project.chapters[0].comments?.first?.note, "Does Class know?")
    }

    func testApplyingSkipsMentionsThatChangedSincePlanning() throws {
        var (project, reference) = try renamedProject()
        let plan = try XCTUnwrap(ProjectRename.plan(project: project, reference: reference))
        try project.chapters[0].setText(NSAttributedString(string: "Rewritten entirely."))
        XCTAssertEqual(try ProjectRename.apply(plan, to: &project), 0)
        XCTAssertEqual(project.chapters[0].plainText, "Rewritten entirely.")
    }
}
