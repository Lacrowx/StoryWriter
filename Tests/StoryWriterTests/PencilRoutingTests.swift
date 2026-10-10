import XCTest
import AppKit
@testable import StoryWriter

final class PencilRoutingTests: XCTestCase {
    func testShortFinalWordDoesNotDrawALeaderAcrossEmptyPage() throws {
        let word = NSRect(x: 50, y: 280, width: 100, height: 24)
        let route = try XCTUnwrap(PencilRouting.connector(lines: [PencilAnchorLine(selection: word, text: word)], textEdge: 1100, note: NSRect(x: 1110, y: 232, width: 170, height: 100)))
        XCTAssertGreaterThan(route.start.x, 1100)
        XCTAssertLessThan(route.end.x - route.start.x, 20)
        XCTAssertTrue(route.edgeMark)
        assertMonotonic(route)
    }

    func testConnectorNeverRunsAcrossTextFollowingSelectedWord() throws {
        let route = try XCTUnwrap(PencilRouting.connector(lines: [PencilAnchorLine(selection: NSRect(x: 460, y: 40, width: 85, height: 24), text: NSRect(x: 50, y: 40, width: 550, height: 24))], textEdge: 600, note: NSRect(x: 610, y: 35, width: 170, height: 80)))
        XCTAssertTrue(route.edgeMark)
        for step in 0...100 { XCTAssertGreaterThan(route.point(at: CGFloat(step) / 100).x, 600) }
    }

    func testWrappedPassageGetsOneBracketAndAMarginConnector() throws {
        let lines = [
            PencilAnchorLine(selection: NSRect(x: 410, y: 40, width: 190, height: 24), text: NSRect(x: 50, y: 40, width: 550, height: 24)),
            PencilAnchorLine(selection: NSRect(x: 50, y: 80, width: 100, height: 24), text: NSRect(x: 50, y: 80, width: 100, height: 24))
        ]
        let route = try XCTUnwrap(PencilRouting.connector(lines: lines, textEdge: 600, note: NSRect(x: 610, y: 35, width: 170, height: 80)))
        let bracket = try XCTUnwrap(route.bracket)
        XCTAssertLessThanOrEqual(bracket.minY, lines[0].selection.midY)
        XCTAssertGreaterThanOrEqual(bracket.maxY, lines[1].selection.midY)
        XCTAssertEqual(route.start.y, bracket.midY)
        for step in 0...100 { XCTAssertGreaterThan(route.point(at: CGFloat(step) / 100).x, 600) }
        assertMonotonic(route)
    }

    func testShortClearTailConnectsDirectlyWithoutOvershootingOrHooking() throws {
        let word = NSRect(x: 530, y: 40, width: 55, height: 24)
        let route = try XCTUnwrap(PencilRouting.connector(lines: [PencilAnchorLine(selection: word, text: NSRect(x: 50, y: 40, width: 535, height: 24))], textEdge: 600, note: NSRect(x: 610, y: 35, width: 170, height: 80)))
        XCTAssertFalse(route.edgeMark)
        XCTAssertNil(route.bracket)
        XCTAssertEqual(route.start.x, word.maxX + 4)
        assertMonotonic(route)
    }

    func testStackedNotesKeepTheirConnectorsInTheGutter() throws {
        let word = NSRect(x: 530, y: 40, width: 55, height: 24)
        let route = try XCTUnwrap(PencilRouting.connector(lines: [PencilAnchorLine(selection: word, text: word)], textEdge: 600, note: NSRect(x: 610, y: 250, width: 170, height: 80)))
        XCTAssertTrue(route.edgeMark)
        for step in 0...100 { XCTAssertGreaterThan(route.point(at: CGFloat(step) / 100).x, 600) }
        assertMonotonic(route)
    }

    private func assertMonotonic(_ route: PencilConnector, file: StaticString = #filePath, line: UInt = #line) {
        var previous = route.start
        for step in 1...100 {
            let point = route.point(at: CGFloat(step) / 100)
            XCTAssertGreaterThanOrEqual(point.x + 0.001, previous.x, file: file, line: line)
            XCTAssertGreaterThanOrEqual(point.y + 0.001, min(route.start.y, route.end.y), file: file, line: line)
            XCTAssertLessThanOrEqual(point.y - 0.001, max(route.start.y, route.end.y), file: file, line: line)
            previous = point
        }
    }
}
