import XCTest
@testable import ReadrKit

/// The welcome-back line: offered only to a reader who has been away a day
/// or more and has somewhere to come back to; worded in the roundest
/// honest unit; gone after a few page turns.
final class WelcomeBackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    // MARK: - Whether to offer it

    func testOfferedAfterADayAwayWithProgress() {
        XCTAssertTrue(WelcomeBack.shouldOffer(lastOpenedAt: ago(1), now: now, hasProgress: true))
        XCTAssertTrue(WelcomeBack.shouldOffer(lastOpenedAt: ago(6), now: now, hasProgress: true))
    }

    func testNotOfferedWithinADay() {
        XCTAssertFalse(WelcomeBack.shouldOffer(lastOpenedAt: ago(0.99), now: now, hasProgress: true))
        XCTAssertFalse(WelcomeBack.shouldOffer(lastOpenedAt: now, now: now, hasProgress: true))
    }

    /// A first open has nothing read to recap — and the stamp is nil then.
    func testNotOfferedOnAFirstOpenOrWithoutProgress() {
        XCTAssertFalse(WelcomeBack.shouldOffer(lastOpenedAt: nil, now: now, hasProgress: true))
        XCTAssertFalse(WelcomeBack.shouldOffer(lastOpenedAt: ago(6), now: now, hasProgress: false))
    }

    /// A clock that went backwards must not read as a long absence.
    func testAFutureStampIsNotAnAbsence() {
        XCTAssertFalse(WelcomeBack.shouldOffer(lastOpenedAt: now.addingTimeInterval(3_600), now: now, hasProgress: true))
    }

    /// The top of page one is what a book opened and closed unread looks
    /// like: no progress. Anything past it is.
    func testProgressIsAnyPositionPastTheStart() {
        XCTAssertFalse(WelcomeBack.hasProgress(nil))
        XCTAssertFalse(WelcomeBack.hasProgress(ReadingPosition(chapterIndex: 0, characterOffset: 0)))
        XCTAssertTrue(WelcomeBack.hasProgress(ReadingPosition(chapterIndex: 0, characterOffset: 1)))
        XCTAssertTrue(WelcomeBack.hasProgress(ReadingPosition(chapterIndex: 1, characterOffset: 0)))
    }

    func testScrollLayoutDismissesAfterTwoMinutesOfReading() {
        XCTAssertEqual(WelcomeBack.scrollReadingBeforeDismissal, 120)
    }

    // MARK: - Wording

    func testDaysUnderTwoWeeks() {
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(1), to: now), "it’s been a day")
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(1.9), to: now), "it’s been a day")
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(6), to: now), "it’s been 6 days")
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(13), to: now), "it’s been 13 days")
    }

    func testWeeksUnderTwoMonths() {
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(14), to: now), "it’s been 2 weeks")
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(45), to: now), "it’s been 6 weeks")
    }

    func testMonthsUnderAYear() {
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(60), to: now), "it’s been 2 months")
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(200), to: now), "it’s been 6 months")
    }

    func testYears() {
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(365), to: now), "it’s been a year")
        XCTAssertEqual(WelcomeBack.absencePhrase(from: ago(800), to: now), "it’s been 2 years")
    }

    /// Below the threshold the phrase is still well-formed (the rule keeps it
    /// from being shown, but the wording must never say "0 days").
    func testNeverZeroDays() {
        XCTAssertEqual(WelcomeBack.absencePhrase(from: now, to: now), "it’s been a day")
    }

    func testDismissalIsAfterThreePageTurns() {
        XCTAssertEqual(WelcomeBack.pageTurnsBeforeDismissal, 3)
    }
}
