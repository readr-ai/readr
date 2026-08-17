import Foundation

public enum NarrationStatus: Hashable, Sendable {
    /// Not narrating; the Listen bar is closed.
    case idle
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
        self.now = now
        engine.delegate = self
    }

    // MARK: - Reading

    public var isSpeaking: Bool { status == .speaking }
    /// True whenever the Listen bar should be on screen.
    public var isActive: Bool { status != .idle }
    /// Progress through the chapter being narrated, 0...1.
    public var chapterProgress: Double { playlist.chapterProgress }
    public var position: NarrationPosition? {
        currentSegment.map {
            NarrationPosition(
                chapterIndex: $0.chapterIndex,
                characterOffset: $0.range.lowerBound + min(spokenOffset, currentSegmentLength)
            )
        }
    }

    // MARK: - Controls

    /// Start reading at a position — the Listen button's entry point, where
    /// the position is the top of the visible page (or a chapter picked from
    /// Contents). Narration begins at the first sentence that hasn't been
    /// passed, never mid-sentence.
    public func start(atChapter chapterIndex: Int, characterOffset: Int = 0) {
        engine.stop()
        activeRequestID = nil
        guard let segment = playlist.seek(
            toChapter: chapterIndex, characterOffset: characterOffset
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
        case .speaking:
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
        guard status == .speaking else { return }
        engine.pause()
        setStatus(.paused)
    }

    public func togglePlayPause() {
        if status == .speaking {
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

    /// Evaluate the sleep timer. The app ticks this once a second; the
    /// controller has no clock of its own so tests can drive it exactly.
    public func tick() {
        guard status == .speaking, sleepTimer.hasExpired(at: now()) else { return }
        stopForSleepTimer()
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
        // Skipping back from the end of the book puts narration in hand again.
        let wasSpeaking = status == .speaking
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
        }
    }

    /// Speak `segment` from `offset` characters in — non-zero when the
    /// remainder of an interrupted sentence is picked back up.
    private func speak(_ segment: SpeechSegment, from offset: Int) {
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
        let request = SpeechRequest(
            text: body,
            voiceID: settings.voiceID,
            language: language,
            rate: settings.rate,
            pitch: settings.pitch,
            volume: settings.volume
        )
        activeRequestID = request.id
        setStatus(.speaking)
        onPositionChange?(
            NarrationPosition(
                chapterIndex: segment.chapterIndex,
                characterOffset: segment.range.lowerBound + start
            )
        )
        engine.speak(request)
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
    /// immediately without repeating what was already read.
    private func applySettingsChange() {
        guard let segment = currentSegment else { return }
        switch status {
        case .speaking:
            engine.stop()
            activeRequestID = nil
            speak(segment, from: spokenOffset)
        case .paused:
            // Re-speaking now would start audio the reader paused; the new
            // settings are picked up by `play()`.
            engine.stop()
            activeRequestID = nil
            mustRespeakToResume = true
        case .idle, .finished:
            break
        }
    }

    private func setStatus(_ new: NarrationStatus) {
        guard status != new else { return }
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
        handleFinishedSegment()
    }

    public func speechEngine(
        _ engine: any SpeechEngine, willSpeak range: Range<Int>, of requestID: UUID
    ) {
        guard requestID == activeRequestID, let segment = currentSegment else { return }
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
}
