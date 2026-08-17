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

    public init(
        id: UUID = UUID(),
        text: String,
        voiceID: String? = nil,
        language: String? = nil,
        rate: Double = 1,
        pitch: Double = 1,
        volume: Double = 1
    ) {
        self.id = id
        self.text = text
        self.voiceID = voiceID
        self.language = language
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
    }
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
}

public extension SpeechEngineDelegate {
    func speechEngine(_ engine: any SpeechEngine, willSpeak range: Range<Int>, of requestID: UUID) {}
    func speechEngine(_ engine: any SpeechEngine, didFail requestID: UUID, error: any Error) {}
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
    /// Stop and discard the current utterance. No `didFinish` follows.
    func stop()
}
