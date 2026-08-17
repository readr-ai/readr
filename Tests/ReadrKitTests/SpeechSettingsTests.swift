import XCTest
@testable import ReadrKit

/// Speed, pitch and volume — the controls that are easiest to put into an
/// unusable state, so every one of them is clamped and the clamping is tested.
final class SpeechSettingsTests: XCTestCase {

    // MARK: - Clamping

    func testInitializerClampsOutOfRangeValues() {
        let fast = SpeechSettings(rate: 99, pitch: 99, volume: 99)
        XCTAssertEqual(fast.rate, SpeechSettings.rateRange.upperBound)
        XCTAssertEqual(fast.pitch, SpeechSettings.pitchRange.upperBound)
        XCTAssertEqual(fast.volume, SpeechSettings.volumeRange.upperBound)

        let slow = SpeechSettings(rate: -5, pitch: -5, volume: -5)
        XCTAssertEqual(slow.rate, SpeechSettings.rateRange.lowerBound)
        XCTAssertEqual(slow.pitch, SpeechSettings.pitchRange.lowerBound)
        XCTAssertEqual(slow.volume, SpeechSettings.volumeRange.lowerBound)
    }

    func testAssignmentClampsToo() {
        var settings = SpeechSettings()
        settings.rate = 10
        settings.pitch = 0
        settings.volume = 2
        XCTAssertEqual(settings.rate, 2.0)
        XCTAssertEqual(settings.pitch, 0.5)
        XCTAssertEqual(settings.volume, 1.0)
    }

    func testNonFiniteValuesDoNotEscapeTheRange() {
        let settings = SpeechSettings(rate: .nan, pitch: .infinity, volume: -.infinity)
        XCTAssertTrue(SpeechSettings.rateRange.contains(settings.rate))
        XCTAssertTrue(SpeechSettings.pitchRange.contains(settings.pitch))
        XCTAssertTrue(SpeechSettings.volumeRange.contains(settings.volume))
    }

    func testDecodingClampsAValueWrittenByAnotherBuild() throws {
        let json = Data(#"{"rate":9,"pitch":0.1,"volume":5}"#.utf8)
        let settings = try JSONDecoder().decode(SpeechSettings.self, from: json)
        XCTAssertEqual(settings.rate, 2.0)
        XCTAssertEqual(settings.pitch, 0.5)
        XCTAssertEqual(settings.volume, 1.0)
        XCTAssertTrue(settings.autoAdvancesChapters, "Missing keys keep the default")
    }

    func testRoundTripsThroughCoding() throws {
        let original = SpeechSettings(
            rate: 1.25, pitch: 0.9, volume: 0.8,
            voiceID: "com.apple.voice.test", autoAdvancesChapters: false
        )
        let decoded = try JSONDecoder().decode(
            SpeechSettings.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Rate mapping

    func testNormalRateMapsToTheEngineDefault() {
        let settings = SpeechSettings(rate: 1)
        XCTAssertEqual(
            settings.platformRate(normal: 0.5, minimum: 0, maximum: 1), 0.5, accuracy: 0.0001
        )
    }

    func testTheSlowEndReachesTheEngineMinimum() {
        XCTAssertEqual(
            SpeechSettings(rate: 0.5).platformRate(normal: 0.5, minimum: 0, maximum: 1),
            0.0, accuracy: 0.0001
        )
    }

    func testTheFastEndStopsWellShortOfTheEngineMaximum() {
        // The label has to be the truth. AVFoundation's rate scale climbs
        // steeply above its default, so spreading 1x...2x linearly across the
        // remaining range made "2x" play about four times as fast — measured by
        // rendering the synthesizer's PCM and timing the same sentence. Roughly
        // a third of the headroom is a genuine doubling.
        let doubled = SpeechSettings(rate: 2).platformRate(normal: 0.5, minimum: 0, maximum: 1)
        XCTAssertEqual(doubled, 0.672, accuracy: 0.005)
        XCTAssertLessThan(doubled, 1.0, "Reaching the engine's maximum was the bug")
    }

    func testEverySpeedAboveNormalScalesFromTheSameCurve() {
        // Each step is an equal share of the headroom the curve actually needs,
        // so the gaps between labels stay even rather than compounding.
        let mapped = [1.0, 1.25, 1.5, 1.75, 2.0].map {
            SpeechSettings(rate: $0).platformRate(normal: 0.5, minimum: 0, maximum: 1)
        }
        let gaps = zip(mapped, mapped.dropFirst()).map { $1 - $0 }
        for gap in gaps {
            XCTAssertEqual(gap, gaps[0], accuracy: 0.0001)
        }
    }

    func testRateMapsMonotonicallyBetweenTheEnds() {
        let steps = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        let mapped = steps.map {
            SpeechSettings(rate: $0).platformRate(normal: 0.5, minimum: 0.1, maximum: 1)
        }
        for (slower, faster) in zip(mapped, mapped.dropFirst()) {
            XCTAssertLessThan(slower, faster)
        }
    }

    // MARK: - The speed control

    func testCyclingRateStepsUpThenWrapsAround() {
        XCTAssertEqual(SpeechSettings(rate: 0.75).cyclingRate(), 1.0)
        XCTAssertEqual(SpeechSettings(rate: 1.0).cyclingRate(), 1.25)
        XCTAssertEqual(SpeechSettings(rate: 1.75).cyclingRate(), 2.0)
        XCTAssertEqual(SpeechSettings(rate: 2.0).cyclingRate(), 0.75, "Wraps to the slowest step")
    }

    func testCyclingFromAnOffStepRateMovesToTheNextStepUp() {
        XCTAssertEqual(SpeechSettings(rate: 1.1).cyclingRate(), 1.25)
        XCTAssertEqual(SpeechSettings(rate: 0.5).cyclingRate(), 0.75)
    }

    func testRateLabelsReadTheWayTheControlShowsThem() {
        XCTAssertEqual(SpeechSettings.rateLabel(1), "1\u{00D7}")
        XCTAssertEqual(SpeechSettings.rateLabel(2), "2\u{00D7}")
        XCTAssertEqual(SpeechSettings.rateLabel(1.25), "1.25\u{00D7}")
        XCTAssertEqual(SpeechSettings.rateLabel(0.75), "0.75\u{00D7}")
    }

    func testEveryOfferedSpeedIsInsideTheAllowedRange() {
        for step in SpeechSettings.rateSteps {
            XCTAssertTrue(SpeechSettings.rateRange.contains(step))
            XCTAssertEqual(SpeechSettings(rate: step).rate, step)
        }
    }
}
