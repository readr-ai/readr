import XCTest
@testable import ReadrKit

final class NeuralVoiceAvailabilityTests: XCTestCase {
    func testCrashProneOSMatrixMatchesFluidAudioAdvisory() {
        let cases: [(major: Int, minor: Int, onMacOS: Bool, expected: Bool)] = [
            (26, 3, false, false),
            (26, 3, true, false),
            (26, 4, false, true),
            (26, 4, true, true),
            (26, 5, false, true),
            (26, 5, true, true),
            (26, 6, false, true),
            (26, 6, true, false),
            (26, 9, false, true),
            (26, 9, true, false),
            (26, 10, false, true),
            (25, 9, false, false),
            (25, 9, true, false),
            (27, 0, false, true),
            (27, 0, true, false),
            (28, 1, false, true),
        ]

        for testCase in cases {
            let platform = testCase.onMacOS ? "macOS" : "iOS/iPadOS"
            XCTAssertEqual(
                NeuralVoiceAvailability.isCrashProneOS(
                    major: testCase.major,
                    minor: testCase.minor,
                    onMacOS: testCase.onMacOS
                ),
                testCase.expected,
                "Unexpected result for \(platform) \(testCase.major).\(testCase.minor)"
            )
        }
    }
}
