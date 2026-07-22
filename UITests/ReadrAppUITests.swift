import XCTest

/// UI (functional) tests driven by XCUITest on the iOS Simulator. The app is
/// launched with `-uiTestSeed` to preload a deterministic library — including
/// a mid-read position and colored highlights on "Sample Book" — avoiding the
/// system file importer (which UI tests can't reliably automate).
final class ReadrAppUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchSeeded(stubLLM: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed"]
        // Canned local provider (screenshot walk's second pass only) so the
        // Ask flow can be captured end-to-end; the first pass stays
        // provider-less to keep the guidance empty states in the gallery.
        if stubLLM { app.launchArguments += ["-uiTestStubLLM"] }
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

    // #42 — a fresh install opens EPUBs in Single page layout, not Scroll.
    // The paged footer's "Page x of y" label only renders in paged layouts,
    // so its presence proves which layout the reader started in.
    // -uiTestFreshDefaults clears any layout choice a previous test persisted.
    func testReaderDefaultsToSinglePage() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "-uiTestFreshDefaults"]
        app.launch()

        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()

        let pageLabel = app.staticTexts["reader.pageLabel"].firstMatch
        XCTAssertTrue(
            pageLabel.waitForExistence(timeout: 10),
            "A fresh install should open the reader paged (Single page), not in Scroll"
        )
        XCTAssertTrue(
            pageLabel.label.hasPrefix("Page "),
            "The paged footer should read 'Page x of y' (got: \(pageLabel.label))"
        )
    }

    // J1/J2 — open a seeded book and navigate chapters. iOS has no chapter
    // chevrons (Apple Books-style: swipe or the Contents list) — this drives
    // the Contents path; the swipe path is covered by
    // ReadrFlowUITests.testScrollModeSwipeCrossesChapters.
    func testOpenSeededBookAndNavigateChapters() {
        let app = launchSeeded()

        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()

        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 5))
        let toc = app.buttons["reader.toc"].firstMatch
        XCTAssertTrue(toc.waitForExistence(timeout: 5))
        toc.tap()
        let chapterTwo = app.buttons["Chapter Two"].firstMatch
        XCTAssertTrue(chapterTwo.waitForExistence(timeout: 5))
        chapterTwo.tap()
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

    // M6 (TestFlight beta) — subscription OAuth stays hidden until the flow is
    // verified end-to-end on iOS (the loopback redirect needs the in-process
    // browser work tracked for M7). The beta must only surface working paths,
    // so the settings screen offers API-key fields but no sign-in button.
    // M7 flips this assertion when it re-enables OAuth.
    func testProviderSettingsOffersNoOAuthSignIn() {
        let app = launchSeeded()
        let settingsButton = button(app, id: "library.settings", label: "AI providers")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        XCTAssertTrue(
            app.staticTexts["AI Providers"].waitForExistence(timeout: 5)
            || app.navigationBars["AI Providers"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.buttons["Sign in with subscription"].firstMatch.exists,
            "Subscription OAuth is not beta-ready; the sign-in button must stay hidden"
        )
    }

    // A6 — first-run copy must never advertise a connection path this build
    // doesn't expose. On iOS the Local row is hidden, so "pick a local model"
    // must not appear; subscription OAuth is hidden, so "sign in" must not
    // appear either. The Ask/compose empty states derive their copy from
    // SettingsModel.setupGuidance, so this asserts on the compose empty state
    // (reached from the Notes panel) which is provider-less by default.
    func testFirstRunCopyOmitsUnavailablePaths() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()
        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 5))

        // Open the Notes panel → Create Article, which shows the provider-less
        // compose empty state whose copy comes from setupGuidance.
        let notes = button(app, id: "reader.notes", label: "Highlights")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        let createArticle = app.buttons["notes.createArticle"].firstMatch
        XCTAssertTrue(createArticle.waitForExistence(timeout: 5))
        createArticle.tap()

        let guidance = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Add an API key")
        ).firstMatch
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertFalse(
            guidance.label.contains("pick a local model"),
            "iOS hides the Local provider, so the copy must not advertise it (got: \(guidance.label))"
        )
        XCTAssertFalse(
            guidance.label.lowercased().contains("sign in"),
            "Subscription OAuth is hidden, so the copy must not advertise 'sign in' (got: \(guidance.label))"
        )
    }

    // A7 — the currently-selected connected provider carries an "Active" badge
    // so both connected cards don't read an indistinguishable "Connected".
    // -uiTestSkipProviderValidation keeps the saved key "Connected" offline
    // (no real authenticated test call), so the badge is deterministic in CI.
    func testActiveBadgeMarksSelectedProvider() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestSeed", "-uiTestInMemoryCredentials", "-uiTestSkipProviderValidation",
        ]
        app.launch()

        let settingsButton = button(app, id: "library.settings", label: "AI providers")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(
            app.staticTexts["AI Providers"].waitForExistence(timeout: 5)
            || app.navigationBars["AI Providers"].waitForExistence(timeout: 5)
        )

        // Save an Anthropic key → it becomes the active selection.
        let keyField = app.secureTextFields["settings.apiKey.anthropic"].firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("sk-ant-uitest-key")
        app.buttons["settings.saveKey.anthropic"].firstMatch.tap()

        // The Active badge appears on the selected (Anthropic) card only.
        let anthropicBadge = app.staticTexts["settings.activeBadge.anthropic"].firstMatch
        XCTAssertTrue(
            anthropicBadge.waitForExistence(timeout: 5),
            "The just-connected provider should show the Active badge"
        )
        // The un-selected OpenAI card must not carry the Active badge.
        XCTAssertFalse(
            app.staticTexts["settings.activeBadge.openAI"].firstMatch.exists,
            "Only the selected provider should be badged Active"
        )
    }

    // Launch-friction guard: a first-run user must be able to get from the
    // key field to the provider's key console without hunting for the URL.
    // SwiftUI `Link` surfaces as a link or a button depending on platform,
    // so accept either element type.
    func testProviderSettingsLinksToAPIKeyConsoles() {
        let app = launchSeeded()
        let settingsButton = button(app, id: "library.settings", label: "AI providers")
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        XCTAssertTrue(
            app.staticTexts["AI Providers"].waitForExistence(timeout: 5)
            || app.navigationBars["AI Providers"].waitForExistence(timeout: 5)
        )
        for slug in ["anthropic", "openai"] {
            let id = "settings.getKey.\(slug)"
            // Short wait: the sheet is already rendered (title asserted
            // above), so this only absorbs accessibility-tree settling.
            let present = app.links[id].firstMatch.waitForExistence(timeout: 2)
                || app.buttons[id].firstMatch.exists
                || app.otherElements[id].firstMatch.exists
            XCTAssertTrue(present, "Missing get-a-key link for \(slug)")
        }
    }

    // J3 — the Notes panel opens from the reader and shows the seeded
    // highlights (quoted text + the Create Article entry point).
    func testNotesPanelShowsSeededHighlights() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()
        // 10s, not 5: the suite's first test pays the simulator's cold-start
        // cost — run #28973952628 saw the reader take >5s to first paint.
        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 10))

        let notesButton = button(app, id: "reader.notes", label: "Highlights")
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        notesButton.tap()

        // Seeded blue highlight's quote appears as its own row in the panel
        // (the chapter body is a single text element, so this exact match is
        // unambiguous).
        XCTAssertTrue(
            app.staticTexts["the clocks were striking thirteen"].firstMatch
                .waitForExistence(timeout: 5),
            "Notes panel should list the seeded highlight's quoted text"
        )
        XCTAssertTrue(
            app.buttons["notes.createArticle"].firstMatch.waitForExistence(timeout: 2),
            "Notes panel should offer the Create Article entry point"
        )
    }

    // J6 — the article studio opens from the Notes panel; without a provider
    // configured it must show the connect-a-provider guidance, not a dead end.
    func testArticleStudioOpensFromNotesPanel() {
        let app = launchSeeded()
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()
        // 10s, not 5: the suite's first test pays the simulator's cold-start
        // cost — run #28973952628 saw the reader take >5s to first paint.
        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 10))

        let notesButton = button(app, id: "reader.notes", label: "Highlights")
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        notesButton.tap()

        let createArticle = app.buttons["notes.createArticle"].firstMatch
        XCTAssertTrue(createArticle.waitForExistence(timeout: 5))
        createArticle.tap()

        // The seeded run has no provider configured, so the guidance screen
        // is deterministic — assert it specifically.
        XCTAssertTrue(
            app.staticTexts["No AI provider connected"].waitForExistence(timeout: 5),
            "Article studio should show the connect-a-provider guidance"
        )
    }

    // MARK: - Ask the book (A1 / A5 / A4)

    /// Open Sample Book and its Ask panel, driving through the seeded library.
    /// Returns the launched app so callers can keep asserting.
    private func openAskPanel(_ app: XCUIApplication) {
        let bookCell = app.staticTexts["Sample Book"].firstMatch
        XCTAssertTrue(bookCell.waitForExistence(timeout: 10))
        bookCell.tap()
        XCTAssertTrue(app.staticTexts["Chapter One"].waitForExistence(timeout: 10))
        let ask = button(app, id: "reader.ask", label: "Ask the book")
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.tap()
        XCTAssertTrue(app.navigationBars["Ask the book"].waitForExistence(timeout: 5))
    }

    // A1 — the Ask panel refreshes after a key is saved from its own empty
    // state: no app restart, the guidance gives way to the ask UI. Launched
    // WITHOUT -uiTestStubLLM so the provider-less empty state renders, and
    // with an in-memory credential store so the save stays off the Keychain.
    // -uiTestSkipProviderValidation keeps the saved key "Connected" offline:
    // this test exercises the panel's refresh out of the empty state, not the
    // authenticated probe. Without it the fake key is live-validated, rejected
    // as .invalid, and activeProvider() refuses to resolve it — so the panel
    // would never leave the "No AI provider connected" state.
    func testAskPanelRefreshesAfterConnectingProvider() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestSeed", "-uiTestInMemoryCredentials", "-uiTestSkipProviderValidation",
        ]
        app.launch()

        openAskPanel(app)

        // Empty state: no provider yet.
        XCTAssertTrue(
            app.staticTexts["No AI provider connected"].waitForExistence(timeout: 5),
            "Ask panel should start in the connect-a-provider empty state"
        )

        // Route to provider settings from the empty state's action button.
        app.buttons["Open AI Providers"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["AI Providers"].waitForExistence(timeout: 5)
            || app.staticTexts["AI Providers"].waitForExistence(timeout: 5)
        )

        // Save an Anthropic key, then dismiss the sheet.
        let keyField = app.secureTextFields["settings.apiKey.anthropic"].firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        keyField.tap()
        keyField.typeText("sk-ant-uitest-key")
        app.buttons["settings.saveKey.anthropic"].firstMatch.tap()
        // Dismiss the keyboard first: tapping the nav-bar "Done" while the
        // keyboard is up makes XCUITest try (and fail) a scroll-to-visible on a
        // non-scrollable nav bar (kAXErrorCannotComplete). A coordinate tap on
        // the already-on-screen Done avoids the AX scroll action entirely.
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Back in the Ask panel: onDismiss re-resolved the provider, so the
        // empty state is gone and the ask input is present — no relaunch.
        XCTAssertTrue(
            app.buttons["ask.send"].waitForExistence(timeout: 5),
            "Ask panel should refresh out of the empty state after a key is saved"
        )
        XCTAssertFalse(
            app.staticTexts["No AI provider connected"].exists,
            "The empty-state guidance should be gone once a provider is connected"
        )
    }

    // A5 — an ask failure surfaces the mapped, actionable error sentence and a
    // Retry that re-runs the same question. -uiTestStubError makes the stub
    // fail the stream with a transport timeout that HTTPError maps to a plain
    // sentence.
    func testAskErrorShowsActionableMessageAndRetry() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "-uiTestStubLLM", "-uiTestStubError"]
        app.launch()

        openAskPanel(app)

        let suggestion = app.buttons["Summarize this book"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        let send = app.buttons["ask.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        // Mapped HTTPError sentence, not Foundation's generic message.
        XCTAssertTrue(
            app.staticTexts["The request to the provider timed out."]
                .waitForExistence(timeout: 10),
            "The error state should show the mapped, actionable sentence"
        )
        let retry = app.buttons["ask.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 3), "A Retry affordance should appear on error")

        // Retry re-runs the same question — the error card reappears (the stub
        // still fails), proving the retry re-invoked the ask.
        let errorCard = app.otherElements["ask.error"].firstMatch
        XCTAssertTrue(errorCard.waitForExistence(timeout: 3))
        retry.tap()
        XCTAssertTrue(
            app.staticTexts["The request to the provider timed out."]
                .waitForExistence(timeout: 10),
            "Retry should re-run the same question and surface the error again"
        )
    }

    // A4 — a whole-book answer shows the honest no-citations copy and never a
    // Sources list. -uiTestStubWholeBook makes the stub report a remote model
    // so the small seeded book routes to the whole-book tier.
    func testAskWholeBookShowsHonestNoCitationsCopy() {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSeed", "-uiTestStubLLM", "-uiTestStubWholeBook"]
        app.launch()

        openAskPanel(app)

        let suggestion = app.buttons["Summarize this book"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        let send = app.buttons["ask.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        // Wait for the stub's streamed tail phrase, then assert the honest
        // whole-book footer and the absence of a fabricated Sources list.
        _ = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "tone of decay")
        ).firstMatch.waitForExistence(timeout: 15)

        XCTAssertTrue(
            app.staticTexts["USING THE WHOLE BOOK"].waitForExistence(timeout: 5)
            || app.otherElements["ask.wholeBookNote"].waitForExistence(timeout: 5),
            "Whole-book answers should show the honest no-citations note"
        )
        XCTAssertFalse(
            app.staticTexts["SOURCES"].exists,
            "The whole-book tier must not promise a Sources list"
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

        // c. Appearance popover: pick Sepia (popover stays open for live
        // preview), then "Single page" — layout choices dismiss the popover,
        // so the toolbar is immediately tappable again. (iOS offers no
        // facing-page spread, Apple-Books-style.)
        let appearance = button(app, id: "reader.appearance", label: "Appearance")
        if appearance.waitForExistence(timeout: 3), appearance.isHittable {
            appearance.tap()
            _ = app.staticTexts["Sepia"].firstMatch.waitForExistence(timeout: 2)
            snap(app, "03-appearance")

            let sepia = app.buttons["Sepia"].firstMatch
            if sepia.waitForExistence(timeout: 2), sepia.isHittable { sepia.tap() }

            let singlePageSepia = app.buttons["Single page"].firstMatch
            if singlePageSepia.waitForExistence(timeout: 2), singlePageSepia.isHittable {
                singlePageSepia.tap() // dismisses the popover
            }
            _ = app.staticTexts["Chapter One"].waitForExistence(timeout: 2)
            snap(app, "04-reader-page-sepia")

            // Back to scroll for the remaining shots (sepia stays).
            if appearance.waitForExistence(timeout: 3), appearance.isHittable {
                appearance.tap()
                let scroll = app.buttons["Scroll"].firstMatch
                if scroll.waitForExistence(timeout: 2), scroll.isHittable {
                    scroll.tap() // dismisses the popover
                }
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
                // Scoped to the studio's nav bar: the notes panel behind it
                // has its own Done now.
                let done = app.navigationBars.buttons["Done"].firstMatch
                if done.waitForExistence(timeout: 2) { done.tap() }
            }
            // Close the notes panel via its own Done, then verify the reader
            // is interactive again — run #56 showed a lingering sheet turns
            // every later capture into the same stuck-sheet image. Fall back
            // to toggling the toolbar button.
            let closeNotes = app.buttons["notes.done"].firstMatch
            if closeNotes.waitForExistence(timeout: 2), closeNotes.isHittable {
                closeNotes.tap()
            }
            let tocProbe = button(app, id: "reader.toc", label: "Table of contents")
            if !tocProbe.waitForExistence(timeout: 2) || !tocProbe.isHittable {
                notesButton.tap() // toggle the inspector closed
                _ = tocProbe.waitForExistence(timeout: 2)
            }
        }

        // f. Table of contents: open, capture, jump to Chapter Two.
        let toc = button(app, id: "reader.toc", label: "Table of contents")
        if toc.waitForExistence(timeout: 3), toc.isHittable {
            toc.tap()
            let chapterTwo = app.buttons["Chapter Two"].firstMatch
            if chapterTwo.waitForExistence(timeout: 3) {
                snap(app, "08-toc")
                chapterTwo.tap() // jumps and closes
                _ = app.staticTexts["Chapter Two"].waitForExistence(timeout: 3)
            } else {
                snap(app, "08-toc")
            }
        }

        // g. In-book search: query, results list, jump to the first hit.
        let search = button(app, id: "reader.search", label: "Find in book")
        if search.waitForExistence(timeout: 3), search.isHittable {
            search.tap()
            let field = app.textFields["reader.search.field"].firstMatch
            if field.waitForExistence(timeout: 3) {
                field.tap()
                // CI simulators sometimes keep a hardware keyboard attached;
                // only type when the software keyboard actually appeared so a
                // focus hiccup skips the query instead of failing the walk.
                if app.keyboards.count > 0 {
                    field.typeText("Winston")
                    _ = app.buttons.containing(
                        NSPredicate(format: "label CONTAINS %@", "Winston")
                    ).firstMatch.waitForExistence(timeout: 4)
                }
                snap(app, "09-search")
                let hit = app.buttons.containing(
                    NSPredicate(format: "label CONTAINS %@", "Winston")
                ).firstMatch
                if hit.exists && hit.isHittable {
                    hit.tap() // jumps and closes
                } else {
                    app.swipeDown() // dismiss the sheet without a hit
                }
            }
        }

        // h. Ask the book (provider guidance without a configured LLM).
        let ask = button(app, id: "reader.ask", label: "Ask the book")
        if ask.waitForExistence(timeout: 3), ask.isHittable {
            ask.tap()
            _ = app.navigationBars["Ask the book"].waitForExistence(timeout: 3)
            snap(app, "10-ask")
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 2) { done.tap() }
        }

        // i. Dark theme + single-page layout (then restore Paper + Scroll so
        // the persisted appearance doesn't leak into other tests).
        if appearance.waitForExistence(timeout: 3), appearance.isHittable {
            appearance.tap()
            let dark = app.buttons["Dark"].firstMatch
            if dark.waitForExistence(timeout: 2), dark.isHittable { dark.tap() }
            let singlePage = app.buttons["Single page"].firstMatch
            if singlePage.waitForExistence(timeout: 2), singlePage.isHittable {
                singlePage.tap() // dismisses the popover
            }
            _ = app.staticTexts["Chapter Two"].waitForExistence(timeout: 2)
            snap(app, "11-reader-dark-page")

            if appearance.waitForExistence(timeout: 3), appearance.isHittable {
                appearance.tap()
                let paper = app.buttons["Paper"].firstMatch
                if paper.waitForExistence(timeout: 2), paper.isHittable { paper.tap() }
                let scroll = app.buttons["Scroll"].firstMatch
                if scroll.waitForExistence(timeout: 2), scroll.isHittable {
                    scroll.tap() // dismisses the popover
                }
            }
        }

        // j. Settings, sidebar, and library grid from a fresh launch —
        // chaining back-pops through the end-of-walk screen proved flaky
        // (these shots never appeared in published galleries). A relaunch
        // lands on Home deterministically.
        app.terminate()
        let app2 = launchSeeded(stubLLM: true)
        _ = app2.staticTexts["Sample Book"].firstMatch.waitForExistence(timeout: 10)

        // The AI-providers gear lives on Home's toolbar — capture before
        // navigating away (the sidebar root doesn't carry it).
        let settingsButton = button(app2, id: "library.settings", label: "AI providers")
        if settingsButton.waitForExistence(timeout: 5), settingsButton.isHittable {
            settingsButton.tap()
            _ = app2.navigationBars["AI Providers"].waitForExistence(timeout: 3)
            snap(app2, "12-settings")
            let done = app2.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
        }

        // Home's back button is labeled "Readr" (the sidebar root's title).
        let toSidebar = app2.buttons["Readr"].firstMatch
        if toSidebar.waitForExistence(timeout: 3) {
            toSidebar.tap()
            _ = app2.staticTexts["All Books"].firstMatch.waitForExistence(timeout: 3)
            snap(app2, "13-sidebar")
        }

        // iOS sidebar rows are List(selection:) Labels — they surface to
        // XCUITest as cells, NOT buttons (why the old buttons-based lookup
        // never matched). Fall back to the visible label text.
        let allBooksCell = app2.cells["sidebar.allBooks"].firstMatch
        let allBooks = allBooksCell.exists
            ? allBooksCell
            : app2.staticTexts["All Books"].firstMatch
        if allBooks.waitForExistence(timeout: 3), allBooks.isHittable {
            allBooks.tap()
            _ = app2.staticTexts["Sample Book"].firstMatch.waitForExistence(timeout: 3)
            snap(app2, "14-library-grid")
        }

        // l. Native PDF reader: the seeded "Field Notes" PDF opens in
        // PDFKit's original-pages mode (PDF journeys were the one class the
        // text fixtures couldn't reach).
        let pdfBook = app2.staticTexts["Field Notes"].firstMatch
        if pdfBook.waitForExistence(timeout: 3), pdfBook.isHittable {
            pdfBook.tap()
            // PDFKit renders asynchronously; give the first page a beat.
            _ = app2.navigationBars.firstMatch.waitForExistence(timeout: 5)
            sleep(2)
            snap(app2, "15-pdf-reader")
            // The back button carries the previous screen's title; prefer it
            // over firstMatch, which can land on the disabled chapter chevron.
            let labeled = app2.navigationBars.buttons["All Books"].firstMatch
            let back = labeled.exists ? labeled : app2.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 3) { back.tap() }
        }

        // m. Ask with the stubbed provider: open Sample Book, ask a suggested
        // question, and capture the streamed answer UI.
        let sample = app2.staticTexts["Sample Book"].firstMatch
        if sample.waitForExistence(timeout: 3), sample.isHittable {
            sample.tap()
            let ask2 = button(app2, id: "reader.ask", label: "Ask the book")
            if ask2.waitForExistence(timeout: 5), ask2.isHittable {
                ask2.tap()
                // Suggestion chips insert text without needing the keyboard.
                let suggestion = app2.buttons["Summarize this book"].firstMatch
                if suggestion.waitForExistence(timeout: 3) { suggestion.tap() }
                let send = app2.buttons["ask.send"].firstMatch
                if send.waitForExistence(timeout: 2), send.isEnabled {
                    send.tap()
                    // The stub streams word-by-word; wait for its tail phrase.
                    _ = app2.staticTexts.containing(
                        NSPredicate(format: "label CONTAINS %@", "tone of decay")
                    ).firstMatch.waitForExistence(timeout: 15)
                }
                snap(app2, "16-ask-answer")
                let done = app2.navigationBars.buttons["Done"].firstMatch
                if done.waitForExistence(timeout: 2) { done.tap() }
            }

            // n. Article studio composing with the stubbed provider — the
            // last CI-reachable journey (J6): highlights → Compose → the
            // streamed draft in the Markdown editor.
            let notes2 = button(app2, id: "reader.notes", label: "Highlights")
            if notes2.waitForExistence(timeout: 3), notes2.isHittable {
                notes2.tap()
                let create = app2.buttons["notes.createArticle"].firstMatch
                if create.waitForExistence(timeout: 3), create.isHittable {
                    create.tap()
                    let compose = app2.buttons["article.compose"].firstMatch
                    if compose.waitForExistence(timeout: 3), compose.isHittable {
                        compose.tap()
                        // The draft streams into the editor; wait for the
                        // editor to appear, then let the stream finish.
                        _ = app2.textViews.firstMatch.waitForExistence(timeout: 10)
                        sleep(4)
                    }
                    snap(app2, "17-article-compose")
                    let done = app2.navigationBars.buttons["Done"].firstMatch
                    if done.waitForExistence(timeout: 2) { done.tap() }
                }
            }
        }
    }
}
