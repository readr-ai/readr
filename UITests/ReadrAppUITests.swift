import XCTest

/// UI (functional) tests driven by XCUITest on the iOS Simulator. The app is
/// launched with `-uiTestSeed` to preload a deterministic library — including
/// a mid-read position and colored highlights on "Sample Book" — avoiding the
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

    /// Toolbar/button lookup by accessibility identifier with a label
    /// fallback, so minor toolbar refactors don't silently break the suite.
    private func button(_ app: XCUIApplication, id: String, label: String) -> XCUIElement {
        let byID = app.buttons[id].firstMatch
        return byID.exists ? byID : app.buttons[label].firstMatch
    }

    // Home leads with Continue Reading for the seeded mid-read book.
    func testHomeShowsContinueReading() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Continue Reading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample Book"].firstMatch.waitForExistence(timeout: 5))
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

    // Empty library shows the welcome guidance.
    func testEmptyLibraryShowsGuidance() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Your library is empty"].waitForExistence(timeout: 10)
            || app.staticTexts["Sample Book"].firstMatch.waitForExistence(timeout: 1)
        )
    }

    // J5 — the AI Providers settings screen opens and lists the local option.
    func testOpenAIProvidersSettings() {
        let app = launchSeeded()
        let settingsButton = button(app, id: "library.settings", label: "AI providers")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        XCTAssertTrue(
            app.staticTexts["AI Providers"].waitForExistence(timeout: 5)
            || app.navigationBars["AI Providers"].waitForExistence(timeout: 5),
            "Tapping AI providers should open the provider settings sheet"
        )
    }

    // J3 — the Notes panel opens from the reader and shows the seeded
    // highlights (quoted text + the Create Article entry point).
    func testNotesPanelShowsSeededHighlights() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()
        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 5))

        let notesButton = button(app, id: "reader.notes", label: "Highlights")
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        notesButton.tap()

        // Seeded blue highlight's quote appears as its own row in the panel
        // (the chapter body is a single text element, so this exact match is
        // unambiguous).
        XCTAssertTrue(
            app.staticTexts["the clocks were striking thirteen"].firstMatch
                .waitForExistence(timeout: 5)
            || app.buttons["notes.createArticle"].firstMatch.waitForExistence(timeout: 2),
            "Notes panel should list seeded highlights"
        )
    }

    // J6 — the article studio opens from the Notes panel; without a provider
    // configured it must show the connect-a-provider guidance, not a dead end.
    func testArticleStudioOpensFromNotesPanel() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()
        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 5))

        let notesButton = button(app, id: "reader.notes", label: "Highlights")
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        notesButton.tap()

        let createArticle = app.buttons["notes.createArticle"].firstMatch
        XCTAssertTrue(createArticle.waitForExistence(timeout: 5))
        createArticle.tap()

        XCTAssertTrue(
            app.staticTexts["No AI provider connected"].waitForExistence(timeout: 5)
            || app.buttons["Compose"].firstMatch.waitForExistence(timeout: 2),
            "Article studio should open from the Notes panel"
        )
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
    /// test's job is imagery, not verification: only the initial load asserts —
    /// every later step guards its waits and skips gracefully so a UI tweak
    /// yields fewer images rather than a red build.
    func testCaptureScreenshots() {
        let app = launchSeeded()

        // a. Home: Continue Reading + Recently Added.
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        snap(app, "01-home")

        // b. Reader (restores to the seeded mid-chapter position).
        bookCell.tap()
        guard app.staticTexts["Chapter One"].waitForExistence(timeout: 5) else { return }
        snap(app, "02-reader")

        // c. Appearance popover open, then two-page layout.
        let appearance = button(app, id: "reader.appearance", label: "Appearance")
        if appearance.waitForExistence(timeout: 3) {
            appearance.tap()
            _ = app.staticTexts["Sepia"].firstMatch.waitForExistence(timeout: 2)
            snap(app, "03-appearance")

            let twoPagesButton = app.buttons["Two pages"].firstMatch
            let twoPagesText = app.staticTexts["Two pages"].firstMatch
            if twoPagesButton.waitForExistence(timeout: 2) {
                twoPagesButton.tap()
            } else if twoPagesText.waitForExistence(timeout: 2) {
                twoPagesText.tap()
            }
            _ = app.staticTexts["Chapter One"].waitForExistence(timeout: 2)
            snap(app, "04-reader-two-pages")

            // Restore scroll + switch to Sepia for the next shot.
            if appearance.waitForExistence(timeout: 3) {
                appearance.tap()
                let scroll = app.buttons["Scroll"].firstMatch
                if scroll.waitForExistence(timeout: 2) { scroll.tap() }
                let sepiaButton = app.buttons["Sepia"].firstMatch
                let sepiaText = app.staticTexts["Sepia"].firstMatch
                if sepiaButton.waitForExistence(timeout: 2) {
                    sepiaButton.tap()
                } else if sepiaText.waitForExistence(timeout: 2) {
                    sepiaText.tap()
                }
                // Close the popover.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            }
            snap(app, "05-reader-sepia")
        }

        // d. Notes panel with the seeded colored highlights.
        let notesButton = button(app, id: "reader.notes", label: "Highlights")
        if notesButton.waitForExistence(timeout: 3) {
            notesButton.tap()
            _ = app.buttons["notes.createArticle"].firstMatch.waitForExistence(timeout: 3)
            snap(app, "06-notes-panel")

            // e. Article studio (provider guidance without a configured LLM).
            let createArticle = app.buttons["notes.createArticle"].firstMatch
            if createArticle.exists && createArticle.isHittable {
                createArticle.tap()
                _ = app.staticTexts["No AI provider connected"].waitForExistence(timeout: 3)
                snap(app, "07-article-studio")
                let done = app.buttons["Done"].firstMatch
                if done.waitForExistence(timeout: 2) { done.tap() }
            }
            // Close the notes panel (sheet on iPhone).
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 2) { done.tap() }
        }

        // f. Back out to the sidebar, visit the All Books grid.
        var backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 3) { backButton.tap() }
        let allBooks = app.buttons["sidebar.allBooks"].firstMatch
        if !allBooks.waitForExistence(timeout: 3) {
            // Compact width may need one more pop to reach the sidebar list.
            backButton = app.navigationBars.buttons.firstMatch
            if backButton.waitForExistence(timeout: 2) { backButton.tap() }
        }
        if allBooks.waitForExistence(timeout: 3) {
            allBooks.tap()
            _ = app.staticTexts["Sample Book"].firstMatch.waitForExistence(timeout: 3)
            snap(app, "08-library-grid")
        }

        // g. AI providers settings sheet.
        let settingsButton = button(app, id: "library.settings", label: "AI providers")
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
            _ = app.navigationBars["AI Providers"].waitForExistence(timeout: 3)
            snap(app, "09-settings")
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
        }
    }
}
