import XCTest

/// Widen the Ask panel's scope to the whole book.
///
/// The scope is a segmented "Answers from" Picker (`ask.scope`), and XCUITest
/// exposes a SwiftUI segmented control differently per platform — a
/// `segmentedControl` with button children on iPhone and iPad, radio buttons
/// on macOS — so the flow tests share one selector that tries each shape
/// rather than each guessing its own.
func selectWholeBook(
    _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
) {
    let control = app.segmentedControls["ask.scope"].firstMatch
    if control.waitForExistence(timeout: 5) {
        let segment = control.buttons["Whole book"].firstMatch
        if segment.waitForExistence(timeout: 2) {
            segment.tap()
            return
        }
    }
    let plain = app.buttons["Whole book"].firstMatch
    if plain.waitForExistence(timeout: 2) {
        plain.tap()
        return
    }
    let radio = app.radioButtons["Whole book"].firstMatch
    if radio.waitForExistence(timeout: 2) {
        radio.tap()
        return
    }
    XCTFail("a text book offers the Whole book scope segment", file: file, line: line)
}
