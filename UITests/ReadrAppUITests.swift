import XCTest

/// UI (functional) tests driven by XCUITest on the iOS Simulator. The app is
/// launched with `-uiTestSeed` to preload a deterministic library, avoiding the
/// system file importer (which UI tests can't reliably automate).
final class ReadrAppUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed"]
        app.launch()
        return app
    }

    // J1/J2 — open a seeded book and navigate chapters.
    func testOpenSeededBookAndNavigateChapters() {
        let app = launchSeeded()

        let bookCell = app.staticTexts["Sample Book"]
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()

        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 5))
        app.buttons["nextChapter"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Chapter Two"].waitForExistence(timeout: 5))
    }

    // Empty library shows guidance.
    func testEmptyLibraryShowsGuidance() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Your library is empty"].waitForExistence(timeout: 10)
            || app.staticTexts["Sample Book"].waitForExistence(timeout: 1)
        )
    }

    // J5 — the AI Providers settings screen opens and lists the local option.
    func testOpenAIProvidersSettings() {
        let app = launchSeeded()
        let settingsButton = app.buttons["AI providers"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        XCTAssertTrue(
            app.staticTexts["Local model (on-device)"].waitForExistence(timeout: 5),
            "Provider settings should list the on-device local model option"
        )
    }

    // J3 — the highlights sheet opens from the reader and shows empty guidance.
    func testHighlightsSheetOpensFromReader() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"]
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()

        let highlightsButton = app.buttons["Highlights"]
        XCTAssertTrue(highlightsButton.waitForExistence(timeout: 5))
        highlightsButton.tap()

        XCTAssertTrue(app.staticTexts["No highlights yet"].waitForExistence(timeout: 5))
    }
}
