import XCTest
@testable import ReadrKit

/// Every narration control, against a mock engine.
///
/// These are the tests that matter for "listen to the book": each control
/// interrupts an utterance in flight, and the interesting failures are all
/// races and off-by-one-sentence mistakes — a skip undone by the cancelled
/// utterance's completion, a speed change that restarts the sentence, a sleep
/// timer that keeps counting while the reader is paused. None of that is
/// observable on a device without listening for minutes at a time; all of it
/// is deterministic here.
final class NarrationControllerTests: XCTestCase {

    /// A clock the test advances by hand.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
    }

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    /// Chapter 0: three sentences. Chapter 1: a `linear="no"` notes document
    /// continuous playback must skip. Chapter 2: two more sentences.
    private func makeBook() -> Book {
        Book(
            metadata: BookMetadata(title: "Test", language: "en-GB"),
            chapters: [
                Chapter(title: "One", order: 0, text: "Alpha one. Alpha two. Alpha three."),
                Chapter(
                    title: "Notes", order: 1, text: "A note nobody reads aloud.",
                    isLinear: false
                ),
                Chapter(title: "Two", order: 2, text: "Beta one. Beta two."),
            ],
            estimatedTokenCount: 100
        )
    }

    private func makeController(
        book: Book? = nil,
        settings: SpeechSettings = SpeechSettings(),
        clock: Clock? = nil
    ) -> (controller: NarrationController, engine: MockSpeechEngine) {
        let engine = MockSpeechEngine()
        let clock = clock ?? Clock(epoch)
        let controller = NarrationController(
            book: book ?? makeBook(),
            engine: engine,
            settings: settings,
            now: { clock.now }
        )
        return (controller, engine)
    }

    // MARK: - Starting from a page

    func testStartReadsFromTheSentenceBeginningAtTheGivenOffset() {
        let (controller, engine) = makeController()
        // 11 is exactly where "Alpha two." begins, so that is the sentence —
        // not the one after it.
        controller.start(atChapter: 0, characterOffset: 11)

        XCTAssertEqual(controller.status, .speaking)
        XCTAssertEqual(engine.spokenTexts, ["Alpha two."])
        XCTAssertEqual(controller.currentSegment?.text, "Alpha two.")
    }

    func testStartBeginsAtTheFirstWholeSentenceAfterTheAnchor() {
        let (controller, engine) = makeController()
        // Offset 15 sits inside "Alpha two." (11..<21). The anchor a reader
        // presses Listen on is the top of a page, and a sentence straddling
        // that boundary began on the page before — so narration takes the next
        // whole one rather than dragging the page backwards to finish it.
        controller.start(atChapter: 0, characterOffset: 15)
        XCTAssertEqual(engine.spokenTexts, ["Alpha three."])
    }

    func testStartInANonLinearChapterReadsItAnyway() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 1)
        XCTAssertEqual(engine.spokenTexts, ["A note nobody reads aloud."])
    }

    func testStartWithNothingLeftToReadFinishesImmediately() {
        let book = Book(
            metadata: BookMetadata(title: "Silent"),
            chapters: [Chapter(title: "Plate", order: 0, text: "\u{FFFC}")],
            estimatedTokenCount: 1
        )
        let (controller, engine) = makeController(book: book)
        controller.start(atChapter: 0)

        XCTAssertEqual(controller.status, .finished)
        XCTAssertNil(controller.currentSegment)
        XCTAssertTrue(engine.spoken.isEmpty)
    }

    func testStartCarriesTheVoiceSettingsAndTheBooksLanguage() {
        let settings = SpeechSettings(
            rate: 1.5, pitch: 0.8, volume: 0.6, voiceID: "com.apple.voice.test"
        )
        let (controller, engine) = makeController(settings: settings)
        controller.start(atChapter: 0)

        let request = engine.spoken.first
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.rate, 1.5)
        XCTAssertEqual(request?.pitch, 0.8)
        XCTAssertEqual(request?.volume, 0.6)
        XCTAssertEqual(request?.voiceID, "com.apple.voice.test")
        XCTAssertEqual(request?.language, "en-GB")
    }

    // MARK: - Play / pause / stop

    func testPauseHoldsTheUtteranceAndPlayResumesItRatherThanRestarting() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)

        controller.pause()
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(engine.pauseCount, 1)

        controller.play()
        XCTAssertEqual(controller.status, .speaking)
        XCTAssertEqual(engine.resumeCount, 1)
        XCTAssertEqual(engine.spoken.count, 1, "Resuming must not re-speak the sentence")
    }

    func testPauseAndPlayAreIdempotent() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)

        controller.play()
        XCTAssertEqual(engine.resumeCount, 0, "Play while speaking does nothing")

        controller.pause()
        controller.pause()
        XCTAssertEqual(engine.pauseCount, 1, "Pause while paused does nothing")
    }

    func testTogglePlayPauseFlipsBothWays() {
        let (controller, _) = makeController()
        controller.start(atChapter: 0)

        controller.togglePlayPause()
        XCTAssertEqual(controller.status, .paused)
        controller.togglePlayPause()
        XCTAssertEqual(controller.status, .speaking)
    }

    func testStopEndsNarrationAndForgetsThePlace() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        let stopsBefore = engine.stopCount

        controller.stop()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertNil(controller.currentSegment)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(engine.stopCount, stopsBefore + 1)
    }

    func testPauseBeforeAnythingStartedDoesNothing() {
        let (controller, engine) = makeController()
        controller.pause()
        controller.play()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertTrue(engine.spoken.isEmpty)
    }

    // MARK: - Reading on

    func testFinishingASentenceReadsTheNextOne() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)

        engine.finishCurrent()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        engine.finishCurrent()
        XCTAssertEqual(controller.currentSegment?.text, "Alpha three.")
        XCTAssertEqual(controller.status, .speaking)
    }

    func testReadingCrossesIntoTheNextChapterAndSkipsNonLinearOnes() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0, characterOffset: 22)
        XCTAssertEqual(engine.spokenTexts, ["Alpha three."])

        engine.finishCurrent()
        XCTAssertEqual(
            controller.currentSegment?.text, "Beta one.",
            "The notes document is not read aloud in continuous playback"
        )
        XCTAssertEqual(controller.currentSegment?.chapterIndex, 2)
    }

    func testReadingStopsAtTheEndOfTheBook() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 2, characterOffset: 10)
        XCTAssertEqual(engine.spokenTexts, ["Beta two."])

        engine.finishCurrent()
        XCTAssertEqual(controller.status, .finished)
        XCTAssertEqual(engine.spoken.count, 1, "Nothing more is spoken on its own")

        // Play at the end replays the last sentence rather than doing nothing:
        // the bar shows a play button there, and a button that does nothing
        // when pressed reads as broken.
        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Beta two.", "Beta two."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testChapterSkipAtTheLastChapterKeepsReadingInsteadOfEnding() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 2)
        engine.speakWord(0..<4) // "Beta"

        controller.skipToNextChapter()
        XCTAssertEqual(
            controller.status, .speaking,
            "There is no next chapter, so the skip is a no-op — not the end of the book"
        )
        XCTAssertEqual(controller.currentSegment?.text, "Beta one.")
        XCTAssertEqual(
            engine.spokenTexts.last, "Beta one.",
            "The voice picks the sentence back up where it was"
        )
    }

    func testChapterEndHoldsWhenAutoAdvanceIsOff() {
        let (controller, engine) = makeController(
            settings: SpeechSettings(autoAdvancesChapters: false)
        )
        controller.start(atChapter: 0, characterOffset: 22)
        engine.finishCurrent()

        XCTAssertEqual(controller.status, .paused, "Narration waits at the chapter wall")
        XCTAssertEqual(engine.spoken.count, 1)
        XCTAssertEqual(controller.currentSegment?.text, "Beta one.")

        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha three.", "Beta one."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testAFinishFromACancelledUtteranceIsIgnored() {
        // The race every interrupting control has to survive: the engine
        // reports the utterance a skip cancelled, which must not be mistaken
        // for the new sentence ending and skip a second one.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        let cancelled = engine.spoken[0].id

        controller.skipToNextSentence()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])

        engine.finishStaleRequest(cancelled)
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.currentSegment?.text, "Alpha two.")
    }

    // MARK: - Skipping

    func testSkipForwardWhileSpeakingCancelsAndReadsTheNextSentence() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        let stopsBefore = engine.stopCount

        controller.skipToNextSentence()
        XCTAssertEqual(engine.stopCount, stopsBefore + 1)
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testSkipBackWhileSpeakingReadsThePreviousSentence() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0, characterOffset: 11)

        controller.skipToPreviousSentence()
        XCTAssertEqual(engine.spokenTexts, ["Alpha two.", "Alpha one."])
    }

    func testSkipBackAtTheStartOfTheBookRestartsTheSentence() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)

        controller.skipToPreviousSentence()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha one."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testSkipWhilePausedMovesWithoutStartingAudio() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        controller.pause()

        controller.skipToNextSentence()
        XCTAssertEqual(controller.status, .paused, "Skipping must not start playback")
        XCTAssertEqual(engine.spoken.count, 1)
        XCTAssertEqual(controller.currentSegment?.text, "Alpha two.")

        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testSkipWhileIdleDoesNothing() {
        let (controller, engine) = makeController()
        controller.skipToNextSentence()
        controller.skipToPreviousSentence()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertTrue(engine.spoken.isEmpty)
    }

    func testChapterSkipsJumpWholeChapters() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)

        controller.skipToNextChapter()
        XCTAssertEqual(controller.currentSegment?.text, "Beta one.")
        XCTAssertEqual(controller.currentSegment?.chapterIndex, 2)

        // Mid-chapter, the previous-chapter control restarts this chapter…
        controller.skipToNextSentence()
        XCTAssertEqual(controller.currentSegment?.text, "Beta two.")
        controller.skipToPreviousChapter()
        XCTAssertEqual(controller.currentSegment?.text, "Beta one.")
        // …and from its head it steps back a chapter.
        controller.skipToPreviousChapter()
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")
        XCTAssertEqual(engine.spokenTexts.last, "Alpha one.")
    }

    func testSkippingForwardPastTheEndFinishes() {
        let (controller, _) = makeController()
        controller.start(atChapter: 2, characterOffset: 10)
        controller.skipToNextSentence()
        XCTAssertEqual(controller.status, .finished)
    }

    func testSkippingBackFromTheEndPutsNarrationInHandAgain() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 2, characterOffset: 10)
        engine.finishCurrent()
        XCTAssertEqual(controller.status, .finished)

        controller.skipToPreviousSentence()
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(controller.currentSegment?.text, "Beta one.")

        controller.play()
        XCTAssertEqual(engine.spokenTexts.last, "Beta one.")
        XCTAssertEqual(controller.status, .speaking)
    }

    // MARK: - Speed and voice, changed while reading

    func testChangingSpeedMidSentenceContinuesFromTheWordReached() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        // "Alpha one." — the engine reports it is speaking "one".
        engine.speakWord(6..<9)

        controller.settings.rate = 1.5
        XCTAssertEqual(
            engine.spokenTexts, ["Alpha one.", "one."],
            "The remainder is re-spoken, not the whole sentence"
        )
        XCTAssertEqual(engine.spoken.last?.rate, 1.5)
        XCTAssertEqual(controller.status, .speaking)
    }

    func testChangingSpeedBeforeAnyWordBoundaryRepeatsTheSentence() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        controller.settings.rate = 0.75
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha one."])
        XCTAssertEqual(engine.spoken.last?.rate, 0.75)
    }

    func testChangingVoiceMidSentenceKeepsThePlace() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.speakWord(6..<9)

        controller.settings.voiceID = "com.apple.voice.other"
        XCTAssertEqual(engine.spoken.last?.text, "one.")
        XCTAssertEqual(engine.spoken.last?.voiceID, "com.apple.voice.other")
    }

    func testChangingSpeedWhilePausedDoesNotStartAudio() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.speakWord(6..<9)
        controller.pause()

        controller.settings.rate = 1.75
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(engine.spoken.count, 1, "A paused reader must not be spoken to")

        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "one."])
        XCTAssertEqual(engine.spoken.last?.rate, 1.75)
        XCTAssertEqual(engine.resumeCount, 0, "The old utterance is gone; it is re-spoken")
    }

    func testSettingTheSameValuesChangesNothing() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        // Via a local: assigning a property to itself is a compile error, and
        // what matters is that an equal value doesn't interrupt the sentence.
        let unchanged = controller.settings
        controller.settings = unchanged
        XCTAssertEqual(engine.spoken.count, 1)
    }

    func testSpeedIsClampedBeforeItReachesTheEngine() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        controller.settings.rate = 99
        XCTAssertEqual(engine.spoken.last?.rate, SpeechSettings.rateRange.upperBound)
    }

    // MARK: - Sleep timer

    func testTimedSleepStopsNarrationButKeepsThePlace() {
        let clock = Clock(epoch)
        let (controller, engine) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 15))

        clock.advance(minutes: 14)
        controller.tick()
        XCTAssertEqual(controller.status, .speaking, "Not yet")

        clock.advance(minutes: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")
        XCTAssertEqual(controller.sleepTimer.mode, .off, "The timer clears once it fires")

        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha one."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testPausingDoesNotBurnTheSleepTimer() {
        let clock = Clock(epoch)
        let (controller, _) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 10))

        clock.advance(minutes: 5)
        controller.pause()
        clock.advance(minutes: 60)
        controller.play()

        clock.advance(minutes: 4)
        controller.tick()
        XCTAssertEqual(controller.status, .speaking, "Five minutes of listening are still owed")

        clock.advance(minutes: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
    }

    func testTheSleepTimerOnlyRunsWhileNarrationDoes() {
        let clock = Clock(epoch)
        let (controller, _) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.pause()
        // Armed while paused: the countdown waits for playback.
        controller.setSleepTimer(.after(minutes: 5))
        clock.advance(minutes: 60)
        controller.tick()
        XCTAssertEqual(controller.status, .paused)

        controller.play()
        clock.advance(minutes: 4)
        controller.tick()
        XCTAssertEqual(controller.status, .speaking)
        clock.advance(minutes: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
    }

    func testEndOfChapterSleepStopsAtTheChapterWall() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0, characterOffset: 11)
        controller.setSleepTimer(.endOfChapter)

        engine.finishCurrent()
        XCTAssertEqual(controller.status, .speaking, "Still inside the chapter")
        XCTAssertEqual(controller.currentSegment?.text, "Alpha three.")

        engine.finishCurrent()
        XCTAssertEqual(controller.status, .paused, "Stops rather than crossing into chapter two")
        XCTAssertEqual(engine.spokenTexts, ["Alpha two.", "Alpha three."])
        XCTAssertEqual(controller.currentSegment?.text, "Beta one.")
    }

    func testAChapterHoldDoesNotBurnTheSleepTimer() {
        // Auto-advance off parks narration at the chapter wall. That is a
        // pause like any other: the countdown has to stop with it, or the
        // first tick after the reader presses play cuts them off.
        let clock = Clock(epoch)
        let (controller, engine) = makeController(
            settings: SpeechSettings(autoAdvancesChapters: false), clock: clock
        )
        controller.start(atChapter: 0, characterOffset: 22)
        controller.setSleepTimer(.after(minutes: 15))

        engine.finishCurrent()
        XCTAssertEqual(controller.status, .paused, "Held at the chapter wall")

        clock.advance(minutes: 60)
        controller.play()
        controller.tick()
        XCTAssertEqual(
            controller.status, .speaking,
            "An hour parked at the wall must not have spent the 15 minutes"
        )

        clock.advance(minutes: 15)
        controller.tick()
        XCTAssertEqual(controller.status, .paused, "The full 15 minutes of listening")
    }

    func testAFailedUtteranceDoesNotBurnTheSleepTimerEither() {
        let clock = Clock(epoch)
        let (controller, engine) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 15))

        engine.fail()
        XCTAssertEqual(controller.status, .paused)

        clock.advance(minutes: 60)
        controller.play()
        controller.tick()
        XCTAssertEqual(controller.status, .speaking)
    }

    func testStartingAgainRestartsTheCountdown() {
        let clock = Clock(epoch)
        let (controller, _) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 15))

        clock.advance(minutes: 14)
        controller.start(atChapter: 0)

        clock.advance(minutes: 14)
        controller.tick()
        XCTAssertEqual(controller.status, .speaking, "The countdown restarted with the session")

        clock.advance(minutes: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
    }

    func testTurningTheSleepTimerOffCancelsIt() {
        let clock = Clock(epoch)
        let (controller, _) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 5))
        controller.setSleepTimer(.off)

        clock.advance(minutes: 60)
        controller.tick()
        XCTAssertEqual(controller.status, .speaking)
        XCTAssertNil(controller.sleepTimerRemaining())
    }

    func testSleepTimerRemainingCountsDownForTheReadout() {
        let clock = Clock(epoch)
        let (controller, _) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 10))
        XCTAssertEqual(controller.sleepTimerRemaining() ?? 0, 600, accuracy: 1)

        clock.advance(minutes: 3)
        XCTAssertEqual(controller.sleepTimerRemaining() ?? 0, 420, accuracy: 1)
    }

    // MARK: - Following along

    func testPositionReportsWhereTheReaderShouldBe() {
        let (controller, engine) = makeController()
        var positions: [NarrationPosition] = []
        controller.onPositionChange = { positions.append($0) }

        controller.start(atChapter: 0)
        XCTAssertEqual(positions.last, NarrationPosition(chapterIndex: 0, characterOffset: 0))

        engine.finishCurrent()
        XCTAssertEqual(
            positions.last, NarrationPosition(chapterIndex: 0, characterOffset: 11),
            "The page follows the voice into the next sentence"
        )

        controller.skipToNextChapter()
        XCTAssertEqual(positions.last, NarrationPosition(chapterIndex: 2, characterOffset: 0))
    }

    func testAMidSentencePositionStillCarriesTheSentenceItBelongsTo() {
        // The page follows the voice to the word, but the reader's saved place
        // has to be the sentence: `seek` takes the first sentence beginning at
        // or after its anchor, so persisting a mid-sentence offset and then
        // pressing Listen again would skip the rest of that sentence unheard.
        let (controller, engine) = makeController()
        var positions: [NarrationPosition] = []
        controller.onPositionChange = { positions.append($0) }

        controller.start(atChapter: 0, characterOffset: 11)
        engine.speakWord(6..<9)
        // A speed change re-speaks the remainder from the last word boundary.
        controller.settings.rate = 1.5

        let resumed = positions.last
        XCTAssertEqual(resumed?.characterOffset, 17, "The voice is at 'two'")
        XCTAssertEqual(
            resumed?.sentenceStart, 11,
            "But the place to come back to is the head of the sentence"
        )
        XCTAssertEqual(controller.position?.sentenceStart, 11)
    }

    func testSpokenWordsAreReportedInChapterCoordinates() {
        let (controller, engine) = makeController()
        var spoken: [(chapter: Int, range: Range<Int>)] = []
        controller.onSpokenRangeChange = { spoken.append((chapter: $0, range: $1)) }

        controller.start(atChapter: 0, characterOffset: 11)
        // "Alpha two." starts at chapter offset 11; "two" is local 6..<9.
        engine.speakWord(6..<9)

        XCTAssertEqual(spoken.count, 1)
        XCTAssertEqual(spoken.first?.chapter, 0)
        XCTAssertEqual(spoken.first?.range, 17..<20)
    }

    func testSpokenWordsOfAResumedRemainderStayInChapterCoordinates() {
        let (controller, engine) = makeController()
        var spoken: [Range<Int>] = []
        controller.onSpokenRangeChange = { _, range in spoken.append(range) }

        controller.start(atChapter: 0)
        engine.speakWord(6..<9)          // "one" in "Alpha one."
        controller.settings.rate = 1.5   // re-speaks "one." from offset 6
        engine.speakWord(0..<3)          // "one" again, local to the remainder

        XCTAssertEqual(spoken, [6..<9, 6..<9], "Offsets are rebased onto the sentence")
    }

    func testStatusChangesAreReported() {
        let (controller, _) = makeController()
        var statuses: [NarrationStatus] = []
        controller.onStatusChange = { statuses.append($0) }

        controller.start(atChapter: 0)
        controller.pause()
        controller.play()
        controller.stop()

        XCTAssertEqual(statuses, [.speaking, .paused, .speaking, .idle])
    }

    func testChapterProgressAdvancesWithNarration() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        XCTAssertEqual(controller.chapterProgress, 1.0 / 3.0, accuracy: 0.001)
        engine.finishCurrent()
        XCTAssertEqual(controller.chapterProgress, 2.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - A dropped completion callback

    func testNarrationRecoversWhenTheEngineGoesQuietWithoutReporting() {
        // The engine can drop `didFinish`. Every move the controller makes is
        // driven by that callback, so without a backstop narration sits on the
        // sentence forever showing Pause — which is what a reader saw at the
        // end of a book on macOS.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.fallSilentWithoutReporting()

        controller.tick()
        XCTAssertEqual(
            controller.status, .speaking,
            "One quiet tick is not enough — an engine can read idle for an instant"
        )

        controller.tick()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.status, .speaking, "It moves on to the next sentence")
    }

    func testTheBackstopEndsTheBookRatherThanHangingOnTheLastSentence() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 2, characterOffset: 10)
        engine.fallSilentWithoutReporting()

        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.status, .finished)
    }

    func testTheBackstopIgnoresAPausedEngine() {
        // Pausing makes the engine stop speaking on purpose; treating that as a
        // finished utterance would advance the book under the reader.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        controller.pause()

        controller.tick()
        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(engine.spoken.count, 1, "Nothing new was spoken")
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")
    }

    func testAFinishLandingAfterAPauseHoldsInsteadOfAdvancing() {
        // The reader taps pause in the same instant a sentence's audio ends:
        // the engine had nothing left to pause, and the completion — queued
        // asynchronously — lands after the pause. Advancing would start the
        // next sentence's audio against the reader's explicit pause.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        controller.pause()
        engine.finishCurrent()

        XCTAssertEqual(controller.status, .paused, "The pause wins")
        XCTAssertEqual(engine.spokenTexts, ["Alpha one."], "Nothing new was spoken")

        // Play moves on: the finished sentence has nothing left to say.
        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testTheBackstopHoldsWhenTheEnginePausedItself() {
        // An audio interruption (a phone call, Siri, another app taking the
        // session) pauses the synthesizer without the controller asking.
        // Treating that as a finished utterance advanced the book by a
        // sentence every two ticks — silently machine-gunning through pages
        // nobody heard for as long as the interruption lasted.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.pauseWithoutBeingAsked()

        controller.tick()
        controller.tick()
        controller.tick()
        XCTAssertEqual(controller.status, .paused, "Held, not advanced")
        XCTAssertEqual(engine.spoken.count, 1, "Nothing new was spoken")
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")

        // The interruption ends: play picks the same utterance back up.
        controller.play()
        XCTAssertEqual(engine.resumeCount, 1)
        XCTAssertEqual(controller.status, .speaking)
    }

    // MARK: - Failure

    func testAnEngineFailurePausesInsteadOfLosingThePlace() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.fail()

        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")

        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha one."])
        XCTAssertEqual(controller.status, .speaking)
    }
}


// MARK: - Preparing (a voice whose model is still downloading)

extension NarrationControllerTests {

    func testAnEnginePreparingItsVoiceIsShownAsPreparingUntilAudioStarts() {
        let (controller, engine) = makeController()
        var statuses: [NarrationStatus] = []
        controller.onStatusChange = { statuses.append($0) }

        controller.start(atChapter: 0)
        engine.reportPreparing()
        XCTAssertEqual(controller.status, .preparing)
        XCTAssertTrue(controller.isActive, "The Listen bar stays up through the wait")
        XCTAssertFalse(controller.isSpeaking)
        XCTAssertTrue(controller.isPreparing)
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.", "The place is kept")

        engine.reportBeganSpeaking()
        XCTAssertEqual(controller.status, .speaking)
        XCTAssertEqual(statuses, [.speaking, .preparing, .speaking])
        XCTAssertEqual(engine.spoken.count, 1, "Nothing was re-spoken")
    }

    func testBeganSpeakingWithoutAPreparingReportChangesNothing() {
        let (controller, engine) = makeController()
        var statuses: [NarrationStatus] = []
        controller.onStatusChange = { statuses.append($0) }
        controller.start(atChapter: 0)
        engine.reportBeganSpeaking()
        XCTAssertEqual(statuses, [.speaking])
    }

    func testAStalePreparingReportIsIgnored() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        let cancelled = engine.spoken[0].id
        controller.skipToNextSentence()

        engine.reportPreparing(stale: cancelled)
        XCTAssertEqual(controller.status, .speaking)
    }

    func testAPreparingReportWhilePausedDoesNotUnpause() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        controller.pause()
        engine.reportPreparing()
        XCTAssertEqual(controller.status, .paused)
    }

    func testAWordBoundaryAlsoEndsPreparing() {
        // An engine that reported preparing and then simply starts reporting
        // words is speaking, whatever else it forgot to say.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()
        engine.speakWord(0..<5)
        XCTAssertEqual(controller.status, .speaking)
    }

    func testPausingWhilePreparingHoldsAndPlayResumesTheSameUtterance() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()

        controller.pause()
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(engine.pauseCount, 1)

        controller.play()
        XCTAssertEqual(controller.status, .speaking)
        XCTAssertEqual(engine.resumeCount, 1)
        XCTAssertEqual(engine.spoken.count, 1, "The engine still holds the utterance")

        // The engine is still waiting for its model, and says so again.
        engine.reportPreparing()
        XCTAssertEqual(controller.status, .preparing)
    }

    func testTogglePlayPauseTreatsPreparingAsPlaying() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()

        controller.togglePlayPause()
        XCTAssertEqual(controller.status, .paused, "The bar's pause control pauses a wait")
        controller.togglePlayPause()
        XCTAssertEqual(controller.status, .speaking)
    }

    func testPlayWhilePreparingDoesNothing() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()
        controller.play()
        XCTAssertEqual(controller.status, .preparing)
        XCTAssertEqual(engine.resumeCount, 0)
        XCTAssertEqual(engine.spoken.count, 1)
    }

    func testSkippingWhilePreparingMovesOnAndSpeaks() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()

        controller.skipToNextSentence()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.status, .speaking, "Until the engine says otherwise")
        engine.reportPreparing()
        XCTAssertEqual(controller.status, .preparing)
    }

    func testASettingsChangeWhilePreparingReSpeaksWithTheNewSettings() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()

        controller.settings.voiceID = "com.apple.voice.other"
        XCTAssertEqual(engine.spoken.count, 2)
        XCTAssertEqual(engine.spoken.last?.voiceID, "com.apple.voice.other")
        XCTAssertEqual(controller.status, .speaking)
    }

    func testAFailureWhilePreparingPausesWithThePlaceKept() {
        // The download failed: narration holds on the sentence and the bar
        // offers a retry — it must not read on, and nothing else speaks.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()
        engine.fail()

        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")
        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha one."])
    }

    func testAFinishWhilePreparingReadsOn() {
        // A punctuation-only "sentence" yields no audio: the engine finishes
        // it without ever starting to speak.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()
        engine.finishCurrent()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha two."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testTheSleepTimerWaitsWhileTheVoicePrepares() {
        let clock = Clock(epoch)
        let (controller, engine) = makeController(clock: clock)
        controller.start(atChapter: 0)
        controller.setSleepTimer(.after(minutes: 10))
        engine.reportPreparing()

        clock.advance(minutes: 60)
        controller.tick()
        XCTAssertEqual(controller.status, .preparing, "A wait for the model is not listening")

        engine.reportBeganSpeaking()
        clock.advance(minutes: 9)
        controller.tick()
        XCTAssertEqual(controller.status, .speaking, "The ten minutes are still owed")
        clock.advance(minutes: 1)
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
    }

    func testTheBackstopHoldsAPreparingUtteranceTheEngineDropped() {
        // The engine went idle without a finish, a failure, or audio: the
        // sentence was never heard, so advancing past it would lose it. Hold
        // instead; play re-speaks it.
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()
        engine.fallSilentWithoutReporting()

        controller.tick()
        XCTAssertEqual(controller.status, .preparing, "One quiet tick is not enough")
        controller.tick()
        XCTAssertEqual(controller.status, .paused)
        XCTAssertEqual(controller.currentSegment?.text, "Alpha one.")

        controller.play()
        XCTAssertEqual(engine.spokenTexts, ["Alpha one.", "Alpha one."])
        XCTAssertEqual(controller.status, .speaking)
    }

    func testStopWhilePreparingClosesTheSession() {
        let (controller, engine) = makeController()
        controller.start(atChapter: 0)
        engine.reportPreparing()
        controller.stop()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(engine.state, .idle)
    }
}
