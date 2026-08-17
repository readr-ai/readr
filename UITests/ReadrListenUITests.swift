import XCTest
#if canImport(UIKit)
import UIKit
#endif

/// Lane C — read-aloud. The playback *rules* are unit-tested in ReadrKit
/// (`NarrationControllerTests`); these assert the app half of the journey: the
/// Listen control is reachable on every idiom, starting narration puts the bar
/// on screen with all of its controls, each control is operable, and closing
/// the bar ends narration.
///
/// Launched with `-uiTestSilentNarration`, which swaps the synthesizer for a
/// soundless stand-in (`UITestStubSpeechEngine`). The whole pipeline is real —
/// controller, bar, follow-along — but narration only moves when a control
/// moves it. Against a live synthesizer on a headless runner, an utterance
/// that fails instantly would race the book to its end before a test could tap
/// anything, and every assertion below would be a timing flake.
final class ReadrListenUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Helpers (mirroring ReadrFlowUITests)

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "-uiTestSilentNarration"]
        #if !canImport(UIKit)
        // Keep the macOS run off the real Keychain (see ReadrFlowUITests).
        app.launchArguments += ["-uiTestInMemoryCredentials"]
        #endif
        app.launch()
        return app
    }

    private func waitForText(
        _ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10
    ) -> Bool {
        let match = NSPredicate(
            format: "label == %@ OR value == %@ OR title == %@", text, text, text
        )
        if app.descendants(matching: .any).matching(match).firstMatch
            .waitForExistence(timeout: timeout) {
            return true
        }
        return app.menuItems.matching(match).firstMatch.exists
    }

    private func anyElement(_ app: XCUIApplication, label text: String) -> XCUIElement {
        let match = NSPredicate(
            format: "label == %@ OR value == %@ OR title == %@", text, text, text
        )
        let button = app.buttons.matching(match).firstMatch
        if button.waitForExistence(timeout: 3) { return button }
        return app.descendants(matching: .any).matching(match).firstMatch
    }

    /// A row of an open menu. SwiftUI publishes menu rows as `menuItems` on
    /// macOS and as `buttons` on iOS, and a selected Picker row can carry a
    /// checkmark in its label — so match by substring across both types.
    private func menuRow(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        let match = NSPredicate(
            format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@",
            text, text, text
        )
        let item = app.menuItems.matching(match).firstMatch
        if item.waitForExistence(timeout: 3) { return item }
        let button = app.buttons.matching(match).firstMatch
        if button.waitForExistence(timeout: 3) { return button }
        return app.descendants(matching: .any).matching(match).firstMatch
    }

    /// Anything carrying `id`, whatever element type SwiftUI exposes it as
    /// (the bar mixes Buttons and Menus).
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openSampleBook(_ app: XCUIApplication) {
        XCTAssertTrue(waitForText(app, "Sample Book"))
        let bookCell = anyElement(app, label: "Sample Book")
        #if canImport(UIKit)
        bookCell.tap()
        #else
        // Mac library cards open on double-click; retried once because the
        // first click after launch can land while the window takes focus.
        bookCell.doubleClick()
        if !waitForText(app, "Chapter One", timeout: 5) {
            anyElement(app, label: "Sample Book").doubleClick()
        }
        #endif
        XCTAssertTrue(waitForText(app, "Chapter One"))
    }

    /// Opens the seeded book and starts narration.
    @discardableResult
    private func startListening(_ app: XCUIApplication) -> XCUIApplication {
        openSampleBook(app)
        let listen = element(app, "reader.listen")
        XCTAssertTrue(
            listen.waitForExistence(timeout: 5), "The reader should offer a Listen control"
        )
        listen.tap()
        XCTAssertTrue(
            element(app, "listen.bar").waitForExistence(timeout: 5),
            "Starting narration should reveal the Listen bar"
        )
        return app
    }

    private func assertGone(_ element: XCUIElement, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    // MARK: - Starting

    func testListenControlIsReachableInTheReader() {
        let app = launchSeeded()
        openSampleBook(app)
        XCTAssertTrue(
            element(app, "reader.listen").waitForExistence(timeout: 5),
            "The Listen control should be reachable by identifier on this idiom"
        )
        XCTAssertFalse(
            element(app, "listen.bar").exists,
            "The bar stays away until the reader asks to listen"
        )
    }

    func testStartingNarrationShowsTheBarWithEveryControl() {
        let app = launchSeeded()
        startListening(app)

        for id in [
            "listen.previousChapter", "listen.previous", "listen.playPause",
            "listen.next", "listen.nextChapter",
            "listen.speed", "listen.voice", "listen.sleep", "listen.close",
        ] {
            XCTAssertTrue(
                element(app, id).waitForExistence(timeout: 5),
                "Narration control '\(id)' should be on the Listen bar"
            )
        }
    }

    func testTheBarNamesTheSentenceBeingRead() {
        let app = launchSeeded()
        startListening(app)

        let sentence = element(app, "listen.sentence")
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        XCTAssertTrue(
            sentence.label.contains("Now reading:"),
            "The read-along line should say what is being read (got: \(sentence.label))"
        )
    }

    // MARK: - Transport

    func testPlayPauseTogglesBothWays() {
        let app = launchSeeded()
        startListening(app)

        let playPause = element(app, "listen.playPause")
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        XCTAssertEqual(playPause.label, "Pause", "Narration starts speaking")

        playPause.tap()
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Play",
            "Pausing should flip the control to Play"
        )

        element(app, "listen.playPause").tap()
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Pause",
            "Playing again should flip it back"
        )
    }

    func testSkipControlsKeepNarrationRunning() {
        let app = launchSeeded()
        startListening(app)

        // Each skip cancels the utterance in flight and starts the next; the
        // bar must survive all four and still be speaking afterwards.
        for id in [
            "listen.next", "listen.previous", "listen.nextChapter", "listen.previousChapter",
        ] {
            let skip = element(app, id)
            XCTAssertTrue(skip.waitForExistence(timeout: 5))
            skip.tap()
            XCTAssertTrue(element(app, "listen.bar").exists, "The bar should survive '\(id)'")
        }
        XCTAssertEqual(element(app, "listen.playPause").label, "Pause")
    }

    func testSkippingSentencesMovesTheReadAlongLine() {
        let app = launchSeeded()
        startListening(app)

        let first = element(app, "listen.sentence").label
        element(app, "listen.next").tap()
        let second = element(app, "listen.sentence").label
        XCTAssertNotEqual(first, second, "Skipping forward should move to another sentence")

        element(app, "listen.previous").tap()
        XCTAssertEqual(
            element(app, "listen.sentence").label, first,
            "Skipping back should return to the sentence before"
        )
    }

    // MARK: - Voice settings

    func testSpeedMenuOffersTheSpeedsAndAppliesOne() {
        let app = launchSeeded()
        startListening(app)

        let speed = element(app, "listen.speed")
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        speed.tap()

        // Speeds are labelled "0.75×" … "2×".
        let faster = menuRow(app, containing: "1.5\u{00D7}")
        XCTAssertTrue(faster.waitForExistence(timeout: 5), "The speed menu should offer 1.5×")
        faster.tap()

        XCTAssertTrue(
            waitForText(app, "1.5\u{00D7}", timeout: 5),
            "The speed control should show the chosen speed"
        )
        XCTAssertTrue(element(app, "listen.bar").exists, "Changing speed keeps narration up")
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Pause",
            "A speed change re-speaks the sentence rather than stopping"
        )
    }

    func testSleepTimerMenuArmsATimer() {
        let app = launchSeeded()
        startListening(app)

        let sleep = element(app, "listen.sleep")
        XCTAssertTrue(sleep.waitForExistence(timeout: 5))
        sleep.tap()

        let fifteen = menuRow(app, containing: "15 min")
        XCTAssertTrue(fifteen.waitForExistence(timeout: 5), "The sleep menu should offer 15 min")
        fifteen.tap()

        XCTAssertTrue(
            element(app, "listen.sleep").waitForExistence(timeout: 5),
            "The sleep control stays on the bar once armed"
        )
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Pause",
            "Arming a sleep timer must not stop narration"
        )
    }

    func testVoiceMenuOpens() {
        let app = launchSeeded()
        startListening(app)

        let voice = element(app, "listen.voice")
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()
        // Better voices are a system download, and the menu says so whether or
        // not this simulator has any installed beyond the default.
        XCTAssertTrue(
            menuRow(app, containing: "More voices").waitForExistence(timeout: 5),
            "The voice menu should say where more voices come from"
        )
    }

    // MARK: - Stopping

    func testClosingTheBarEndsNarration() {
        let app = launchSeeded()
        startListening(app)

        let close = element(app, "listen.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        assertGone(element(app, "listen.bar"))
        // The reader is still there, on the page narration left it at.
        XCTAssertTrue(element(app, "reader.listen").exists)
        XCTAssertTrue(waitForText(app, "Chapter One", timeout: 5))
    }

    func testListenControlStopsNarrationWhenPressedAgain() {
        let app = launchSeeded()
        startListening(app)

        let listen = element(app, "reader.listen")
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        XCTAssertEqual(
            listen.label, "Stop listening", "The control flips while narrating"
        )
        listen.tap()
        assertGone(element(app, "listen.bar"))
    }
}
