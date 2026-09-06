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

    private func launchSeeded(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "-uiTestSilentNarration"] + extraArguments
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

    // MARK: - Listen from a selection

    /// Select a word mid-page, tap the annotation bar's headphones, and the
    /// Listen bar appears reading the sentence the word is in — the fix for
    /// "there's no way to start from the middle of a chapter".
    ///
    /// Same LIMITATION as the highlight-from-selection flow in
    /// ReadrFlowUITests: XCUITest has no text-selection API, so a long-press
    /// (then a double-tap) is attempted and the test SKIPS if neither raises
    /// the annotation bar on this simulator boot.
    func testListenFromSelectionStartsNarrationAtThatSentence() throws {
        let app = launchSeeded()
        openSampleBook(app)

        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "The reading surface should be present")

        let listenHere = element(app, "annotation.listen")
        var barIsUp = false
        for dy in [0.5, 0.65, 0.3, 0.42] {
            let point = text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
            point.press(forDuration: 1.2)
            if !listenHere.waitForExistence(timeout: 5) {
                point.doubleTap()
                _ = listenHere.waitForExistence(timeout: 5)
            }
            if listenHere.exists { barIsUp = true; break }
        }
        guard barIsUp else {
            throw XCTSkip(
                "No annotation bar at any probed press point — word selection "
                    + "isn't automatable on this simulator boot. The seek rule is "
                    + "pinned in ReadrKit (SpeechPlaylistTests, NarrationControllerTests)."
            )
        }
        // Whatever sentence the press landed in is what the bar must read.
        listenHere.tap()

        XCTAssertTrue(
            element(app, "listen.bar").waitForExistence(timeout: 5),
            "Listen from here should reveal the Listen bar"
        )
        let sentence = element(app, "listen.sentence")
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        let spoken = (sentence.label.isEmpty ? sentence.value as? String : sentence.label) ?? ""
        XCTAssertFalse(
            spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "The bar should name the sentence being read"
        )
        // Closing the bar stops narration, as with the toolbar Listen.
        element(app, "listen.close").tap()
        XCTAssertTrue(element(app, "listen.bar").waitForNonExistence(timeout: 5))
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

        // The card: ◀ ● ▶, speed, sleep, ✕. Chapter skips live in Contents
        // and the voice in the Aa popover (September 2026 UX review, F6).
        for id in [
            "listen.previous", "listen.playPause", "listen.next",
            "listen.speed", "listen.sleep", "listen.close",
        ] {
            XCTAssertTrue(
                element(app, id).waitForExistence(timeout: 5),
                "Narration control '\(id)' should be on the Listen card"
            )
        }
        for id in ["listen.previousChapter", "listen.nextChapter", "listen.voice", "listen.ahead"] {
            XCTAssertFalse(element(app, id).exists, "'\(id)' left the card")
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

    // MARK: - Visible narration states (#82 follow-up)

    /// `-uiTestNarrationPreparing` makes the stub report every utterance as
    /// preparing and never speaking — the deterministic stand-in for the
    /// real Readr Voice first-use download, which a UI test can't drive.
    func testPreparingStateShowsOnTheBar() {
        let app = launchSeeded(extraArguments: ["-uiTestNarrationPreparing"])
        startListening(app)

        let preparing = element(app, "listen.preparing")
        XCTAssertTrue(preparing.waitForExistence(timeout: 5))
        XCTAssertTrue(
            preparing.label.contains("Preparing Readr Voice"),
            "The bar should say Readr Voice is preparing (got: \(preparing.label))"
        )
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Pause",
            "Preparing still shows Pause — it pauses the wait, the way it pauses speech"
        )
    }

    /// `-uiTestNarrationHold` makes the stub immediately suspend every
    /// utterance for `.needsForeground` — the deterministic stand-in for the
    /// buffer running out with the screen locked, which a UI test can't
    /// force a real engine into.
    func testHoldStateShowsThePausedCopy() {
        let app = launchSeeded(extraArguments: ["-uiTestNarrationHold"])
        startListening(app)

        let hold = element(app, "listen.hold")
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        XCTAssertEqual(hold.label, "Paused \u{2014} unlock Readr to keep listening")
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Play",
            "A hold is not underway — the control offers Play, not Pause"
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
            "listen.next", "listen.previous",
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

    // The narrator is chosen in the Aa popover, once — not on every card —
    // which means BEFORE the first Listen too: the voices are resolved for
    // the popover, not by starting narration.
    func testVoiceCanBeChosenBeforeListening() {
        let app = launchSeeded()
        openSampleBook(app)

        let appearance = element(app, "reader.appearance")
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let voice = element(app, "appearance.voice")
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "the Aa popover should offer the voice")
        XCTAssertFalse(
            ((voice.value as? String) ?? "").isEmpty,
            "The row should name the book's voice before anything has been read aloud"
        )
        voice.tap()
        XCTAssertTrue(menuRow(app, containing: "More voices").waitForExistence(timeout: 5))
        let none = NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@",
                               "No voices installed", "No voices installed")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(none).firstMatch.exists,
            "The voices are resolved for the popover, not only when narration starts"
        )
    }

    // Contents is the card's chapter skip: a jump there takes the voice
    // along, rather than the voice reading on where it was and turning the
    // page straight back.
    func testContentsJumpTakesTheVoiceAlong() {
        let app = launchSeeded()
        startListening(app)
        let sentence = element(app, "listen.sentence")
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        let before = sentence.label

        let toc = element(app, "reader.toc")
        XCTAssertTrue(toc.waitForExistence(timeout: 5))
        toc.tap()
        let chapterTwo = app.buttons["Chapter Two"].firstMatch
        XCTAssertTrue(chapterTwo.waitForExistence(timeout: 5))
        chapterTwo.tap()

        XCTAssertTrue(
            app.staticTexts["Chapter Two"].waitForExistence(timeout: 5),
            "The page should turn to Chapter Two"
        )
        expectation(
            for: NSPredicate(format: "label != %@", before), evaluatedWith: sentence
        )
        waitForExpectations(timeout: 5)
        XCTAssertEqual(
            element(app, "listen.playPause").label, "Pause",
            "The voice keeps reading, from the chapter the reader chose"
        )
        // Not turned back by the voice: it is reading here now.
        sleep(3)
        XCTAssertTrue(
            app.staticTexts["Chapter Two"].exists,
            "The page must stay on the chapter the reader jumped to"
        )
    }

    // The narrator is chosen in the Aa popover, once — not on every card.
    func testVoiceMenuOpensFromAppearance() {
        let app = launchSeeded()
        startListening(app)

        let appearance = element(app, "reader.appearance")
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let voice = element(app, "appearance.voice")
        XCTAssertTrue(voice.waitForExistence(timeout: 5), "the Aa popover should offer the voice")
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

    // MARK: - Listen in a PDF

    /// Listen in a PDF starts on the page in view, not at the top of the
    /// document — the dense-PDF half of "no way to start from the middle".
    /// The seeded Field Notes PDF has two pages with distinct text; on page 2
    /// the bar must name a page-2 sentence.
    func testListenInAPDFStartsOnThePageInView() {
        let app = launchSeeded()
        openFieldNotesPDF(app)
        pageSeededPDFToPageTwo(app)

        let listen = element(app, "reader.listen")
        XCTAssertTrue(listen.waitForExistence(timeout: 5), "The PDF reader should offer Listen")
        listen.tap()
        XCTAssertTrue(element(app, "listen.bar").waitForExistence(timeout: 10), "Listen on a PDF page should start narration")

        let sentence = element(app, "listen.sentence")
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        let spoken = (sentence.label.isEmpty ? sentence.value as? String : sentence.label) ?? ""
        XCTAssertTrue(
            spoken.contains("season") || spoken.contains("gaps"),
            "Listen on page 2 should start with page 2's text, got: \(spoken)"
        )
        XCTAssertFalse(
            spoken.contains("promise to your future self"),
            "Listen on page 2 must not start from page 1: \(spoken)"
        )
    }
}
