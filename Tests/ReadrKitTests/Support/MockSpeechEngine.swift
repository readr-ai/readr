import Foundation
@testable import ReadrKit

/// A speech engine that records what it was asked to do and only makes
/// progress when a test says so — so every playback rule is exercised
/// deterministically, with no audio hardware and no waiting.
final class MockSpeechEngine: SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?
    private(set) var state: SpeechEngineState = .idle

    /// Every request, in order.
    private(set) var spoken: [SpeechRequest] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0

    /// The request the engine is currently on (nil once stopped/finished).
    private(set) var active: SpeechRequest?

    /// Texts of every request, for readable assertions.
    var spokenTexts: [String] { spoken.map(\.text) }

    func speak(_ request: SpeechRequest) {
        spoken.append(request)
        active = request
        state = .speaking
    }

    func pause() {
        pauseCount += 1
        state = .paused
    }

    func resume() {
        resumeCount += 1
        state = .speaking
    }

    func stop() {
        stopCount += 1
        active = nil
        state = .idle
    }

    // MARK: - Driving the engine from a test

    /// The engine speaks the current utterance through to the end.
    func finishCurrent() {
        guard let request = active else { return }
        active = nil
        state = .idle
        delegate?.speechEngine(self, didFinish: request.id)
    }

    /// A word-boundary report for the current utterance, in character offsets
    /// into its text (what `AVSpeechEngine` converts UTF-16 boundaries into).
    func speakWord(_ range: Range<Int>) {
        guard let request = active else { return }
        delegate?.speechEngine(self, willSpeak: range, of: request.id)
    }

    /// The engine goes quiet without saying so — an utterance whose completion
    /// callback never arrives. Observed at the end of a book on macOS, where it
    /// left the bar on Pause with the last sentence for minutes.
    func fallSilentWithoutReporting() {
        state = .idle
    }

    /// The engine pauses without the controller asking — what an audio
    /// interruption (phone call, Siri) does to `AVSpeechSynthesizer`.
    func pauseWithoutBeingAsked() {
        state = .paused
    }

    /// A "finished" arriving from an utterance that was already cancelled —
    /// the race every interrupting control has to survive.
    func finishStaleRequest(_ requestID: UUID) {
        delegate?.speechEngine(self, didFinish: requestID)
    }

    func fail(_ error: any Error = SpeechEngineError.noVoiceAvailable) {
        guard let request = active else { return }
        active = nil
        state = .idle
        delegate?.speechEngine(self, didFail: request.id, error: error)
    }

    /// The engine has taken the utterance but cannot voice it yet — its
    /// model is still downloading (Readr Voice on first use).
    func reportPreparing() {
        guard let request = active else { return }
        delegate?.speechEngine(self, isPreparing: request.id)
    }

    /// Audio for the current utterance has started.
    func reportBeganSpeaking() {
        guard let request = active else { return }
        delegate?.speechEngine(self, didBeginSpeaking: request.id)
    }

    /// A "preparing" report from an utterance already cancelled.
    func reportPreparing(stale requestID: UUID) {
        delegate?.speechEngine(self, isPreparing: requestID)
    }
}
