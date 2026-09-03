import XCTest
@testable import ReadrKit

final class SpeechPrefetchWindowTests: XCTestCase {
    func testWindowStopsAtCapacityInsteadOfRestartingAtAnEvictedGap() {
        let durations = [20.0, 20, 20, 20, 20]
        let end = SpeechPrefetchWindow.endIndex(
            forAudioSeconds: durations,
            capacitySeconds: 60
        )

        XCTAssertEqual(end, 3)
        XCTAssertFalse(
            SpeechPrefetchWindow.shouldRefill(
                frontier: end,
                windowEnd: end,
                bufferedSeconds: 0,
                isForeground: true,
                wasRefilling: true,
                startsBelow: 30,
                stopsAt: 60
            ),
            "An evicted head creates a gap, but a completed bounded window stays complete"
        )
    }

    func testWindowLeavesSpaceAlreadyOccupiedBehindTheCursor() {
        let end = SpeechPrefetchWindow.endIndex(
            forAudioSeconds: [20, 20, 20, 20],
            capacitySeconds: 60,
            secondsBehindCursor: 20
        )

        XCTAssertEqual(end, 2)
    }

    func testBufferedPlaybackSecondsUseTheClampedReaderRate() {
        let baseAudio = 120.0
        let rows: [(requested: Double, expected: TimeInterval)] = [
            (SpeechSettings.rateRange.lowerBound, 240),
            (1, 120),
            (SpeechSettings.rateRange.upperBound, 60),
            (-100, 240),
            (100, 60),
        ]

        for row in rows {
            XCTAssertEqual(
                SpeechPrefetchWindow.playbackSeconds(
                    audioSeconds: baseAudio,
                    rate: row.requested
                ),
                row.expected,
                accuracy: 0.001
            )
        }
    }

    func testBackgroundRefillThresholdsUseRateAdjustedSeconds() {
        let startsBelow = 30 * 60.0
        let stopsAt = 60 * 60.0
        let baseAudio = 30 * 60.0

        XCTAssertFalse(
            refill(baseAudio: baseAudio, rate: 0.5, startsBelow: startsBelow, stopsAt: stopsAt),
            "At minimum rate, 30 minutes of audio is a full hour of playback"
        )
        XCTAssertFalse(
            refill(baseAudio: baseAudio, rate: 1, startsBelow: startsBelow, stopsAt: stopsAt),
            "At 1x, the start threshold is reached exactly"
        )
        XCTAssertTrue(
            refill(baseAudio: baseAudio, rate: 2, startsBelow: startsBelow, stopsAt: stopsAt),
            "At maximum rate, the same files provide only 15 minutes of playback"
        )

        XCTAssertFalse(
            SpeechPrefetchWindow.shouldRefill(
                frontier: 1,
                windowEnd: 2,
                bufferedSeconds: stopsAt,
                isForeground: false,
                wasRefilling: true,
                startsBelow: startsBelow,
                stopsAt: stopsAt
            ),
            "An active background refill stops at the rate-adjusted upper threshold"
        )
    }

    private func refill(
        baseAudio: TimeInterval,
        rate: Double,
        startsBelow: TimeInterval,
        stopsAt: TimeInterval
    ) -> Bool {
        SpeechPrefetchWindow.shouldRefill(
            frontier: 0,
            windowEnd: 2,
            bufferedSeconds: SpeechPrefetchWindow.playbackSeconds(
                audioSeconds: baseAudio,
                rate: rate
            ),
            isForeground: false,
            wasRefilling: false,
            startsBelow: startsBelow,
            stopsAt: stopsAt
        )
    }
}
