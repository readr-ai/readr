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
/// Two Kokoro runtimes exist — CoreML (`KokoroSpeechEngine`, macOS) and MLX
/// (`MLXKokoroSpeechEngine`, iPhone/iPad, where CoreML crashes inside Apple's
/// BNNS) — and each platform prepares and speaks through exactly one of them,
/// `readrVoice`. Which engine gets a sentence is `NarrationEnginePolicy`'s
/// call (ReadrKit, table-tested), evaluated per request: that is what makes
/// the fallbacks seamless — while the model downloads, or while the screen is
/// locked on iOS, the platform voice reads that sentence and Readr Voice
/// returns at the next boundary.
///
/// Every sub-engine reports through this router; a callback is forwarded only
/// if it comes from the engine that owns the current utterance, so a stale
/// completion from the engine just switched *away from* can't advance the
/// book (the same stale-callback discipline `AVSpeechEngine` applies per
/// utterance).
final class RoutingSpeechEngine: SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    private let platform: AVSpeechEngine
    private let coreML: KokoroSpeechEngine
    #if os(iOS)
    /// Nil where MLX cannot run (the simulator, no Metal GPU) — the router
    /// then behaves exactly as it did before MLX existed.
    private let mlx: MLXKokoroSpeechEngine?
    #endif
    /// The Kokoro engine this platform prepares, and whose readiness the
    /// Listen bar shows: MLX where it exists, CoreML otherwise.
    private let readrVoice: any ReadrVoiceEngine
    /// The engine the last `speak` was routed to — the one allowed to report.
    private var current: (any SpeechEngine)?
    /// The request `current` is on — what the failure fallback re-speaks
    /// through the platform engine when Kokoro can't deliver it.
    private var currentRequest: SpeechRequest?

    /// The Kokoro runtime this process would use for Readr Voice; nil when
    /// neither can serve, in which case the voice is not offered.
    static var readrVoiceRuntime: NarrationEnginePolicy.KokoroRuntime? {
        #if os(iOS)
        let mlxAvailable = MLXKokoroSpeechEngine.isAvailableOnThisDevice
        #else
        let mlxAvailable = false
        #endif
        return NarrationEnginePolicy.kokoroRuntime(
            mlxAvailable: mlxAvailable, coreMLSupported: KokoroSpeechEngine.isSupportedOnThisOS
        )
    }

    static var isReadrVoiceAvailable: Bool { readrVoiceRuntime != nil }

    init(
        platform: AVSpeechEngine = AVSpeechEngine(),
        coreML: KokoroSpeechEngine = KokoroSpeechEngine()
    ) {
        self.platform = platform
        self.coreML = coreML
        #if os(iOS)
        let mlx = MLXKokoroSpeechEngine.isAvailableOnThisDevice ? MLXKokoroSpeechEngine() : nil
        self.mlx = mlx
        if let mlx {
            self.readrVoice = mlx
        } else {
            self.readrVoice = coreML
        }
        mlx?.delegate = self
        #else
        self.readrVoice = coreML
        #endif
        platform.delegate = self
        coreML.delegate = self
    }

    var state: SpeechEngineState {
        current?.state ?? .idle
    }

    private func situation(for request: SpeechRequest) -> NarrationEnginePolicy.Situation {
        #if os(iOS)
        let mlxAvailable = mlx != nil
        let mlxReady = mlx?.isReady ?? false
        let isForeground = mlx?.isForeground ?? true
        #else
        let mlxAvailable = false
        let mlxReady = false
        let isForeground = true
        #endif
        return NarrationEnginePolicy.Situation(
            requestsReadrVoice: KokoroSpeechEngine.isKokoroVoiceID(request.voiceID),
            coreMLKokoroUsable: coreML.isReady,
            mlxKokoroAvailable: mlxAvailable,
            mlxKokoroReady: mlxReady,
            isForeground: isForeground
        )
    }

    func speak(_ request: SpeechRequest) {
        let target: any SpeechEngine
        switch NarrationEnginePolicy.engine(for: situation(for: request)) {
        case .coreMLKokoro:
            target = coreML
        case .mlxKokoro:
            #if os(iOS)
            if let mlx {
                target = mlx
            } else {
                target = platform
            }
            #else
            target = platform
            #endif
        case .platform:
            // Readr Voice may be chosen while its model isn't in yet (a
            // first-use download), or — on iOS — while the screen is locked.
            // Narration must start NOW, so the platform voice reads in the
            // meantime (AVSpeechEngine treats the unknown voice id as "pick
            // for the language") and the very next sentence after the model
            // lands, or the app is active again, routes to Kokoro and
            // switches voices at the sentence boundary.
            //
            // Auto-prepare only from the UNTRIED state. A `.failed` download
            // must not restart per sentence — that hammered a flaky
            // connection with a fresh multi-hundred-MB attempt every few
            // seconds and flapped the menu note. After a failure, retry is
            // the explicit re-pick (`NarrationModel.setVoice`), which is
            // exactly what the menu's failure note tells the reader.
            if KokoroSpeechEngine.isKokoroVoiceID(request.voiceID),
               readrVoice.readiness == .notReady {
                readrVoice.prepare()
            }
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
        // Every engine, unconditionally — stop is the everything-off switch
        // and must never depend on routing state.
        currentRequest = nil
        platform.stop()
        coreML.stop()
        #if os(iOS)
        mlx?.stop()
        #endif
    }

    /// Pre-download the Kokoro model for this platform's runtime — called
    /// when the reader picks the Readr Voice so the first spoken sentence
    /// doesn't carry the wait.
    func prepareKokoro() {
        readrVoice.prepare()
    }

    /// Download/readiness changes of the Readr Voice, for the Listen bar
    /// (the model keeps its own published copy; there is no snapshot getter).
    var onReadrVoiceReadinessChange: ((ReadrVoiceReadiness) -> Void)? {
        get { readrVoice.onReadinessChange }
        set { readrVoice.onReadinessChange = newValue }
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
        // in (synthesis fault, refused playback, the app backgrounded
        // mid-synthesis on iOS) must not pause the default voice in a fail
        // loop — the same request is re-spoken through the platform engine
        // under the same id, so the controller never notices. Per-sentence,
        // deliberately: the next sentence tries Kokoro again, which
        // self-heals transient faults and costs one failed synthesis when it
        // doesn't. A platform failure is reported as before.
        if engine !== platform, let request = currentRequest, request.id == requestID {
            current = platform
            platform.speak(request)
            return
        }
        delegate?.speechEngine(self, didFail: requestID, error: error)
    }
}
