import XCTest
@testable import Readr

final class AskPreferencesTests: XCTestCase {
    func testAnswerFontSizeIsClampedToSupportedRange() {
        XCTAssertEqual(
            AskPreferences.clampedAnswerFontSize(AskPreferences.minimumAnswerFontSize - 10),
            AskPreferences.minimumAnswerFontSize
        )
        XCTAssertEqual(AskPreferences.clampedAnswerFontSize(17), 17)
        XCTAssertEqual(
            AskPreferences.clampedAnswerFontSize(AskPreferences.maximumAnswerFontSize + 10),
            AskPreferences.maximumAnswerFontSize
        )
    }

    func testContextRangeRawValuesAreStableForPersistence() {
        XCTAssertEqual(AskContextRange.nearby.rawValue, "nearby")
        XCTAssertEqual(AskContextRange.readSoFar.rawValue, "readSoFar")
        XCTAssertEqual(AskContextRange.wholeBook.rawValue, "wholeBook")
    }
}
