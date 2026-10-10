import XCTest
import AppKit
@testable import StoryWriter

final class PencilCommentTests: XCTestCase {
    func testOnlyMatchingUnresolvedAnchorsAppearOnPage() {
        let text = "👩🏽‍💻 Ada waits. Ben leaves."
        let range = (text as NSString).range(of: "Ada")
        let valid = PassageComment(start: range.location, length: range.length, quote: "Ada", note: "Who is she waiting for?")
        var resolved = valid; resolved.id = UUID(); resolved.resolved = true
        var detached = valid; detached.id = UUID(); detached.detached = true
        var stale = valid; stale.id = UUID(); stale.quote = "Ben"
        let invalid = PassageComment(start: Int.max, length: 3, quote: "Ada", note: "Bad anchor")
        XCTAssertEqual(PencilComments.attached([resolved, valid, detached, stale, invalid], to: text).map(\.id), [valid.id])
        XCTAssertTrue(PencilComments.attached([valid], to: text.replacingOccurrences(of: "Ada", with: "Eva")).isEmpty)
    }

    @MainActor func testSideNotesStackAndEditWithoutChangingManuscript() throws {
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 400))
        view.isRichText = true; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        let text = NSAttributedString(string: "Ada waits. Ben arrives.\n\nA longer paragraph follows.", attributes: WritingStyle.attributes)
        view.textStorage?.setAttributedString(text)
        let layer = PencilCommentLayer(view: view); view.pencilComments = layer
        let first = PassageComment(start: 0, length: 3, quote: "Ada", note: "Give her a reason to wait here. She needs something concrete to do in this moment.")
        let second = PassageComment(start: 11, length: 3, quote: "Ben", note: "This arrival feels too convenient.")
        var edited: (UUID, String)?
        layer.update([first, second], enabled: true, change: { id, change in if case .note(let text) = change { edited = (id, text) } })
        view.layout()
        let notes = layer.notes.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(notes.count, 2)
        XCTAssertGreaterThanOrEqual(notes[1].frame.minY, notes[0].frame.maxY + 8)
        XCTAssertLessThanOrEqual(notes[1].frame.maxY, view.bounds.height)
        XCTAssertGreaterThan(notes[0].frame.minX, view.textContainerOrigin.x + view.textContainer!.size.width)
        XCTAssertLessThanOrEqual(notes[0].frame.maxX, view.bounds.width)
        XCTAssertTrue(view.textContainer!.exclusionPaths.isEmpty)
        let next = (view.string as NSString).range(of: "A longer")
        let glyph = view.layoutManager!.glyphIndexForCharacter(at: next.location)
        let nextLine = view.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: 0, dy: view.textContainerOrigin.y)
        XCTAssertLessThan(nextLine.minY, notes[1].frame.maxY)
        notes[0].editor.string = "A directly edited note"
        notes[0].textDidChange(Notification(name: NSText.didChangeNotification, object: notes[0].editor))
        XCTAssertEqual(edited?.0, first.id)
        XCTAssertEqual(edited?.1, "A directly edited note")
        XCTAssertTrue(view.attributedString().isEqual(to: text))
        layer.update([first, second], enabled: false, change: { _, _ in })
        view.layout()
        XCTAssertTrue(layer.notes.isEmpty)
        XCTAssertEqual(view.pencilColumnWidth, 0)
        XCTAssertTrue(view.textContainer!.exclusionPaths.isEmpty)
        XCTAssertTrue(view.attributedString().isEqual(to: text))
    }

    @MainActor func testSideNotesStayOnNarrowPagesAndFollowReflow() {
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 400))
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textStorage?.setAttributedString(NSAttributedString(string: "Ada waits for the last ferry to arrive and watches the water.\n\nBen arrives.", attributes: WritingStyle.attributes))
        let range = (view.string as NSString).range(of: "Ben")
        let comment = PassageComment(start: range.location, length: range.length, quote: "Ben", note: "Why so late?")
        let layer = PencilCommentLayer(view: view); view.pencilComments = layer
        layer.update([comment], enabled: true, change: { _, _ in })
        view.layout()
        let initialY = layer.notes[0].frame.minY
        for width in [600.0, 450, 320] {
            view.setFrameSize(NSSize(width: width, height: 400)); view.layout()
            XCTAssertGreaterThanOrEqual(view.textContainer!.size.width, 220)
            XCTAssertLessThanOrEqual(layer.notes[0].frame.maxX, width)
            XCTAssertGreaterThan(layer.notes[0].frame.minX, view.textContainerOrigin.x + view.textContainer!.size.width)
        }
        XCTAssertGreaterThan(layer.notes[0].frame.minY, initialY)
    }

    func testInkPersistsAndOlderCommentsGetStableColors() throws {
        let old = Data(#"{"id":"B12EC696-70BB-4E4C-91F8-0C115C7D31A5","start":0,"length":3,"quote":"Ada","note":"Wait","resolved":false,"detached":false,"createdAt":0}"#.utf8)
        var comment = try JSONDecoder().decode(PassageComment.self, from: old)
        XCTAssertNil(comment.ink)
        XCTAssertEqual(comment.pencilInk, try JSONDecoder().decode(PassageComment.self, from: old).pencilInk)
        comment.ink = .rose
        XCTAssertEqual(try JSONDecoder().decode(PassageComment.self, from: JSONEncoder().encode(comment)).ink, .rose)
    }

    @MainActor func testMarginConnectorIsVisibleOutsideTextContainer() throws {
        let view = ManuscriptTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 400))
        view.appearance = NSAppearance(named: .aqua)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.textStorage?.setAttributedString(NSAttributedString(string: "Ada waits for the ferry.", attributes: WritingStyle.attributes))
        let layer = PencilCommentLayer(view: view); view.pencilComments = layer
        var comment = PassageComment(start: 0, length: 3, quote: "Ada", note: "Why is she here?")
        comment.ink = .rose
        layer.update([comment], enabled: true, change: { _, _ in })
        view.layout()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 840, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 840, height: 400).fill()
        let transform = NSAffineTransform(); transform.translateX(by: 0, yBy: 400); transform.scaleX(by: 1, yBy: -1); transform.concat()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let edge = Int(ceil(view.textContainerOrigin.x + view.textContainer!.size.width))
        let noteEdge = Int(layer.notes[0].frame.minX)
        var coloredPixels = 0
        for x in edge..<noteEdge {
            for y in 0..<400 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > color.greenComponent + 0.12 { coloredPixels += 1 }
            }
        }
        XCTAssertGreaterThan(coloredPixels, 4, "Pencil connector must remain visible in the margin after drawing the manuscript")
    }
}
