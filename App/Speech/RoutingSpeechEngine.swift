import Foundation
import ReadrKit

/// Routes narration only to the platform's Kokoro runtime. A missing/failed
/// engine reports a recoverable failure; it never constructs a system TTS
/// synthesizer. The selected engine alone may advance the active utterance.
final class RoutingSpeechEngine: SpeechEngine, SpeechPrefetching, SpeechRateAdjusting, NarrationVoiceCataloguing {
    weak var delegate: (any SpeechEngineDelegate)?

    /// Built on macOS only, and only outside the BNNS crash gate. iOS is
    /// MLX-only: CoreML Kokoro is never constructed there, so an
    /// iOS 18–26.3 device or simulator (which pass the gate) never prepares
    /// or enters it.
    private let coreML: KokoroSpeechEngine?
    #if os(iOS)
    /// Nil where MLX cannot run (the simulator, no Metal GPU) — the router
    /// then reports that neural narration is unavailable.
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
        // iOS is MLX-only. `KokoroSpeechEngine.isSupportedOnThisOS`
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

    init() {
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
        coreML?.delegate = self
        #if os(iOS)
        mlx?.delegate = self
        #endif
    }

    func voices(for language: String) -> [SpeechVoice] {
        guard readrVoiceRuntime != nil, KokoroSpeechEngine.supports(language: language) else { return [] }
        return [KokoroSpeechEngine.pickerVoice]
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
        guard KokoroSpeechEngine.supports(language: request.language ?? "en") else {
            refuse(request, message: "Readr Voice currently supports English narration. This book's language is not supported.")
            return
        }
        switch NarrationEnginePolicy.engine(for: situation(for: request)) {
        case .coreMLKokoro:
            guard let coreML else { refuse(request); return }
            target = coreML
        case .mlxKokoro:
            #if os(iOS)
            guard let mlx else { refuse(request); return }
            target = mlx
            #else
            refuse(request); return
            #endif
        case .platform, .unavailable:
            refuse(request); return
        }
        // Switching engines mid-flight: silence the one being left, so two
        // voices never overlap.
        if let current, current !== target {
            current.stop()
        }
        current = target
        target.speak(request)
    }

    private func refuse(_ request: SpeechRequest, message: String = "Readr Voice is unavailable. Retry the voice download on a supported device.") {
        current?.stop()
        current = nil
        delegate?.speechEngine(self, didFail: request.id, error: NeuralNarrationError(message: message))
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
        coreML?.stop()
        #if os(iOS)
        mlx?.stop()
        #endif
    }

    // MARK: - Synthesizing ahead

    /// The controller's lookahead goes to whichever Kokoro engine the policy
    /// would give each sentence to — in practice the MLX engine on iOS,
    /// which keeps a buffer; the CoreML engine synthesizes as it goes and
    /// gets nothing. Unsupported requests are never prepared by another voice.
    func prefetch(_ requests: [SpeechRequest]) {
        #if os(iOS)
        guard let mlx else { return }
        let forMLX = requests.filter {
            NarrationEnginePolicy.engine(for: situation(for: $0)) == .mlxKokoro
        }
        mlx.prefetch(forMLX)
        #endif
    }

    func secondsBuffered(ahead requests: [SpeechRequest]) -> TimeInterval {
        #if os(iOS)
        return mlx?.secondsBuffered(ahead: requests) ?? 0
        #else
        return 0
        #endif
    }

    /// A speed change goes to the engine on the current sentence; only one
    /// that can change speed in place says yes.
    func adjustRate(_ rate: Double) -> Bool {
        (current as? SpeechRateAdjusting)?.adjustRate(rate) ?? false
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

    func speechEngine(
        _ engine: any SpeechEngine, didSuspend requestID: UUID, reason: NarrationHoldReason
    ) {
        guard engine === current else { return }
        delegate?.speechEngine(self, didSuspend: requestID, reason: reason)
    }
}

private struct NeuralNarrationError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
