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
/// table-tested); the router only carries out the answer.
///
/// There is no fallback in here. Since 3.3.1 a Readr Voice request goes to
/// the Readr Voice engine whether or not its model is in: the engine waits
/// (reporting `isPreparing`, which the bar shows) and speaks the moment it
/// can, and a failure is reported to the controller as a failure — narration
/// pauses and the bar offers Retry. An Apple voice reads only what the
/// reader gave it: a non-English book, or a voice picked under "Other
/// voices".
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
        let mlxFailed = mlx?.readiness == .failed
        #else
        let mlxAvailable = false
        let mlxFailed = false
        #endif
        // A CoreML engine exists only outside the OS gate, so "exists and
        // hasn't failed" is the whole of "can serve" — downloading counts.
        let coreMLAvailable = coreML.map { $0.readiness != .failed } ?? false
        return NarrationEnginePolicy.Situation(
            requestsReadrVoice: KokoroSpeechEngine.isKokoroVoiceID(request.voiceID),
            coreMLKokoroAvailable: coreMLAvailable,
            mlxKokoroAvailable: mlxAvailable,
            mlxKokoroFailed: mlxFailed
        )
    }

    func speak(_ request: SpeechRequest) {
        let target: any SpeechEngine
        switch NarrationEnginePolicy.engine(for: situation(for: request)) {
        case .coreMLKokoro:
            // `coreMLKokoroAvailable` is false whenever `coreML` is nil, so
            // the fallback here is unreachable — kept so the switch is total.
            target = coreML ?? platform
        case .mlxKokoro:
            #if os(iOS)
            target = mlx ?? platform
            #else
            target = platform
            #endif
        case .platform:
            // A platform voice id, a language Readr Voice can't read, or —
            // the backstop — a Readr Voice engine that has failed. That last
            // case is never reached from the app without a Retry first
            // (`NarrationModel.play`), because an Apple voice must not read
            // a Readr Voice book on its own account.
            target = platform
        }
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
        // Every engine, unconditionally — stop is the everything-off switch
        // and must never depend on routing state.
        platform.stop()
        coreML?.stop()
        #if os(iOS)
        mlx?.stop()
        #endif
    }

    /// Download the Kokoro model for this platform's runtime without
    /// speaking — the explicit pick, and the bar's Retry after a failure.
    func prepareKokoro() {
        readrVoice?.prepare()
    }

    /// Where the Readr Voice engine stands, for the model's Retry decision.
    var readrVoiceReadiness: ReadrVoiceReadiness? {
        readrVoice?.readiness
    }

    /// Download/readiness changes of the Readr Voice, for the Listen bar
    /// (the model keeps its own published copy; there is no snapshot getter).
    var onReadrVoiceReadinessChange: ((ReadrVoiceReadiness) -> Void)? {
        get { readrVoice?.onReadinessChange }
        set { readrVoice?.onReadinessChange = newValue }
    }

    /// Download progress of the Readr Voice model, for the bar's preparing
    /// state.
    var onReadrVoiceDownloadProgressChange: ((Double?) -> Void)? {
        get { readrVoice?.onDownloadProgressChange }
        set { readrVoice?.onDownloadProgressChange = newValue }
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
        // Reported as it is, whichever engine it came from. A Readr Voice
        // failure used to be re-spoken through the Apple voice under the
        // same id; now it pauses narration on the sentence with the bar
        // saying why and offering Retry — the reader decides, not a
        // fallback.
        delegate?.speechEngine(self, didFail: requestID, error: error)
    }

    func speechEngine(_ engine: any SpeechEngine, isPreparing requestID: UUID) {
        guard engine === current else { return }
        delegate?.speechEngine(self, isPreparing: requestID)
    }

    func speechEngine(_ engine: any SpeechEngine, didBeginSpeaking requestID: UUID) {
        guard engine === current else { return }
        delegate?.speechEngine(self, didBeginSpeaking: requestID)
    }
}
