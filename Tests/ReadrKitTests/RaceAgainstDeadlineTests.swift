import XCTest
@testable import ReadrKit

/// A synthesis that hangs must not hang the caller. The MLX engine's first
/// timeout was a `withThrowingTaskGroup`, which awaits every child before it
/// returns — and MLX synthesis cannot be cancelled — so the timer changed
/// nothing. This helper leaves the loser running and returns anyway.
final class RaceAgainstDeadlineTests: XCTestCase {

    private struct Boom: Error, Equatable {}

    func testFastWorkReturnsItsValue() async throws {
        let value = try await raceAgainstDeadline(seconds: 1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSlowWorkThrowsTheDeadlineErrorAtTheDeadline() async {
        let started = Date()
        do {
            _ = try await raceAgainstDeadline(seconds: 0.05) { () -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            XCTFail("expected the deadline to win")
        } catch let error as DeadlineExceeded {
            XCTAssertEqual(error.seconds, 0.05, accuracy: 0.0001)
            let elapsed = Date().timeIntervalSince(started)
            // At the deadline, not at the end of the work: well under the
            // two seconds the work would have taken.
            XCTAssertLessThan(elapsed, 1)
            XCTAssertGreaterThanOrEqual(elapsed, 0.04)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testAnErrorFromWorkPropagatesUnchanged() async {
        do {
            _ = try await raceAgainstDeadline(seconds: 1) { () -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch let error as Boom {
            XCTAssertEqual(error, Boom())
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTheLosingWorkKeepsRunningAndItsResultIsDropped() async throws {
        // The work finishes after the deadline: the caller has already been
        // resumed with the deadline error, and the late value goes nowhere —
        // in particular the continuation is not resumed a second time (that
        // would trap, which is what makes this a test).
        let finished = Flag()
        do {
            _ = try await raceAgainstDeadline(seconds: 0.05) { () -> Int in
                try? await Task.sleep(nanoseconds: 200_000_000)
                finished.set()
                return 7
            }
            XCTFail("expected the deadline to win")
        } catch is DeadlineExceeded {
            // expected
        }
        XCTAssertFalse(finished.isSet, "the work should still be running when the deadline wins")
        let waitedUntil = Date().addingTimeInterval(2)
        while !finished.isSet, Date() < waitedUntil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(finished.isSet, "the losing work keeps running to completion")
        // Give the late resume every chance to happen before the test ends.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testTheDeadlineTimerDoesNotOutliveAFastResult() async throws {
        // Many fast calls with long deadlines: none of them should leave a
        // timer that later resumes anything. (A double resume traps.)
        for index in 0..<50 {
            let value = try await raceAgainstDeadline(seconds: 10) { index }
            XCTAssertEqual(value, index)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    /// A thread-safe boolean for the tests above.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}
