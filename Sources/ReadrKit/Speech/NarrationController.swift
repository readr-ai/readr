import Foundation

public enum NarrationStatus: Hashable, Sendable {
    /// Not narrating; the Listen bar is closed.
    case idle
    /// The engine has the sentence but its voice is not ready to say it —
    /// Readr Voice's first-use model download. Narration starts the moment
    /// it is: nothing else reads meanwhile. Counts as active (the bar stays
    /// up) and as playing (the pause control pauses the wait), but not as
    /// listening (the sleep timer waits with it).
    case preparing
    case speaking
    /// Held — by the reader, by the sleep timer, or at a chapter end when
    /// auto-advance is off. `play()` picks up where it stopped.
    case paused
    /// Nothing left to read in the book.
    case finished
}

/// Drives narration: which sentence is spoken, what every playback control
/// does to it, and where the reader's page should be while it plays.
///
/// All of it lives here rather than in the SwiftUI layer, because the rules are
/// where the bugs are: a skip must not be undone by the "finished" callback of
/// the utterance it cancelled; a speed change must continue from the word the
/// voice reached, not restart the sentence; pausing must not burn the sleep
/// timer. Each of those is a unit test against a mock engine (see
/// `NarrationControllerTests`) instead of something only a device can show.
///
/// Main-thread-confined: the engine reports back on the main thread and the
/// callbacks drive the reader's UI directly.
public final class NarrationController {
    /// Voice preferences. Changing them mid-sentence is applied live — the
    /// current sentence is re-spoken from the word the voice had reached, so
    /// the reader hears the new speed or voice without losing their place.
    public var settings: SpeechSettings {
        didSet {
            guard settings != oldValue else { return }
            applySettingsChange()
        }
    }

    public private(set) var status: NarrationStatus = .idle
    public private(set) var currentSegment: SpeechSegment?
    public private(set) var sleepTimer = SleepTimerState()
    /// Why narration is `.paused` when the reader did not pause it — the
    /// engine set the sentence down and needs something from outside. Nil
    /// for a reader's pause, and cleared by anything the reader does.
    public private(set) var holdReason: NarrationHoldReason?

    /// How far ahead of the voice an engine that synthesizes ahead
    /// (`SpeechPrefetching`) is asked to work, in estimated seconds of
    /// audio — or the rest of the book, which the app asks for while the
    /// device is charging.
    public enum LookaheadHorizon: Hashable, Sendable {
        case seconds(TimeInterval)
        case restOfBook
    }

    /// An hour of listening by default. Changing it re-issues the lookahead
    /// at once if narration is underway.
    public var lookaheadHorizon: LookaheadHorizon = .seconds(NarrationController.defaultLookaheadSeconds) {
        didSet {
            guard lookaheadHorizon != oldValue, isUnderway else { return }
            issueLookahead()
        }
    }
    public static let defaultLookaheadSeconds: TimeInterval = 60 * 60
    /// The estimate behind the horizon: prose read aloud at 1× runs at
    /// about fifteen characters a second. Rough on purpose — the horizon is
    /// a budget for synthesis, not a promise to the reader.
    public static let charactersPerSecond: Double = 15

    /// The sentences after the current one that the engine was last handed,
    /// in playback order (empty for an engine that does not synthesize
    /// ahead). The app asks the engine how much of this is already audio.
    public private(set) var lookahead: [SpeechRequest] = []
    /// The book being narrated; stamped on every request so an engine that
    /// keeps audio can key it to the book.
    public let bookID: UUID

    /// Fires on every status transition.
    public var onStatusChange: ((NarrationStatus) -> Void)?
    /// Where the voice is now — the reader follows this to keep the page under
    /// the narration.
    public var onPositionChange: ((NarrationPosition) -> Void)?
    /// The word being spoken, in chapter coordinates, for read-along display.
    public var onSpokenRangeChange: ((Int, Range<Int>) -> Void)?

    private var playlist: SpeechPlaylist
    private let engine: any SpeechEngine
    private let language: String?
    private let now: () -> Date

    /// The utterance the engine is on. Callbacks carrying any other id belong
    /// to an utterance we already cancelled and are ignored.
    private var activeRequestID: UUID?
    /// How far into `currentSegment.text` the voice has spoken, in characters.
    /// The resume point after a speed/voice change or a sleep stop.
    private var spokenOffset = 0
    /// Character offset within `currentSegment.text` where the active request's
    /// text begins — non-zero when the remainder of a sentence is re-spoken.
    private var activeRequestOrigin = 0
    private var currentSegmentLength = 0
    /// Set when the engine no longer holds a resumable utterance, so `play()`
    /// re-speaks instead of asking it to continue.
    private var mustRespeakToResume = false
    /// Consecutive ticks where we believed narration was speaking and the
    /// engine disagreed — see `tick()`.
    private var silentTicks = 0

    public init(
        book: Book,
        engine: any SpeechEngine,
        settings: SpeechSettings = SpeechSettings(),
        segmenter: SpeechSegmenter = SpeechSegmenter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.playlist = SpeechPlaylist(book: book, segmenter: segmenter)
        self.engine = engine
        self.settings = settings
        self.language = book.metadata.language
        self.bookID = book.id
        self.now = now
        engine.delegate = self
    }

    // MARK: - Reading

    public var isSpeaking: Bool { status == .speaking }
    public var isPreparing: Bool { status == .preparing }
    /// Speaking, or about to as soon as the voice is ready — the states the
    /// play/pause control shows as Pause.
    public var isUnderway: Bool { status == .speaking || status == .preparing }
    /// True whenever the Listen bar should be on screen.
    public var isActive: Bool { status != .idle }
    /// Progress through the chapter being narrated, 0...1.
    public var chapterProgress: Double { playlist.chapterProgress }
    public var position: NarrationPosition? {
        currentSegment.map {
            NarrationPosition(
                chapterIndex: $0.chapterIndex,
                characterOffset: $0.range.lowerBound + min(spokenOffset, currentSegmentLength),
                sentenceStart: $0.range.lowerBound
            )
        }
    }

    // MARK: - Controls

    /// Start reading at a position — the Listen button's entry point, where
    /// the position is the top of the visible page (or a chapter picked from
    /// Contents), or "Listen from here" on a selection. Narration always
    /// begins at a sentence start, never mid-sentence: `anchor` decides
    /// whether that is the sentence containing the offset (a selection) or the
    /// first one beginning after it (a page top) — see `SpeechPlaylist.SeekAnchor`.
    public func start(
        atChapter chapterIndex: Int,
        characterOffset: Int = 0,
        anchor: SpeechPlaylist.SeekAnchor = .nextSentenceStart
    ) {
        engine.stop()
        activeRequestID = nil
        guard let segment = playlist.seek(
            toChapter: chapterIndex, characterOffset: characterOffset, anchor: anchor
        ) else {
            currentSegment = nil
            setStatus(.finished)
            return
        }
        // A fresh listening session restarts the countdown.
        if sleepTimer.mode.isOn {
            sleepTimer.arm(sleepTimer.mode, at: now())
        }
        speak(segment, from: 0)
    }

    public func play() {
        switch status {
        case .speaking, .preparing:
            return
        case .paused:
            sleepTimer.resume(at: now())
            if mustRespeakToResume, let segment = currentSegment {
                speak(segment, from: spokenOffset)
            } else {
                engine.resume()
                setStatus(.speaking)
            }
        case .idle:
            if let segment = currentSegment ?? playlist.current {
                speak(segment, from: spokenOffset)
            }
        case .finished:
            // The book ran out. Replay its last sentence rather than leaving
            // the bar's play button inert — a control that does nothing when
            // pressed reads as broken, and from here ⏮ walks back in.
            if let segment = currentSegment {
                speak(segment, from: 0)
            }
        }
    }

    public func pause() {
        guard isUnderway else { return }
        engine.pause()
        holdReason = nil
        setStatus(.paused)
    }

    public func togglePlayPause() {
        if isUnderway {
            pause()
        } else {
            play()
        }
    }

    /// Stop and forget the position — closing the Listen bar.
    public func stop() {
        engine.stop()
        activeRequestID = nil
        currentSegment = nil
        spokenOffset = 0
        activeRequestOrigin = 0
        currentSegmentLength = 0
        mustRespeakToResume = false
        holdReason = nil
        clearLookahead()
        sleepTimer.disarm()
        setStatus(.idle)
    }

    public func skipToNextSentence() {
        // Skipping past the last sentence really is the end of the book.
        move(atEnd: .finish) { $0.advance() }
    }

    public func skipToPreviousSentence() {
        // At the very start of the book there is nothing to step back to;
        // restart the sentence instead, which is what the control looks like
        // it should do.
        move(atEnd: .stayPut) { playlist in
            if let previous = playlist.rewind() { return previous }
            return playlist.current
        }
    }

    public func skipToNextChapter() {
        // No chapter after this one: stay where the voice is and keep reading,
        // the way a track control does at the end of a record. Declaring the
        // book finished here would strand narration mid-chapter.
        move(atEnd: .stayPut) { $0.advanceToNextChapter() }
    }

    public func skipToPreviousChapter() {
        move(atEnd: .stayPut) { playlist in
            if let previous = playlist.rewindToChapterStart() { return previous }
            return playlist.current
        }
    }

    /// Arm, re-arm, or clear the sleep timer.
    public func setSleepTimer(_ mode: SleepTimer) {
        sleepTimer.arm(mode, at: now())
        // Armed while paused, the countdown waits for playback to resume.
        if status != .speaking {
            sleepTimer.pause(at: now())
        }
    }

    /// Time left on a timed sleep, for the control's readout.
    public func sleepTimerRemaining() -> TimeInterval? {
        sleepTimer.remaining(at: now())
    }

    /// Evaluate the sleep timer, and notice an utterance that ended without
    /// saying so. The app ticks this once a second; the controller has no clock
    /// of its own so tests can drive it exactly.
    public func tick() {
        if status == .speaking, sleepTimer.hasExpired(at: now()) {
            stopForSleepTimer()
            return
        }
        checkForSilentEngine()
    }

    /// A completion callback can go missing — observed at the end of a book on
    /// macOS, where the voice stopped, `didFinish` never arrived, and the bar
    /// sat on Pause with the last sentence for minutes. Nothing downstream can
    /// recover from that, because every move the controller makes is driven by
    /// that callback.
    ///
    /// The engine's own state is the backstop: if it says it is idle while we
    /// think it is speaking, the utterance is over whatever we were told. Two
    /// consecutive ticks rather than one, because an engine may report idle for
    /// an instant between `speak()` and the audio actually starting.
    private func checkForSilentEngine() {
        guard isUnderway, activeRequestID != nil, engine.state != .speaking else {
            silentTicks = 0
            return
        }
        silentTicks += 1
        guard silentTicks >= 2 else { return }
        silentTicks = 0
        // Quiet because *paused*, not because the utterance ended: an audio
        // interruption (phone call, Siri) pauses the synthesizer without the
        // controller asking. Advancing from here treated every interrupted
        // sentence as spoken and machine-gunned through pages nobody heard —
        // hold instead, and `play()` resumes the same utterance.
        if engine.state == .paused {
            setStatus(.paused)
            return
        }
        // Dropped while still preparing: the sentence was never heard, so
        // it is not spoken. Hold on it; `play()` re-speaks it.
        if status == .preparing {
            activeRequestID = nil
            mustRespeakToResume = true
            setStatus(.paused)
            return
        }
        handleFinishedSegment()
    }

    // MARK: - Playback

    /// What a skip does when there is nothing left in that direction.
    private enum EndBehavior {
        /// The book is over.
        case finish
        /// Nothing to move to — carry on with the current sentence.
        case stayPut
    }

    /// Move the cursor and, if narration is running, follow it with the voice.
    /// Skipping while paused only moves — it must not start audio the reader
    /// paused.
    private func move(
        atEnd endBehavior: EndBehavior, _ step: (inout SpeechPlaylist) -> SpeechSegment?
    ) {
        guard status != .idle else { return }
        engine.stop()
        activeRequestID = nil
        // The reader took over: whatever held narration no longer applies.
        holdReason = nil
        // Skipping back from the end of the book puts narration in hand again.
        let wasSpeaking = isUnderway
        if status == .finished { setStatus(.paused) }

        guard let segment = step(&playlist) else {
            currentSegment = playlist.current
            currentSegmentLength = currentSegment.map { $0.text.count } ?? 0
            mustRespeakToResume = true
            switch endBehavior {
            case .finish:
                spokenOffset = 0
                setStatus(.finished)
            case .stayPut:
                // The engine was already stopped for the move; put the voice
                // back where it was so the skip is simply a no-op.
                if wasSpeaking, let segment = currentSegment {
                    speak(segment, from: spokenOffset)
                } else {
                    issueLookahead()
                }
            }
            return
        }
        if wasSpeaking {
            speak(segment, from: 0)
        } else {
            currentSegment = segment
            currentSegmentLength = segment.text.count
            spokenOffset = 0
            activeRequestOrigin = 0
            mustRespeakToResume = true
            onPositionChange?(
                NarrationPosition(
                    chapterIndex: segment.chapterIndex,
                    characterOffset: segment.range.lowerBound
                )
            )
            issueLookahead()
        }
    }

    /// Speak `segment` from `offset` characters in — non-zero when the
    /// remainder of an interrupted sentence is picked back up. The engine
    /// is handed the sentences that follow at the same time (unless
    /// `reissuingLookahead` is off: a speed change re-speaks without
    /// touching a lookahead that speed does not invalidate).
    private func speak(_ segment: SpeechSegment, from offset: Int, reissuingLookahead: Bool = true) {
        let characters = Array(segment.text)
        currentSegment = segment
        currentSegmentLength = characters.count
        let start = min(max(0, offset), characters.count)
        let body = String(characters[start...])
        guard !body.isEmpty else {
            // Nothing left in this sentence — treat it as spoken.
            handleFinishedSegment()
            return
        }

        spokenOffset = start
        activeRequestOrigin = start
        mustRespeakToResume = false
        let request = makeRequest(for: body)
        appliedSettings = settings
        activeRequestID = request.id
        setStatus(.speaking)
        onPositionChange?(
            NarrationPosition(
                chapterIndex: segment.chapterIndex,
                characterOffset: segment.range.lowerBound + start,
                sentenceStart: segment.range.lowerBound
            )
        )
        engine.speak(request)
        if reissuingLookahead {
            issueLookahead()
        }
    }

    private func makeRequest(for text: String) -> SpeechRequest {
        SpeechRequest(
            text: text,
            voiceID: settings.voiceID,
            language: language,
            rate: settings.rate,
            pitch: settings.pitch,
            volume: settings.volume,
            bookID: bookID
        )
    }

    // MARK: - Lookahead

    /// Hand an engine that synthesizes ahead the sentences after the
    /// current one, up to the horizon. Nothing for any other engine — the
    /// list is not even built.
    private func issueLookahead() {
        guard let prefetching = engine as? SpeechPrefetching else { return }
        let ahead = Self.segments(
            playlist.upcomingSegments(limit: Self.lookaheadSegmentCap),
            within: lookaheadHorizon, rate: settings.rate
        )
        lookahead = ahead.map { makeRequest(for: $0.text) }
        prefetching.prefetch(lookahead)
    }

    private func clearLookahead() {
        guard let prefetching = engine as? SpeechPrefetching else { return }
        guard !lookahead.isEmpty else { return }
        lookahead = []
        prefetching.prefetch([])
    }

    /// How many sentences the playlist is walked for at most — the rest of
    /// a long book is tens of thousands, which is fine to build once a
    /// sentence, but a bound keeps a pathological book from being
    /// unbounded work.
    static let lookaheadSegmentCap = 50_000

    /// Estimated seconds of audio for a sentence at `rate` — characters
    /// over `charactersPerSecond`, scaled by the speed.
    public static func estimatedSeconds(of segment: SpeechSegment, rate: Double) -> TimeInterval {
        Double(segment.text.count) / (charactersPerSecond * max(rate, 0.01))
    }

    /// The front of `segments` whose estimated audio reaches `horizon`:
    /// sentences are taken while the total so far is short of it, so the
    /// one that crosses the line is included and a horizon of zero takes
    /// nothing. `.restOfBook` takes them all.
    public static func segments(
        _ segments: [SpeechSegment], within horizon: LookaheadHorizon, rate: Double
    ) -> [SpeechSegment] {
        switch horizon {
        case .restOfBook:
            return segments
        case .seconds(let budget):
            var taken: [SpeechSegment] = []
            var total: TimeInterval = 0
            for segment in segments where total < budget {
                taken.append(segment)
                total += estimatedSeconds(of: segment, rate: rate)
            }
            return taken
        }
    }

    /// The current sentence was spoken through. Decide what happens next: stop
    /// for the sleep timer, hold at a chapter end, or read on.
    private func handleFinishedSegment() {
        activeRequestID = nil
        if sleepTimer.hasExpired(at: now()) {
            stopForSleepTimer()
            return
        }

        let finishedChapter = currentSegment?.chapterIndex
        guard let next = playlist.advance() else {
            engine.stop()
            spokenOffset = currentSegmentLength
            mustRespeakToResume = true
            clearLookahead()
            setStatus(.finished)
            return
        }

        if next.chapterIndex != finishedChapter {
            if sleepTimer.stopsAtChapterEnd {
                currentSegment = next
                currentSegmentLength = next.text.count
                spokenOffset = 0
                stopForSleepTimer()
                return
            }
            if !settings.autoAdvancesChapters {
                // Hold at the top of the next chapter: `play()` continues.
                currentSegment = next
                currentSegmentLength = next.text.count
                spokenOffset = 0
                activeRequestOrigin = 0
                mustRespeakToResume = true
                engine.stop()
                setStatus(.paused)
                onPositionChange?(
                    NarrationPosition(
                        chapterIndex: next.chapterIndex,
                        characterOffset: next.range.lowerBound
                    )
                )
                return
            }
        }
        speak(next, from: 0)
    }

    /// The sleep timer fired: stop the audio but keep the place, so pressing
    /// play resumes the sentence the reader dozed off on.
    private func stopForSleepTimer() {
        engine.stop()
        activeRequestID = nil
        mustRespeakToResume = true
        sleepTimer.disarm()
        setStatus(.paused)
    }

    /// A live speed/voice/volume change. The current sentence is re-spoken
    /// from the last word boundary the engine reported, so the change is heard
    /// immediately without repeating what was already read — unless only the
    /// speed changed and the engine can apply that to the audio in flight,
    /// in which case nothing is re-spoken and the lookahead, which speed
    /// does not invalidate, is left alone.
    private func applySettingsChange() {
        guard let segment = currentSegment else { return }
        switch status {
        case .speaking, .preparing:
            if onlyRateChanged(from: appliedSettings),
               let adjusting = engine as? SpeechRateAdjusting,
               adjusting.adjustRate(settings.rate) {
                appliedSettings = settings
                return
            }
            let speedOnly = onlyRateChanged(from: appliedSettings)
            engine.stop()
            activeRequestID = nil
            speak(segment, from: spokenOffset, reissuingLookahead: !speedOnly)
        case .paused:
            // Re-speaking now would start audio the reader paused; the new
            // settings are picked up by `play()`. `stop()` invalidates the
            // engine's old pump, so hand it a fresh list for the new settings.
            engine.stop()
            activeRequestID = nil
            mustRespeakToResume = true
            issueLookahead()
        case .idle, .finished:
            break
        }
    }

    /// The settings the engine was last given, for telling a speed-only
    /// change from any other.
    private lazy var appliedSettings: SpeechSettings = settings

    private func onlyRateChanged(from previous: SpeechSettings) -> Bool {
        var same = settings
        same.rate = previous.rate
        return same == previous && settings.rate != previous.rate
    }

    private func setStatus(_ new: NarrationStatus) {
        guard status != new else { return }
        if new != .paused { holdReason = nil }
        // The wait for the voice is over: the countdown that paused with
        // `.preparing` picks up here (a reader's pause is resumed by `play()`).
        if new == .speaking, status == .preparing {
            sleepTimer.resume(at: now())
        }
        status = new
        // The countdown only runs while narration does, whatever the reason it
        // stopped — the reader pausing, a chapter wall with auto-advance off,
        // an utterance the engine couldn't speak. Centralised here because
        // every one of those paths used to have to remember it, and two of
        // them didn't: the timer kept burning while nothing was being read,
        // then cut narration off a second after the reader pressed play.
        if new != .speaking {
            sleepTimer.pause(at: now())
        }
        onStatusChange?(new)
    }
}

// MARK: - Engine callbacks

extension NarrationController: SpeechEngineDelegate {
    public func speechEngine(_ engine: any SpeechEngine, didFinish requestID: UUID) {
        // Stale: this utterance was cancelled by a skip, a settings change, or
        // the sleep timer, and its completion must not advance the book.
        guard requestID == activeRequestID else { return }
        // Finished *while paused*: the reader tapped pause in the same instant
        // the utterance's audio ended (nothing was left to pause), and the
        // completion — queued asynchronously by the engine — landed after.
        // Advancing here would start the next sentence's audio against the
        // pause. Hold instead, with the sentence marked fully spoken so
        // `play()` moves on to the next one naturally.
        if status == .paused {
            activeRequestID = nil
            spokenOffset = currentSegmentLength
            mustRespeakToResume = true
            return
        }
        handleFinishedSegment()
    }

    public func speechEngine(_ engine: any SpeechEngine, isPreparing requestID: UUID) {
        // Only an utterance we asked for and are waiting on: a report for a
        // cancelled one is stale, and one arriving while paused must not
        // un-pause the reader.
        guard requestID == activeRequestID, status == .speaking else { return }
        setStatus(.preparing)
    }

    public func speechEngine(_ engine: any SpeechEngine, didBeginSpeaking requestID: UUID) {
        guard requestID == activeRequestID, status == .preparing else { return }
        setStatus(.speaking)
    }

    public func speechEngine(
        _ engine: any SpeechEngine, willSpeak range: Range<Int>, of requestID: UUID
    ) {
        guard requestID == activeRequestID, let segment = currentSegment else { return }
        // A word boundary is audio, whatever else the engine forgot to say.
        if status == .preparing { setStatus(.speaking) }
        let localLower = min(activeRequestOrigin + range.lowerBound, currentSegmentLength)
        let localUpper = min(activeRequestOrigin + range.upperBound, currentSegmentLength)
        spokenOffset = localLower
        guard localLower < localUpper else { return }
        onSpokenRangeChange?(
            segment.chapterIndex,
            (segment.range.lowerBound + localLower)..<(segment.range.lowerBound + localUpper)
        )
    }

    public func speechEngine(
        _ engine: any SpeechEngine, didFail requestID: UUID, error: any Error
    ) {
        guard requestID == activeRequestID else { return }
        activeRequestID = nil
        mustRespeakToResume = true
        setStatus(.paused)
    }

    public func speechEngine(
        _ engine: any SpeechEngine, didSuspend requestID: UUID, reason: NarrationHoldReason
    ) {
        guard requestID == activeRequestID else { return }
        activeRequestID = nil
        mustRespeakToResume = true
        holdReason = reason
        setStatus(.paused)
    }
}
