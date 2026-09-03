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
/// BNNS) — and each platform builds, prepares and speaks through at most one
/// of them, `readrVoice`. Which runtime that is, and which engine gets a
/// sentence, are both `NarrationEnginePolicy`'s call (ReadrKit,
/// table-tested); the router only carries out the answer. The per-sentence
/// evaluation is what makes the fallbacks seamless — while the model
/// downloads, or while the app is backgrounded on iOS, the platform voice
/// reads that sentence and Readr Voice returns at the next boundary.
///
/// Every sub-engine reports through this router; a callback is forwarded only
/// if it comes from the engine that owns the current utterance, so a stale
/// completion from the engine just switched *away from* can't advance the
/// book (the same stale-callback discipline `AVSpeechEngine` applies per
/// utterance).
final class RoutingSpeechEngine: SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    private let platform: AVSpeechEngine
    /// Built on macOS only, and only outside the BNNS crash gate. iOS is
    /// MLX-or-platform: CoreML Kokoro is never constructed there, so an
    /// iOS 18–26.3 device or simulator (which pass the gate) never prepares
    /// or enters it.
    private let coreML: KokoroSpeechEngine?
    #if os(iOS)
    /// Nil where MLX cannot run (the simulator, no Metal GPU) — the router
    /// then narrates through the platform voice and nothing is downloaded.
    private let mlx: MLXKokoroSpeechEngine?
    #endif
    /// The Kokoro engine this platform prepares, and whose readiness the
    /// Listen bar shows — `readrVoiceRuntime`'s engine. Nil when no runtime
    /// can serve; `NarrationModel.readrVoiceUnavailable` says why.
    private let readrVoice: (any ReadrVoiceEngine)?
    /// The engine the last `speak` was routed to — the one allowed to report.
    private var current: (any SpeechEngine)?
    /// The request `current` is on — what the failure fallback re-speaks
    /// through the platform engine when Kokoro can't deliver it.
    private var currentRequest: SpeechRequest?

    /// The Kokoro runtime this process would use for Readr Voice; nil when
    /// neither can serve, in which case the voice is not offered.
    static var readrVoiceRuntime: NarrationEnginePolicy.KokoroRuntime? {
        #if os(iOS)
        // iOS is MLX-or-platform. `KokoroSpeechEngine.isSupportedOnThisOS`
        // is true on iOS 18–26.3, but CoreML Kokoro must never be prepared on
        // a phone: one runtime, one model download, and no BNNS exposure.
        return NarrationEnginePolicy.kokoroRuntime(
            mlxAvailable: MLXKokoroSpeechEngine.isAvailableOnThisDevice, coreMLSupported: false
        )
        #else
        return NarrationEnginePolicy.kokoroRuntime(
            mlxAvailable: false, coreMLSupported: KokoroSpeechEngine.isSupportedOnThisOS
        )
        #endif
    }

    static var isReadrVoiceAvailable: Bool { readrVoiceRuntime != nil }

    /// The runtime this router was built with — for the model, which must
    /// not evaluate the static (it probes for a Metal device) when it runs
    /// under the UI-test stub and has no router at all.
    let readrVoiceRuntime: NarrationEnginePolicy.KokoroRuntime?

    init(platform: AVSpeechEngine = AVSpeechEngine()) {
        self.platform = platform
        let runtime = Self.readrVoiceRuntime
        readrVoiceRuntime = runtime
        // The policy's answer, and nothing else, decides which engine exists.
        switch runtime {
        case .mlx:
            #if os(iOS)
            let mlx = MLXKokoroSpeechEngine()
            self.mlx = mlx
            coreML = nil
            readrVoice = mlx
            #else
            // Unreachable: the policy answers `.mlx` only where an MLX engine
            // exists, and one never exists on macOS.
            coreML = nil
            readrVoice = nil
            #endif
        case .coreML:
            #if os(iOS)
            mlx = nil
            #endif
            let coreML = KokoroSpeechEngine()
            self.coreML = coreML
            readrVoice = coreML
        case nil:
            #if os(iOS)
            mlx = nil
            #endif
            coreML = nil
            readrVoice = nil
        }
        platform.delegate = self
        coreML?.delegate = self
        #if os(iOS)
        mlx?.delegate = self
        #endif
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
            coreMLKokoroUsable: coreML?.isReady ?? false,
            mlxKokoroAvailable: mlxAvailable,
            mlxKokoroReady: mlxReady,
            isForeground: isForeground
        )
    }

    func speak(_ request: SpeechRequest) {
        let situation = situation(for: request)
        let target: any SpeechEngine
        switch NarrationEnginePolicy.engine(for: situation) {
        case .coreMLKokoro:
            // `coreMLKokoroUsable` is false whenever `coreML` is nil, so the
            // fallback here is unreachable — kept so the switch is total.
            target = coreML ?? platform
        case .mlxKokoro:
            #if os(iOS)
            target = mlx ?? platform
            #else
            target = platform
            #endif
        case .platform:
            // Readr Voice may be chosen while its model isn't in yet (a
            // first-use download), or — on iOS — while the app is
            // backgrounded. Narration must start NOW, so the platform voice
            // reads in the meantime (AVSpeechEngine treats the unknown voice
            // id as "pick for the language") and the very next sentence after
            // the model lands, or the app is back in the foreground, routes
            // to Kokoro and switches voices at the sentence boundary.
            //
            // Auto-prepare only from the UNTRIED state, and only in the
            // foreground. A `.failed` download must not restart per sentence
            // — that hammered a flaky connection with a fresh
            // multi-hundred-MB attempt every few seconds and flapped the
            // menu note; after a failure, retry is the explicit re-pick
            // (`NarrationModel.setVoice`), which is exactly what the menu's
            // failure note tells the reader. And a download that failed
            // while backgrounded resets to `.notReady` (see the MLX engine)
            // so that it CAN retry — on the next foreground sentence, not on
            // every sentence read from a pocket.
            if situation.requestsReadrVoice, situation.isForeground,
               let readrVoice, readrVoice.readiness == .notReady {
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
        coreML?.stop()
        #if os(iOS)
        mlx?.stop()
        #endif
    }

    /// Pre-download the Kokoro model for this platform's runtime — called
    /// when the reader picks the Readr Voice so the first spoken sentence
    /// doesn't carry the wait.
    func prepareKokoro() {
        readrVoice?.prepare()
    }

    /// Download/readiness changes of the Readr Voice, for the Listen bar
    /// (the model keeps its own published copy; there is no snapshot getter).
    var onReadrVoiceReadinessChange: ((ReadrVoiceReadiness) -> Void)? {
        get { readrVoice?.onReadinessChange }
        set { readrVoice?.onReadinessChange = newValue }
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
