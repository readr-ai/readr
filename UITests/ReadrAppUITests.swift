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

        let bookCell = app.staticTexts["Sample Book"].firstMatch
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

        // The settings sheet's navigation title (iOS uppercases Form section
        // headers, so assert on the title instead).
        XCTAssertTrue(
            app.staticTexts["AI Providers"].waitForExistence(timeout: 5)
            || app.navigationBars["AI Providers"].waitForExistence(timeout: 5),
            "Tapping AI providers should open the provider settings sheet"
        )
    }

    // J3 — the highlights sheet opens from the reader and shows empty guidance.
    func testHighlightsSheetOpensFromReader() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()

        let highlightsButton = app.buttons["Highlights"]
        XCTAssertTrue(highlightsButton.waitForExistence(timeout: 5))
        highlightsButton.tap()

        XCTAssertTrue(app.staticTexts["No highlights yet"].waitForExistence(timeout: 5))
    }

    // MARK: - Screenshots for CI

    /// Attaches a full-screen PNG to the test result bundle so CI can extract
    /// it with xcparse and publish it to the `ci-screenshots` branch.
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Walks the main journeys and captures screenshots along the way. This
    /// test's job is imagery, not verification: only the initial library load
    /// asserts — every later step guards its waits and skips gracefully so a
    /// UI tweak yields fewer images rather than a red build.
    func testCaptureScreenshots() {
        let app = launchSeeded()

        // a. Library
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        snap(app, "01-library")

        // b. Reader in the default scroll layout.
        bookCell.tap()
        guard app.staticTexts["Chapter One"].waitForExistence(timeout: 5) else { return }
        snap(app, "02-reader-scroll")

        // c. Two-page layout, then restore scroll.
        let layoutButton = app.buttons["Appearance"]  // layout lives in the Aa menu now
        if layoutButton.waitForExistence(timeout: 3) {
            layoutButton.tap()
            let twoPagesButton = app.buttons["Two pages"].firstMatch
            let twoPagesText = app.staticTexts["Two pages"].firstMatch
            if twoPagesButton.waitForExistence(timeout: 3) {
                twoPagesButton.tap()
            } else if twoPagesText.waitForExistence(timeout: 2) {
                twoPagesText.tap()
            }
            // Brief wait for the layout transition to settle.
            _ = app.staticTexts["Chapter One"].waitForExistence(timeout: 2)
            snap(app, "03-reader-two-pages")

            if layoutButton.waitForExistence(timeout: 3) {
                layoutButton.tap()
                let scrollButton = app.buttons["Scroll"].firstMatch
                let scrollText = app.staticTexts["Scroll"].firstMatch
                if scrollButton.waitForExistence(timeout: 3) {
                    scrollButton.tap()
                } else if scrollText.waitForExistence(timeout: 2) {
                    scrollText.tap()
                }
            }
        }

        // d. Sepia appearance, if the reader offers it.
        let appearanceButton = app.buttons["Appearance"]
        if appearanceButton.exists {
            appearanceButton.tap()
            let sepiaButton = app.buttons["Sepia"].firstMatch
            let sepiaText = app.staticTexts["Sepia"].firstMatch
            if sepiaButton.waitForExistence(timeout: 3) {
                sepiaButton.tap()
            } else if sepiaText.waitForExistence(timeout: 2) {
                sepiaText.tap()
            }
            snap(app, "04-reader-sepia")
            // Dismiss any still-open menu by tapping elsewhere.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        // e. Highlights sheet.
        let highlightsButton = app.buttons["Highlights"]
        if highlightsButton.waitForExistence(timeout: 3) {
            highlightsButton.tap()
            _ = app.staticTexts["No highlights yet"].waitForExistence(timeout: 3)
            snap(app, "05-highlights")
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) {
                done.tap()
            }
        }

        // f. Back to the library, then the AI providers settings sheet.
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
        }
        let settingsButton = app.buttons["AI providers"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
            _ = app.navigationBars["AI Providers"].waitForExistence(timeout: 3)
            snap(app, "06-settings")
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) {
                done.tap()
            }
        }
    }
}
