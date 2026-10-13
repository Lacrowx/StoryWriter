import XCTest
import AppKit
import SwiftUI
import Combine
@testable import StoryWriter

/// End-to-end keystroke cost in the real workspace with a novel-length project.
final class TypingBenchmarkTests: XCTestCase {
    @MainActor func testWorkspaceKeystrokeCost() throws {
        let automatic = LocalGrammarService.shared.automatic
        LocalGrammarService.shared.automatic = false
        defer { LocalGrammarService.shared.automatic = automatic }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TypingBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "TypingBenchmark-\(UUID())")!
        let store = ProjectStore(root: root, createExample: false, workspaceDefaults: defaults)
        let id = store.create(title: "Novel", kind: .story)
        let paragraph = "Mara crossed the square while Cole waited by the fountain, counting the bells. "
        store.update(id) { project in
            project.characters = ["Mara Vance", "Cole Marsh", "Ines", "Tobias Grey"].map { Character(name: $0) }
            project.chapters = (0..<25).map { index in
                var chapter = Chapter(title: "Chapter \(index + 1)")
                let text = String(repeating: paragraph + "\n", count: 300) // ~4,000 words
                chapter.setEditingText(NSAttributedString(string: text, attributes: WritingStyle.attributes))
                return chapter
            }
        }
        // A comment after the typing point must stay anchored without view refreshes.
        store.update(id) { project in
            let text = project.chapters[0].plainText as NSString
            let quote = "counting the bells", start = text.range(of: quote, options: .backwards).location
            project.chapters[0].comments = [PassageComment(start: start, length: quote.utf16.count, quote: quote, note: "Check")]
        }
        _ = store.saveNow()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LibraryView().environmentObject(store))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func pump(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        var editor: ManuscriptTextView?
        for _ in 0..<60 where editor == nil {
            pump()
            editor = Self.all(ManuscriptTextView.self, in: window.contentView!).max { $0.string.utf16.count < $1.string.utf16.count }
            if (editor?.string.utf16.count ?? 0) < 1000 { editor = nil }
        }
        let view = try XCTUnwrap(editor, "Editor did not appear")
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length / 2, length: 0))
        pump(0.3)
        var samples: [Double] = []
        for character in "The quick brown fox jumps over" {
            let start = CFAbsoluteTimeGetCurrent()
            view.insertText(String(character), replacementRange: view.selectedRange())
            // Let SwiftUI apply the resulting store change, then draw.
            RunLoop.main.run(until: Date())
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        let median = samples[samples.count / 2], p90 = samples[samples.count * 9 / 10]
        print(String(format: "Workspace keystroke, 100k-word project: median %.2f ms, p90 %.2f ms", median, p90))
        let typed = try XCTUnwrap(store.project(id)!.chapters.first { $0.plainText.contains("The quick brown fox") })
        let comment = try XCTUnwrap(typed.comments?.first)
        XCTAssertEqual((typed.plainText as NSString).substring(with: comment.range), comment.quote)
        XCTAssertLessThan(p90, 100, "Occasional keystrokes must also stay responsive")
        XCTAssertLessThan(median, 50, "Typing has regressed to a visible lag") // Was ~800 ms before render throttling.
        func command(_ title: String, in commands: [ContextCommand]) -> ContextCommand? {
            for item in commands {
                if item.title == title { return item }
                if let children = item.children, let found = command(title, in: children) { return found }
            }
            return nil
        }
        let continuity = try XCTUnwrap(command("Continuity", in: view.appContextCommands()))
        continuity.action?(); pump()
        var sidebarSamples: [Double] = []
        for character in " Writing with continuity open stays smooth." {
            let start = CFAbsoluteTimeGetCurrent()
            view.insertText(String(character), replacementRange: view.selectedRange()); pump(0.001)
            sidebarSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        sidebarSamples.sort()
        let sidebarMedian = sidebarSamples[sidebarSamples.count / 2]
        print(String(format: "Workspace keystroke with continuity open, 100k-word project: median %.2f ms, p90 %.2f ms", sidebarMedian, sidebarSamples[sidebarSamples.count * 9 / 10]))
        XCTAssertLessThan(sidebarSamples[sidebarSamples.count * 9 / 10], 100)
        XCTAssertLessThan(sidebarMedian, 50, "Continuity must not make typing visibly lag")
        let repetitions = max(100, min(1000, Int(ProcessInfo.processInfo.environment["STORYWRITER_PROFILE_KEYS"] ?? "") ?? 100))
        for deleting in [false, true] {
            var eventSamples: [Double] = [], frameGaps: [Double] = []
            var keyboardSamples: [Double] = [], layoutSamples: [Double] = [], drawSamples: [Double] = []
            var grammarPublications = 0
            let grammarObservation = view.grammarSession?.objectWillChange.sink { grammarPublications += 1 }
            var cursorPublications = 0
            let cursorObservation = view.contextEditor?.objectWillChange.sink { cursorPublications += 1 }
            var previousTick = CFAbsoluteTimeGetCurrent()
            let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
                let now = CFAbsoluteTimeGetCurrent()
                frameGaps.append((now - previousTick) * 1000)
                previousTick = now
            }
            for _ in 0..<repetitions {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: deleting ? "\u{7f}" : "a", charactersIgnoringModifiers: deleting ? "\u{7f}" : "a",
                    isARepeat: deleting, keyCode: deleting ? 51 : 0))
                let start = CFAbsoluteTimeGetCurrent()
                view.keyDown(with: event)
                let keyboardEnd = CFAbsoluteTimeGetCurrent()
                window.contentView?.layoutSubtreeIfNeeded()
                let layoutEnd = CFAbsoluteTimeGetCurrent()
                window.displayIfNeeded()
                let drawEnd = CFAbsoluteTimeGetCurrent()
                keyboardSamples.append((keyboardEnd - start) * 1000)
                layoutSamples.append((layoutEnd - keyboardEnd) * 1000)
                drawSamples.append((drawEnd - layoutEnd) * 1000)
                eventSamples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                pump(0.02)
            }
            heartbeat.invalidate()
            withExtendedLifetime((cursorObservation, grammarObservation)) {}
            print("Review-bar publications during \(deleting ? "Backspace" : "typing"): \(grammarPublications)")
            XCTAssertEqual(grammarPublications, 0, "Repeated keys must not redraw an empty review bar")
            eventSamples.sort(); frameGaps.sort()
            keyboardSamples.sort(); layoutSamples.sort(); drawSamples.sort()
            XCTAssertLessThan(eventSamples[repetitions * 9 / 10], 100, "Sustained native input must remain responsive")
            print(String(format: "Native %@, %d repeated keys: median %.2f ms, p90 %.2f ms, worst %.2f ms; longest main-loop gap %.2f ms", deleting ? "Backspace" : "typing", repetitions, eventSamples[repetitions / 2], eventSamples[repetitions * 9 / 10], eventSamples.last ?? 0, frameGaps.last ?? 0))
            print(String(format: "Native %@ stages p90: keyboard %.2f ms; layout %.2f ms; draw %.2f ms; cursor publications %d", deleting ? "Backspace" : "typing", keyboardSamples[repetitions * 9 / 10], layoutSamples[repetitions * 9 / 10], drawSamples[repetitions * 9 / 10], cursorPublications))
        }
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) }
    }
}
