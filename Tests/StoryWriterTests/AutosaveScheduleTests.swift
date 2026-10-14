import XCTest
@testable import StoryWriter

final class AutosaveScheduleTests: XCTestCase {
    func testBriefPausesBatchWritesAndContinuousTypingStillSaves() {
        var schedule = AutosaveSchedule()
        var writes: [Double] = []
        // A writer pauses for one second between words for a full minute.
        // Even a chosen 0.7-second pause must not write once per word.
        for tick in 0...600 {
            let time = Double(tick) / 10
            if tick % 10 == 0 { schedule.edited(at: time) }
            if let deadline = schedule.deadline(idleDelay: 0.7), deadline <= time {
                writes.append(time)
                schedule.beganSave(); schedule.saved(at: time)
            }
        }
        XCTAssertEqual(writes.count, 6)
        for (previous, next) in zip(writes, writes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next - previous, 10 - 0.001)
        }
        XCTAssertLessThanOrEqual(writes[0], 30)

        schedule = AutosaveSchedule()
        for second in 0...29 { schedule.edited(at: Double(second)) }
        XCTAssertEqual(schedule.deadline(idleDelay: 2), 30)
    }

    func testPauseDeadlineMovesWithoutResettingMaximumWait() {
        var schedule = AutosaveSchedule()
        XCTAssertNil(schedule.deadline(idleDelay: 2))
        schedule.edited(at: 0)
        XCTAssertEqual(schedule.deadline(idleDelay: 2), 2)
        schedule.edited(at: 1.5)
        XCTAssertEqual(schedule.deadline(idleDelay: 2), 3.5)
        schedule.edited(at: 29)
        XCTAssertEqual(schedule.deadline(idleDelay: 5), 30)
    }

    func testEditsDuringSaveKeepTheirOwnDeadlineAndManualSaveClearsIt() {
        var schedule = AutosaveSchedule()
        schedule.edited(at: 0); schedule.beganSave()
        schedule.edited(at: 1); schedule.saved(at: 2)
        XCTAssertEqual(schedule.pendingSince, 1)
        XCTAssertEqual(schedule.deadline(idleDelay: 2), 12)
        schedule.beganSave(); schedule.saved(at: 3)
        XCTAssertNil(schedule.deadline(idleDelay: 2))
    }
}
