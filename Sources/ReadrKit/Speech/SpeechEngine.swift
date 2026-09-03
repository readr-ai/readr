import Foundation

/// One thing to say.
///
/// Requests carry an `id` so callbacks can be matched to the utterance that
/// produced them: every control that interrupts narration (skip, speed change,
/// sleep) cancels what is being spoken, and a late "finished" from the
/// cancelled utterance must not be mistaken for the sentence ending and advance
/// the book.
public struct SpeechRequest: Hashable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    /// Preferred voice; nil lets the engine choose for `language`.
    public var voiceID: String?
    /// BCP-47 language of the text, used when no voice is named.
    public var language: String?
    /// Speaking rate as a multiple of the voice's normal pace (see
    /// `SpeechSettings.platformRate(normal:minimum:maximum:)`).
    public var rate: Double
    public var pitch: Double
    public var volume: Double
    /// The book the text comes from. An engine that keeps synthesized audio
    /// keys it by book, voice and text, so the audio goes when the book does.
    public var bookID: UUID?

    public init(
        id: UUID = UUID(),
        text: String,
        voiceID: String? = nil,
        language: String? = nil,
        rate: Double = 1,
        pitch: Double = 1,
        volume: Double = 1,
        bookID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.voiceID = voiceID
        self.language = language
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.bookID = bookID
    }
}

/// Why narration holds without the reader asking — shown on the Listen bar
/// and the lock screen while it does.
public enum NarrationHoldReason: Hashable, Sendable {
    /// The engine has nothing synthesized for the next sentence and cannot
    /// make it where the app is (backgrounded, with the GPU withheld): the
    /// reader unlocks the phone to go on. "Paused — unlock Readr to keep
    /// listening."
    case needsForeground
}

public enum SpeechEngineState: Hashable, Sendable {
    case idle
    case speaking
    case paused
}

public enum SpeechEngineError: Error, Sendable, Equatable {
    /// No installed voice could speak the request.
    case noVoiceAvailable
    /// The platform refused to start audio (session conflict, no output).
    case audioUnavailable
}

/// What an engine reports back. Callbacks arrive on the main thread — the
/// controller is main-thread-confined and drives the reader's UI directly.
public protocol SpeechEngineDelegate: AnyObject {
    /// The utterance finished speaking of its own accord. Never sent for an
    /// utterance stopped by `stop()`.
    func speechEngine(_ engine: any SpeechEngine, didFinish requestID: UUID)
    /// The engine is about to speak `range` — **character** offsets into the
    /// request's `text`, so an engine reporting UTF-16 offsets converts first.
    func speechEngine(_ engine: any SpeechEngine, willSpeak range: Range<Int>, of requestID: UUID)
    /// The utterance could not be spoken.
    func speechEngine(_ engine: any SpeechEngine, didFail requestID: UUID, error: any Error)
    /// The engine has taken the utterance but cannot voice it yet: its voice
    /// is still being prepared — Readr Voice's first-use model download.
    /// Narration shows a preparing state until `didBeginSpeaking` (or a
    /// word boundary, a finish, or a failure) arrives for the same request.
    /// An engine may report this more than once for one utterance — after a
    /// `resume()` that finds the model still not in, for instance.
    func speechEngine(_ engine: any SpeechEngine, isPreparing requestID: UUID)
    /// Audio for the utterance has started. Only meaningful after
    /// `isPreparing`; engines that never prepare need not send it.
    func speechEngine(_ engine: any SpeechEngine, didBeginSpeaking requestID: UUID)
    /// The engine has set the utterance down unspoken and will not pick it
    /// up on its own: it needs something from outside, named by `reason`.
    /// Narration holds on the sentence; `play()` re-speaks it.
    func speechEngine(
        _ engine: any SpeechEngine, didSuspend requestID: UUID, reason: NarrationHoldReason
    )
}

public extension SpeechEngineDelegate {
    func speechEngine(_ engine: any SpeechEngine, willSpeak range: Range<Int>, of requestID: UUID) {}
    func speechEngine(_ engine: any SpeechEngine, didFail requestID: UUID, error: any Error) {}
    func speechEngine(_ engine: any SpeechEngine, isPreparing requestID: UUID) {}
    func speechEngine(_ engine: any SpeechEngine, didBeginSpeaking requestID: UUID) {}
    func speechEngine(
        _ engine: any SpeechEngine, didSuspend requestID: UUID, reason: NarrationHoldReason
    ) {}
}

/// An engine that can synthesize ahead of the voice. Optional: the
/// controller checks for it and hands such an engine the sentences that
/// follow the one being spoken, as far ahead as its horizon reaches
/// (`NarrationController.lookaheadHorizon`).
public protocol SpeechPrefetching: AnyObject {
    /// The sentences after the current one, in playback order. Replaces the
    /// previous list; re-sent whenever a sentence starts, after skips, and
    /// after a voice change. What the engine does with it — how much it
    /// synthesizes, when, and where it keeps the audio — is the engine's.
    func prefetch(_ requests: [SpeechRequest])
    /// Seconds of audio the engine already holds for `requests`, counted
    /// from the head of the list until the first sentence it does not hold
    /// — a gap would have to be synthesized before anything after it could
    /// play, so audio beyond a gap is not "ahead".
    func secondsBuffered(ahead requests: [SpeechRequest]) -> TimeInterval
}

/// An engine that can change speed without re-speaking. Optional: for one
/// that cannot, the controller re-speaks the sentence from the last word
/// boundary with the new rate, as it always has.
public protocol SpeechRateAdjusting: AnyObject {
    /// Apply `rate` to the utterance in flight. False when this engine
    /// cannot do that for the utterance it is on, in which case the
    /// controller re-speaks it.
    func adjustRate(_ rate: Double) -> Bool
}

/// The narration back end.
///
/// `AVSpeechSynthesizer` sits behind this in the app target, which keeps
/// `ReadrKit` platform-agnostic (the package builds and tests on Linux CI) and
/// leaves every playback rule — ordering, skipping, sleep, resume-after-speed-
/// change — testable against a mock. A neural on-device voice can replace the
/// system synthesizer later without the controller noticing.
///
/// Implementations must hold `delegate` weakly: the controller owns the engine
/// and is itself the delegate.
public protocol SpeechEngine: AnyObject {
    var delegate: (any SpeechEngineDelegate)? { get set }
    var state: SpeechEngineState { get }

    /// Speak `request`, replacing anything currently being spoken.
    func speak(_ request: SpeechRequest)
    /// Hold the current utterance where it is, resumable by `resume()`.
    func pause()
    func resume()
    /// Stop and discard the current utterance. No `didFinish` follows. An
    /// engine that also conforms to `SpeechPrefetching` must cancel its pump
    /// and discard the last prefetch list; one unavoidable synthesis already
    /// in flight may finish, but it must not schedule more work from that list.
    func stop()
}
