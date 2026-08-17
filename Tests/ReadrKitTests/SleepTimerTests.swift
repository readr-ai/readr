import XCTest
@testable import ReadrKit

/// The sleep timer's arithmetic, driven by injected dates rather than a real
/// clock — the point of a listening feature is that the reader falls asleep,
/// so "15 minutes" has to mean 15 minutes of *listening*.
final class SleepTimerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testOffNeverExpires() {
        let timer = SleepTimerState()
        XCTAssertEqual(timer.mode, .off)
        XCTAssertFalse(timer.hasExpired(at: start.addingTimeInterval(86_400)))
        XCTAssertNil(timer.remaining(at: start))
        XCTAssertFalse(timer.stopsAtChapterEnd)
    }

    func testATimedSleepExpiresWhenItRunsOut() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 15), at: start)
        XCTAssertFalse(timer.hasExpired(at: start.addingTimeInterval(14 * 60)))
        XCTAssertTrue(timer.hasExpired(at: start.addingTimeInterval(15 * 60)))
        XCTAssertTrue(timer.hasExpired(at: start.addingTimeInterval(60 * 60)))
    }

    func testRemainingCountsDownAndStopsAtZero() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 10), at: start)
        XCTAssertEqual(timer.remaining(at: start) ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(90)) ?? 0, 510, accuracy: 0.001)
        XCTAssertEqual(
            timer.remaining(at: start.addingTimeInterval(9_999)) ?? -1, 0, accuracy: 0.001
        )
    }

    func testPausingHoldsTheCountdown() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 30), at: start)
        // Five minutes of listening, then a long pause.
        timer.pause(at: start.addingTimeInterval(5 * 60))
        let afterLunch = start.addingTimeInterval(60 * 60)
        XCTAssertFalse(timer.hasExpired(at: afterLunch), "A paused timer must not run out")
        XCTAssertEqual(timer.remaining(at: afterLunch) ?? 0, 25 * 60, accuracy: 0.001)

        timer.resume(at: afterLunch)
        XCTAssertFalse(timer.hasExpired(at: afterLunch.addingTimeInterval(24 * 60)))
        XCTAssertTrue(timer.hasExpired(at: afterLunch.addingTimeInterval(25 * 60)))
    }

    func testResumingWithoutAPauseChangesNothing() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 10), at: start)
        let deadline = timer.deadline
        timer.resume(at: start.addingTimeInterval(60))
        XCTAssertEqual(timer.deadline, deadline)
    }

    func testReArmingRestartsTheCountdown() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 15), at: start)
        let later = start.addingTimeInterval(14 * 60)
        timer.arm(.after(minutes: 15), at: later)
        XCTAssertFalse(timer.hasExpired(at: later.addingTimeInterval(14 * 60)))
        XCTAssertTrue(timer.hasExpired(at: later.addingTimeInterval(15 * 60)))
    }

    func testEndOfChapterNeverExpiresOnTheClock() {
        var timer = SleepTimerState()
        timer.arm(.endOfChapter, at: start)
        XCTAssertTrue(timer.stopsAtChapterEnd)
        XCTAssertFalse(timer.hasExpired(at: start.addingTimeInterval(86_400)))
        XCTAssertNil(timer.remaining(at: start))
    }

    func testDisarmingClearsEverything() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 5), at: start)
        timer.disarm()
        XCTAssertEqual(timer.mode, .off)
        XCTAssertNil(timer.deadline)
        XCTAssertNil(timer.remaining(at: start))
        XCTAssertFalse(timer.hasExpired(at: start.addingTimeInterval(86_400)))
    }

    func testArmingOffClearsATimedSleep() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 5), at: start)
        timer.arm(.off, at: start)
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.hasExpired(at: start.addingTimeInterval(86_400)))
    }

    func testASleepOfZeroMinutesIsTreatedAsOneRatherThanInstant() {
        var timer = SleepTimerState()
        timer.arm(.after(minutes: 0), at: start)
        XCTAssertFalse(timer.hasExpired(at: start))
        XCTAssertTrue(timer.hasExpired(at: start.addingTimeInterval(60)))
    }

    func testDisplayNames() {
        XCTAssertEqual(SleepTimer.off.displayName, "Off")
        XCTAssertEqual(SleepTimer.after(minutes: 15).displayName, "15 min")
        XCTAssertEqual(SleepTimer.endOfChapter.displayName, "End of chapter")
        XCTAssertFalse(SleepTimer.off.isOn)
        XCTAssertTrue(SleepTimer.after(minutes: 5).isOn)
        XCTAssertTrue(SleepTimer.endOfChapter.isOn)
    }

    func testEveryOfferedDurationIsUsable() {
        for minutes in SleepTimer.minuteOptions {
            var timer = SleepTimerState()
            timer.arm(.after(minutes: minutes), at: start)
            XCTAssertFalse(timer.hasExpired(at: start))
            XCTAssertTrue(timer.hasExpired(at: start.addingTimeInterval(Double(minutes) * 60)))
        }
    }
}
