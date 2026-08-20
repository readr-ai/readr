import Foundation
import ReadrKit

/// One `SpeechEngine` that routes each request to the platform synthesizer or
/// to Kokoro by its voice id — `KokoroSpeechEngine.voiceIDPrefix` ids go to
/// the neural voice, everything else (including nil) to `AVSpeechEngine`.
///
/// Routing at the request level, rather than swapping engines on the
/// controller, means the existing voice-change path just works:
/// `NarrationController.applySettingsChange` already re-speaks the current
/// sentence when `voiceID` changes, and the re-spoken request simply lands on
/// the other engine. The controller keeps exactly one `engine` and stays
/// untouched.
///
/// Both sub-engines report through this router; a callback is forwarded only
/// if it comes from the engine that owns the current utterance, so a stale
/// completion from the engine just switched *away from* can't advance the
/// book (the same stale-callback discipline `AVSpeechEngine` applies per
/// utterance).
final class RoutingSpeechEngine: SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    private let platform: AVSpeechEngine
    private let kokoro: KokoroSpeechEngine
    /// The engine the last `speak` was routed to — the one allowed to report.
    private var current: (any SpeechEngine)?

    init(platform: AVSpeechEngine = AVSpeechEngine(), kokoro: KokoroSpeechEngine = KokoroSpeechEngine()) {
        self.platform = platform
        self.kokoro = kokoro
        platform.delegate = self
        kokoro.delegate = self
    }

    var state: SpeechEngineState {
        current?.state ?? .idle
    }

    func speak(_ request: SpeechRequest) {
        let target: any SpeechEngine =
            KokoroSpeechEngine.isKokoroVoiceID(request.voiceID) ? kokoro : platform
        // Switching engines mid-flight: silence the one being left, so two
        // voices never overlap.
        if let current, current !== target {
            current.stop()
        }
        current = target
        target.speak(request)
    }

    func pause() {
        current?.pause()
    }

    func resume() {
        current?.resume()
    }

    func stop() {
        // Both, unconditionally — stop is the everything-off switch and must
        // never depend on routing state.
        platform.stop()
        kokoro.stop()
    }

    /// Pre-download the Kokoro model — called when the reader picks the
    /// Readr Voice so the first spoken sentence doesn't carry the wait.
    func prepareKokoro() {
        kokoro.prepare()
    }

    /// Narration is over (the Listen bar closed): hand the audio session back.
    func endAudioSession() {
        platform.endAudioSession()
        kokoro.endAudioSession()
    }
}

extension RoutingSpeechEngine: SpeechEngineDelegate {
    func speechEngine(_ engine: any SpeechEngine, didFinish requestID: UUID) {
        guard engine === current else { return }
        delegate?.speechEngine(self, didFinish: requestID)
    }

    func speechEngine(_ engine: any SpeechEngine, willSpeak range: Range<Int>, of requestID: UUID) {
        guard engine === current else { return }
        delegate?.speechEngine(self, willSpeak: range, of: requestID)
    }

    func speechEngine(_ engine: any SpeechEngine, didFail requestID: UUID, error: any Error) {
        guard engine === current else { return }
        delegate?.speechEngine(self, didFail: requestID, error: error)
    }
}
