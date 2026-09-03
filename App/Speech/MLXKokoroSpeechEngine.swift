#if os(iOS)
import Foundation
import AVFoundation
import Metal
import UIKit
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioTTS
import ReadrKit

/// "Readr Voice" on iPhone and iPad: the same Kokoro-82M as
/// `KokoroSpeechEngine`, run on the Metal GPU through MLX
/// (Blaizzy/mlx-audio-swift) instead of CoreML. On iOS 26.4+ Apple's CoreML
/// CPU path segfaults inside libBNNS during Kokoro inference — uncatchable,
/// three App Store crash logs, FluidAudio#817/#844 — and MLX never touches
/// BNNS. See docs/research/MLX-KOKORO-IOS.md for the decision and the
/// alternatives that lost.
///
/// Same shape and contract as the CoreML engine: synthesize the whole
/// sentence, play it with `AVAudioPlayer`, report `.speaking` through the
/// synthesis/download gap so the controller's silent-engine watchdog holds
/// off, `didFail` on any error so `RoutingSpeechEngine`'s platform fallback
/// re-speaks the sentence through the Apple voice. Main-thread-confined;
/// synthesis hops to the `Synthesizer` actor and back.
///
/// Two things are different, and both are Metal's rules, not ours:
///
/// - **No GPU work from the background.** Metal refuses command buffers
///   from a backgrounded or locked app, and MLX surfaces that as a C++
///   `runtime_error` thrown inside Metal's completion handler — a
///   `std::terminate`, not something Swift can catch (mlx-swift#274, #407).
///   So this engine never *starts* GPU work unless the app is active:
///   `isForeground` flips false on `willResignActive` (which fires before
///   the lock, ahead of `didEnterBackground`) and the router reads it per
///   sentence through `NarrationEnginePolicy`, handing the sentence to the
///   Apple voice instead. The weights are loaded onto the GPU only in the
///   foreground too — a first-use download that finishes with the phone in
///   a pocket waits for the reader to come back. What remains is the
///   sub-second window of a synthesis already in flight when the lock
///   happens; the `do/catch` and timeout below cover every failure that
///   *is* catchable, and the smoke test exercises the rest on a device.
/// - **No simulator.** MLX cannot run on the iOS Simulator at all
///   (mlx#2605); `isAvailableOnThisDevice` is false there, this engine is
///   never constructed, and the router keeps its CoreML/platform behaviour.
///   Nothing here touches MLX before `prepare()` — `init` observes two
///   notifications and nothing else — so a launch, and the UI tests'
///   `-uiTestSilentNarration` stub, never load the runtime.
final class MLXKokoroSpeechEngine: NSObject, ReadrVoiceEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    /// Kokoro-82M weights and voice packs, ~327MB, Apache-2.0. Fetched once
    /// from Hugging Face on first use into the app's Caches directory (the
    /// package's `HubCache.default`); PRIVACY.md discloses the fetch.
    static let weightsRepo = "mlx-community/Kokoro-82M-bf16"
    /// The G2P assets `MisakiTextProcessor` fetches for itself, ~20MB, MIT:
    /// the Misaki gold+silver lexicon and a 3MB BART fallback that runs on
    /// MLX — no espeak, no CoreML. Named here so the privacy text can name
    /// every host the app talks to.
    static let g2pRepo = "beshkenadze/kitten-tts-g2p"

    /// Kokoro refuses more than 510 phonemes per call; a synthesis over this
    /// long has hung, not stalled, and the sentence goes to the Apple voice.
    static let synthesisTimeout: TimeInterval = 30

    /// MLX's buffer pool grows towards Metal's recommended working set —
    /// several GB on a Mac and a jetsam on a phone (a Kokoro port measured a
    /// 3GB cache; mlx-swift's own iOS sample uses 20MB). 64MB comfortably
    /// covers one sentence's intermediates.
    static let gpuCacheLimit = 64 * 1024 * 1024

    // MARK: - Availability

    /// Evaluated once per process. False on the simulator (mlx#2605) and on
    /// a device with no Metal GPU; nothing here loads MLX.
    static let isAvailableOnThisDevice: Bool = {
        #if targetEnvironment(simulator)
        DiagnosticsLog.shared.record(
            .warning, .reader, "Readr Voice (MLX) unavailable: the iOS Simulator cannot run MLX"
        )
        return false
        #else
        guard MTLCreateSystemDefaultDevice() != nil else {
            DiagnosticsLog.shared.record(
                .warning, .reader, "Readr Voice (MLX) unavailable: no Metal device"
            )
            return false
        }
        return true
        #endif
    }()

    // MARK: - Readiness

    typealias Readiness = ReadrVoiceReadiness

    private(set) var readiness: Readiness = MLXKokoroSpeechEngine.isAvailableOnThisDevice
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

    // MARK: - Foreground

    /// The app is active, so Metal will accept GPU work. Read by the router
    /// per sentence; false from `willResignActive` (ahead of the lock and of
    /// `didEnterBackground`) until `didBecomeActive`. Conservative on
    /// purpose: a Control Center pull or an incoming call also hands one
    /// sentence to the Apple voice, which is cheap; a GPU refusal is not.
    private(set) var isForeground: Bool
    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: - State

    private let synthesizer = Synthesizer()
    private var initializeTask: Task<Void, Error>?
    private var player: AVAudioPlayer?
    /// The request being synthesized or played. Non-nil is what makes `state`
    /// report `.speaking` through the synthesis gap.
    private var activeRequest: SpeechRequest?
    private var synthesisTask: Task<Void, Never>?
    /// The controller paused while we were still synthesizing — hold the
    /// finished audio instead of starting it.
    private var pausedByCaller = false

    override init() {
        // Main-thread-confined, like every engine; the model that builds the
        // router is @MainActor, which is what makes this assumption safe.
        isForeground = MainActor.assumeIsolated {
            UIApplication.shared.applicationState == .active
        }
        super.init()
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.isForeground = false },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.isForeground = true },
        ]
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var state: SpeechEngineState {
        guard activeRequest != nil else { return .idle }
        if pausedByCaller { return .paused }
        if let player {
            // The player's own state, not ours — an audio interruption pauses
            // an AVAudioPlayer silently (see KokoroSpeechEngine.state).
            return player.isPlaying ? .speaking : .paused
        }
        return .speaking
    }

    // MARK: - SpeechEngine

    func speak(_ request: SpeechRequest) {
        // The router already routes a backgrounded sentence to the platform
        // voice; this is the engine refusing on its own account, so no
        // caller can start GPU work with the screen locked.
        guard readiness != .unsupported, isForeground else {
            let error: any Error = isForeground
                ? SpeechEngineError.audioUnavailable as any Error
                : MLXKokoroError.backgrounded as any Error
            delegate?.speechEngine(self, didFail: request.id, error: error)
            return
        }
        cancelInFlight()
        activeRequest = request
        pausedByCaller = false
        synthesisTask = Task { @MainActor [weak self] in
            await self?.synthesizeThenPlay(request)
        }
    }

    func pause() {
        pausedByCaller = true
        player?.pause()
    }

    func resume() {
        pausedByCaller = false
        // With no player yet (paused mid-synthesis), synthesizeThenPlay
        // starts playback itself once the audio lands.
        guard let player else { return }
        if !player.play(), let request = activeRequest {
            // A refused start is a failure, not a silent no-op the watchdog
            // has to discover two ticks later.
            self.player = nil
            activeRequest = nil
            delegate?.speechEngine(
                self, didFail: request.id, error: SpeechEngineError.audioUnavailable
            )
        }
    }

    func stop() {
        cancelInFlight()
        activeRequest = nil
        pausedByCaller = false
        // The audio session stays up between sentences; the router's
        // `endAudioSession()` ends it for real.
    }

    /// Start the download and (in the foreground) the GPU load without
    /// speaking — called when the reader picks this voice.
    func prepare() {
        guard readiness != .unsupported else { return }
        Task { @MainActor [weak self] in
            try? await self?.ensureInitialized()
        }
    }

    // MARK: - Synthesis

    @MainActor
    private func synthesizeThenPlay(_ request: SpeechRequest) async {
        do {
            try await ensureInitialized()
            // A skip/stop may have replaced this request during the wait.
            guard activeRequest?.id == request.id else { return }
            // Re-checked after the wait: a first-use download is minutes
            // long, and the phone may have been locked meanwhile.
            guard isForeground else { throw MLXKokoroError.backgrounded }
            let voice = KokoroSpeechEngine.kokoroVoice(from: request.voiceID)
            // Kokoro takes the reader's multiplier directly (already clamped
            // by SpeechSettings, the single clamping authority).
            let speed = Float(request.rate)
            let text = request.text
            let synthesizer = self.synthesizer
            let wav = try await withTimeout(seconds: Self.synthesisTimeout) {
                try await synthesizer.synthesize(text: text, voice: voice, speed: speed)
            }
            guard activeRequest?.id == request.id else { return }
            // Claimed only once audio is ready to play, so a first-use
            // download doesn't interrupt whatever the reader was listening to.
            NarrationAudioSession.activate()
            let player = try AVAudioPlayer(data: wav)
            player.volume = Float(request.volume)
            player.delegate = self
            self.player = player
            if pausedByCaller {
                player.prepareToPlay()
            } else if !player.play() {
                // The session refused to start audio; pretending to speak
                // would wedge narration on a silent "playing".
                self.player = nil
                activeRequest = nil
                delegate?.speechEngine(
                    self, didFail: request.id, error: SpeechEngineError.audioUnavailable
                )
            }
        } catch is CancellationError {
            // A skip/stop cancelled us; the controller already moved on.
        } catch {
            guard activeRequest?.id == request.id else { return }
            activeRequest = nil
            player = nil
            DiagnosticsLog.shared.record(
                .warning, .reader, "Readr Voice (MLX) could not speak a sentence", error: error
            )
            delegate?.speechEngine(self, didFail: request.id, error: error)
        }
    }

    @MainActor
    private func ensureInitialized() async throws {
        guard readiness != .unsupported else {
            throw SpeechEngineError.audioUnavailable
        }
        if let initializeTask {
            return try await initializeTask.value
        }
        readiness = .downloading
        let synthesizer = self.synthesizer
        let task = Task { [weak self] in
            // Network first, GPU second, and never the GPU with the screen
            // locked: the download is safe anywhere, the load is not.
            try await synthesizer.download()
            try await self?.waitUntilForeground()
            try await synthesizer.load()
        }
        initializeTask = task
        do {
            try await task.value
            readiness = .ready
        } catch {
            // A failed download must not poison every later attempt.
            initializeTask = nil
            readiness = .failed
            throw error
        }
    }

    @MainActor
    private func waitUntilForeground() async throws {
        while !isForeground {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func cancelInFlight() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
    }

    // MARK: - The model, off the main thread

    /// Owns the MLX model. An actor so the download, the load and every
    /// synthesis run off the main thread and one at a time.
    private actor Synthesizer {
        private let textProcessor = MisakiTextProcessor()
        private var modelDirectory: URL?
        private var model: KokoroModel?

        /// Weights and G2P assets onto disk. No MLX involved.
        func download() async throws {
            guard let repo = Repo.ID(rawValue: MLXKokoroSpeechEngine.weightsRepo) else {
                throw MLXKokoroError.invalidRepository(MLXKokoroSpeechEngine.weightsRepo)
            }
            modelDirectory = try await ModelUtils.resolveOrDownloadModel(
                repoID: repo, requiredExtension: "safetensors"
            )
            try await textProcessor.prepare()
        }

        /// Weights onto the GPU. Foreground only — see the type comment.
        func load() async throws {
            guard model == nil else { return }
            guard let modelDirectory else { throw MLXKokoroError.notDownloaded }
            // Before the first allocation, so the pool never grows past it.
            Memory.cacheLimit = MLXKokoroSpeechEngine.gpuCacheLimit
            model = try await KokoroModel.fromModelDirectory(
                modelDirectory, textProcessor: textProcessor
            )
        }

        /// A whole sentence as 16-bit WAV, ready for `AVAudioPlayer`.
        func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
            guard let model else { throw MLXKokoroError.notLoaded }
            model.speed = speed
            let samples = try await samples(for: text, voice: voice, model: model)
            return PCMWAVEncoder.data(samples: samples, sampleRate: model.sampleRate)
        }

        /// The segmenter caps sentences at 320 characters, which keeps nearly
        /// every one under Kokoro's 510-phoneme limit; the rest are cut at a
        /// clause and synthesized in pieces.
        private func samples(
            for text: String, voice: String, model: KokoroModel
        ) async throws -> [Float] {
            do {
                let audio = try await model.generate(
                    text: text, voice: voice, refAudio: nil, refText: nil,
                    language: "en-us",
                    generationParameters: model.defaultGenerationParameters
                )
                return audio.asArray(Float.self)
            } catch AudioGenerationError.invalidInput(let message)
                where message.hasPrefix("Input too long") && text.count > 40 {
                let pieces = ClauseSplitter.split(text, maxLength: max(40, (text.count + 1) / 2))
                var joined: [Float] = []
                for piece in pieces {
                    joined += try await samples(for: piece, voice: voice, model: model)
                }
                return joined
            }
        }
    }
}

// MARK: - Errors

enum MLXKokoroError: Error, LocalizedError {
    /// The app is not active; Metal would refuse the GPU work.
    case backgrounded
    case timedOut(TimeInterval)
    case invalidRepository(String)
    case notDownloaded
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .backgrounded:
            return "Readr Voice cannot synthesize while the app is in the background"
        case .timedOut(let seconds):
            return "Readr Voice synthesis exceeded \(Int(seconds))s"
        case .invalidRepository(let repo):
            return "Invalid model repository id: \(repo)"
        case .notDownloaded:
            return "Readr Voice model has not been downloaded"
        case .notLoaded:
            return "Readr Voice model has not been loaded"
        }
    }
}

/// The first of `work` or a timer to finish wins. A synthesis that runs past
/// the timer keeps running (MLX has no mid-graph cancellation) but the caller
/// stops waiting for it and falls back; the actor serializes the next call
/// behind it.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MLXKokoroError.timedOut(seconds)
        }
        guard let first = try await group.next() else {
            throw MLXKokoroError.timedOut(seconds)
        }
        group.cancelAll()
        return first
    }
}

// MARK: - AVAudioPlayerDelegate

extension MLXKokoroSpeechEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onNarrationMain { [weak self] in
            guard let self, player === self.player,
                  let request = self.activeRequest else { return }
            self.player = nil
            self.activeRequest = nil
            if flag {
                self.delegate?.speechEngine(self, didFinish: request.id)
            } else {
                // Playback died partway; a failure holds narration in place
                // rather than advancing past text the listener never heard.
                self.delegate?.speechEngine(
                    self, didFail: request.id, error: SpeechEngineError.audioUnavailable
                )
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onNarrationMain { [weak self] in
            guard let self, player === self.player,
                  let request = self.activeRequest else { return }
            self.player = nil
            self.activeRequest = nil
            self.delegate?.speechEngine(
                self, didFail: request.id,
                error: error ?? SpeechEngineError.audioUnavailable
            )
        }
    }
}
#endif
