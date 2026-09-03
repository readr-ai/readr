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
    /// The request `current` is on — what the failure fallback re-speaks
    /// through the platform engine when Kokoro can't deliver it.
    private var currentRequest: SpeechRequest?

    init(
        platform: AVSpeechEngine = AVSpeechEngine(),
        kokoro: KokoroSpeechEngine = KokoroSpeechEngine()
    ) {
        self.platform = platform
        self.kokoro = kokoro
        platform.delegate = self
        kokoro.delegate = self
    }

    var state: SpeechEngineState {
        current?.state ?? .idle
    }

    func speak(_ request: SpeechRequest) {
        let target: any SpeechEngine
        if KokoroSpeechEngine.isKokoroVoiceID(request.voiceID) {
            if kokoro.isReady {
                target = kokoro
            } else {
                // An `.unsupported` engine is routed around here too.
                // Readr Voice is chosen but its model isn't in yet (first-use
                // ~104MB download). Narration must start NOW — a Listen button
                // that buffers for minutes reads as broken — so the platform
                // voice reads in the meantime (AVSpeechEngine treats the
                // unknown voice id as "pick for the language") and the very
                // next sentence after the model lands routes here and switches
                // voices at the sentence boundary.
                //
                // Auto-prepare only from the UNTRIED state. A `.failed`
                // download must not restart per sentence — that hammered a
                // flaky connection with a fresh ~104MB attempt every few
                // seconds and flapped the menu note. After a failure, retry
                // is the explicit re-pick (`NarrationModel.setVoice`), which
                // is exactly what the menu's failure note tells the reader.
                if kokoro.readiness == .notReady {
                    kokoro.prepare()
                }
                target = platform
            }
        } else {
            target = platform
        }
        // Switching engines mid-flight: silence the one being left, so two
        // voices never overlap.
        if let current, current !== target {
            current.stop()
        }
        current = target
        currentRequest = request
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
        currentRequest = nil
        platform.stop()
        kokoro.stop()
    }

    /// Pre-download the Kokoro model — called when the reader picks the
    /// Readr Voice so the first spoken sentence doesn't carry the wait.
    func prepareKokoro() {
        kokoro.prepare()
    }

    /// Download/readiness changes of the Readr Voice, for the Listen bar
    /// (the model keeps its own published copy; there is no snapshot getter).
    var onReadrVoiceReadinessChange: ((KokoroSpeechEngine.Readiness) -> Void)? {
        get { kokoro.onReadinessChange }
        set { kokoro.onReadinessChange = newValue }
    }

    /// Narration is over (the Listen bar closed): hand the audio session back.
    /// One deactivation — the session is process-global, so per-engine calls
    /// deactivated the same session twice.
    func endAudioSession() {
        NarrationAudioSession.deactivate()
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
        // The promised platform fallback: a Kokoro failure AFTER the model is
        // in (synthesis fault, refused playback) must not pause the default
        // voice in a fail loop — the same request is re-spoken through the
        // platform engine under the same id, so the controller never notices.
        // Per-sentence, deliberately: the next sentence tries Kokoro again,
        // which self-heals transient faults and costs one failed synthesis
        // (~200ms) when it doesn't. A platform failure is reported as before.
        if engine === kokoro, let request = currentRequest, request.id == requestID {
            current = platform
            platform.speak(request)
            return
        }
        delegate?.speechEngine(self, didFail: requestID, error: error)
    }
}
