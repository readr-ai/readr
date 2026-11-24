import Foundation
import AVFoundation
import FluidAudio
import ReadrKit

/// "Readr Voice": Kokoro-82M neural narration behind ReadrKit's
/// `SpeechEngine` protocol, via FluidAudio's CoreML port (Apache-2.0,
/// espeak-free G2P). See docs/ROADMAP.md M10 — the A/B listen chose Kokoro
/// over the platform voices decisively.
///
/// The DEFAULT narrator for English books since v3.2.0 (an explicitly chosen
/// platform voice still wins, and non-English books keep the platform
/// voices). The ~104MB model downloads automatically on the first Listen —
/// PRIVACY.md and the store copy disclose that one fixed-CDN fetch — and
/// until it's in, `RoutingSpeechEngine` narrates through the platform voice
/// and switches over at a sentence boundary. The router is also the failure
/// story: any post-ready synthesis fault re-routes that sentence to the
/// platform voice rather than pausing narration.
///
/// Shape: synthesize the whole sentence (Kokoro is not a streaming engine —
/// 100–250ms for a typical sentence on Apple silicon), then play it with
/// `AVAudioPlayer`. While synthesis or the model download is in flight the
/// engine reports `.speaking`, so `NarrationController`'s silent-engine
/// watchdog doesn't mistake the wait for a finished utterance. No word
/// boundaries are reported yet (`predictedDurations` maps token→time, but
/// mapping tokens back to character ranges is real work, tracked in M10) —
/// the page still follows per sentence; only mid-sentence resume precision
/// degrades to the sentence start.
///
/// Main-thread-confined like `AVSpeechEngine`; synthesis hops to the
/// `KokoroAneManager` actor and back, and playback is `SentenceAudioPlayer`,
/// the one `AVAudioPlayer` contract both Kokoro engines share.
///
/// macOS only: `RoutingSpeechEngine` builds this engine on macOS alone. On
/// iPhone and iPad Readr Voice is MLX or nothing (`MLXKokoroSpeechEngine`;
/// CoreML crashes inside Apple's BNNS on iOS 26.4+), so the CoreML path is
/// never prepared or entered there — not even on the iOS 18–26.3 builds
/// that pass the BNNS gate.
final class KokoroSpeechEngine: NSObject, ReadrVoiceEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    // MARK: - The picker's view of this engine

    /// Evaluated once per process. FluidAudio's Kokoro path can crash inside
    /// Apple's BNNS runtime on affected OS builds, so it must never be entered
    /// there; the signal cannot be caught and compute-unit routing does not
    /// avoid it (FluidAudio #817/#844).
    static let isSupportedOnThisOS: Bool = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let onMacOS = true
        let platform = "macOS"
        #else
        let onMacOS = false
        let platform = "iOS/iPadOS"
        #endif
        let isSupported = !NeuralVoiceAvailability.isCrashProneOS(
            major: version.majorVersion,
            minor: version.minorVersion,
            onMacOS: onMacOS
        )
        if !isSupported {
            let versionText = "\(version.majorVersion).\(version.minorVersion)"
            DiagnosticsLog.shared.record(
                .warning, .reader,
                "Readr Voice disabled on \(platform) \(versionText): Apple BNNS crash-prone OS"
            )
        }
        return isSupported
    }()

    /// Sentinel voice-id namespace. Nothing AVFoundation could ever report
    /// collides with it, which is what routes a request here (see
    /// `RoutingSpeechEngine`) and what `NarrationModel` special-cases when
    /// honouring a stored choice.
    static let voiceIDPrefix = "readr.voice.kokoro."
    static let defaultVoiceID = voiceIDPrefix + "af_heart"

    static func isKokoroVoiceID(_ id: String?) -> Bool {
        id?.hasPrefix(voiceIDPrefix) == true
    }

    /// The row the voice picker shows.
    static let pickerVoice = SpeechVoice(
        id: defaultVoiceID,
        name: "Readr Voice",
        language: "en-US",
        quality: .premium,
        family: .modern
    )

    /// English only for now: af_heart is an English voice, and the spike only
    /// validated the espeak-free G2P path for English. Primary-subtag equality
    /// via ReadrKit's own normalization — a prefix test also matched
    /// three-letter codes like `enm` (Middle English).
    static func supports(language: String?) -> Bool {
        guard let language else { return false }
        return SpeechVoice.primaryLanguageCode(of: language) == "en"
    }

    /// Kokoro voice-pack name from a sentinel id ("af_heart"). Shared with the
    /// MLX engine: the sentinel ids are the same whichever runtime speaks.
    static func kokoroVoice(from id: String?) -> String {
        guard let id, isKokoroVoiceID(id) else { return "af_heart" }
        return String(id.dropFirst(voiceIDPrefix.count))
    }

    // MARK: - Readiness

    /// Where the voice stands between "picked" and "audible": the model is a
    /// ~104MB first-use download, and the Listen bar shows this so the wait
    /// is never silent. While it isn't `.ready`, `RoutingSpeechEngine` narrates
    /// through the platform voice and switches over at a sentence boundary.
    /// `.unsupported` here means this OS build crashes the process inside
    /// Apple's BNNS during Kokoro inference (FluidAudio#817/#844); the engine
    /// refuses every request. See `NeuralVoiceAvailability`.
    typealias Readiness = ReadrVoiceReadiness

    private(set) var readiness: Readiness = KokoroSpeechEngine.isSupportedOnThisOS
        ? .notReady : .unsupported {
        didSet {
            guard readiness != oldValue else { return }
            onReadinessChange?(readiness)
        }
    }
    /// Fires on the main thread (readiness only changes inside @MainActor
    /// paths); the model publishes it to the Listen bar.
    var onReadinessChange: ((Readiness) -> Void)?
    var isReady: Bool { readiness == .ready }
    /// FluidAudio's download reports no progress; the bar shows the wait as
    /// indeterminate with the size.
    let downloadProgress: Double? = nil
    var onDownloadProgressChange: ((Double?) -> Void)?

    // MARK: - State

    private let manager = KokoroAneManager()
    private var initializeTask: Task<Void, Error>?
    /// Playback, shared with the MLX engine: `SentenceAudioPlayer` owns the
    /// `AVAudioPlayer`, the active request and the pause flag, and reports
    /// through the two hooks wired in `init`.
    private let audio = SentenceAudioPlayer()

    override init() {
        super.init()
        audio.onFinish = { [weak self] id in
            guard let self else { return }
            self.delegate?.speechEngine(self, didFinish: id)
        }
        audio.onFail = { [weak self] id, error in
            guard let self else { return }
            self.delegate?.speechEngine(self, didFail: id, error: error)
        }
        audio.onStart = { [weak self] id in
            guard let self else { return }
            self.delegate?.speechEngine(self, didBeginSpeaking: id)
        }
    }

    var state: SpeechEngineState { audio.state }

    // MARK: - SpeechEngine

    func speak(_ request: SpeechRequest) {
        guard readiness != .unsupported else {
            delegate?.speechEngine(
                self, didFail: request.id, error: SpeechEngineError.audioUnavailable
            )
            return
        }
        // Not in yet: the sentence waits for the download (started below if
        // it hasn't been), and the bar shows the wait rather than an Apple
        // voice reading meanwhile.
        if readiness != .ready {
            delegate?.speechEngine(self, isPreparing: request.id)
        }
        audio.speak(request) { [weak self] request in
            guard let self else { throw CancellationError() }
            try await self.ensureInitialized()
            // A skip/stop may have replaced this request during the wait.
            guard self.audio.isCurrent(request) else { throw CancellationError() }
            return .data(try await self.manager.synthesize(
                text: request.text,
                voice: Self.kokoroVoice(from: request.voiceID),
                // Kokoro takes the reader's multiplier directly — no
                // platform-rate curve like AVFoundation's. Already in range:
                // SpeechSettings is the single clamping authority (init,
                // didSet, and decode), and every request is built from it.
                speed: Float(request.rate)
            ))
        }
    }

    func pause() {
        audio.pause()
    }

    func resume() {
        audio.resume()
        // Resumed into the same wait: say so again, since the pause took
        // the controller out of its preparing state.
        if readiness != .ready, let request = audio.activeRequest {
            delegate?.speechEngine(self, isPreparing: request.id)
        }
    }

    func stop() {
        audio.stop()
    }

    /// Start the model download/load without speaking — the explicit pick,
    /// and the Retry after a failure. Main-thread-confined like the rest of
    /// the engine; `readiness` leaves `.failed` before this returns.
    func prepare() {
        guard readiness != .unsupported else { return }
        MainActor.assumeIsolated {
            _ = startInitializing()
        }
    }

    // MARK: - Initialization

    @MainActor
    private func ensureInitialized() async throws {
        guard readiness != .unsupported else {
            throw SpeechEngineError.audioUnavailable
        }
        try await startInitializing().value
    }

    /// The download, started at most once at a time. Readiness moves to
    /// `.downloading` synchronously so a request routed in the same turn as
    /// a Retry sees an engine that is trying; the outcome is bookkept on
    /// the main actor when the task ends.
    @MainActor
    private func startInitializing() -> Task<Void, Error> {
        if let initializeTask { return initializeTask }
        readiness = .downloading
        let task = Task { try await manager.initialize() }
        initializeTask = task
        Task { @MainActor [weak self] in
            do {
                try await task.value
                self?.readiness = .ready
            } catch {
                // A failed download must not poison every later attempt.
                guard let self, self.initializeTask == task else { return }
                self.initializeTask = nil
                self.readiness = .failed
                DiagnosticsLog.shared.recordVoiceLoadFailure(
                    runtime: "CoreML", inForeground: true, error: error
                )
            }
        }
        return task
    }
}
