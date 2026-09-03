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
/// Same shape and contract as the CoreML engine — playback is the shared
/// `SentenceAudioPlayer`: synthesize the whole sentence, play it with
/// `AVAudioPlayer`, report `.speaking` through the synthesis/download gap so
/// the controller's silent-engine watchdog holds off, `didFail` on any error
/// so `RoutingSpeechEngine`'s platform fallback re-speaks the sentence
/// through the Apple voice. Main-thread-confined; synthesis hops to the
/// `Synthesizer` actor and back.
///
/// Two things are different, and both are Metal's rules, not ours:
///
/// - **No GPU work from the background.** Metal refuses command buffers
///   from a backgrounded app, and MLX surfaces that as a C++
///   `runtime_error` thrown inside Metal's completion handler — a
///   `std::terminate`, not something Swift can catch (mlx-swift#274, #407).
///   So this engine never *starts* GPU work unless `isForeground` — "not
///   backgrounded", see that property for exactly what that means — and the
///   router reads the same flag per sentence through
///   `NarrationEnginePolicy`, handing the sentence to the Apple voice
///   instead. The weights are loaded onto the GPU only in the foreground
///   too — a first-use download that finishes with the phone in a pocket
///   waits for the reader to come back. What remains is the sub-second
///   window of a synthesis already in flight when the lock happens; the
///   `do/catch` and the deadline below cover every failure that *is*
///   catchable, and the smoke test exercises the rest on a device.
/// - **No simulator.** MLX cannot run on the iOS Simulator at all
///   (mlx#2605); `isAvailableOnThisDevice` is false there, this engine is
///   never constructed, and the router narrates through the platform voice.
///   Nothing here touches MLX before `prepare()` — `init` observes four
///   notifications and nothing else — so a launch, and the UI tests'
///   `-uiTestSilentNarration` stub, never load the runtime.
final class MLXKokoroSpeechEngine: NSObject, ReadrVoiceEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    /// Kokoro-82M weights (~330MB) and voice packs (~60MB), Apache-2.0.
    /// Fetched once from Hugging Face on first use into the app's Caches
    /// directory (the package's `HubCache.default`, which keeps a hub blob
    /// cache AND a working copy — up to twice the size on disk until iOS
    /// purges the cache); PRIVACY.md discloses the fetch.
    static let weightsRepo = "mlx-community/Kokoro-82M-bf16"
    /// The G2P assets `MisakiTextProcessor` fetches for itself, ~20MB, MIT:
    /// the Misaki gold+silver lexicon and a 3MB BART fallback that runs on
    /// MLX — no espeak, no CoreML. Named here so the privacy text can name
    /// every host the app talks to.
    static let g2pRepo = "beshkenadze/kitten-tts-g2p"

    /// Kokoro refuses more than 510 phonemes per call; a synthesis over this
    /// long has hung, not stalled. The sentence goes to the Apple voice and
    /// the engine marks itself `.failed` — see `synthesize`.
    static let synthesisTimeout: TimeInterval = 30

    /// MLX keeps freed buffers in a pool for reuse and lets that pool grow
    /// towards Metal's recommended working set — several GB on a Mac and a
    /// jetsam on a phone (a Kokoro port measured a 3GB cache; mlx-swift's
    /// own iOS sample uses 20MB). `Memory.cacheLimit` bounds that FREE
    /// buffer cache only — memory not in use, kept rather than returned to
    /// the system — not resident memory: the weights and a sentence's live
    /// intermediates are unaffected. 64MB comfortably covers one sentence's
    /// worth of reusable buffers. (`Memory.memoryLimit`, the allocation
    /// ceiling, stays at its default of 1.5× the recommended working set.)
    static let gpuCacheLimit = 64 * 1024 * 1024

    /// Spoken once, in the foreground, right after the load and thrown
    /// away: `KokoroModel.fromModelDirectory` re-runs the G2P's `prepare()`,
    /// the Misaki lexicons and the BART fallback are built lazily on the
    /// first `process`, and Metal compiles the model's kernels on first use.
    /// Paying for all of that here means the first real sentence carries
    /// none of it.
    static let warmUpText = "Ready."

    /// How long a `willResignActive` counts as "about to be backgrounded".
    /// The lock sends `willResignActive` and then `didEnterBackground`
    /// within a few hundred milliseconds; Control Center, a notification
    /// banner and an incoming call send `willResignActive` alone. After this
    /// long with no `didEnterBackground`, the app is taken to be still in
    /// the foreground.
    static let resignGracePeriod: TimeInterval = 1.5

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

    /// Byte-weighted fraction of the weights download, from the hub client;
    /// nil before it starts, once it ends (the G2P assets, the load and the
    /// warm-up that follow are short and indeterminate), and outside
    /// `.downloading`.
    private(set) var downloadProgress: Double? {
        didSet {
            guard downloadProgress != oldValue else { return }
            onDownloadProgressChange?(downloadProgress)
        }
    }
    var onDownloadProgressChange: ((Double?) -> Void)?

    // MARK: - Foreground

    /// The app is NOT backgrounded, so Metal will accept GPU work. Read by
    /// the router per sentence and by the actor before every load.
    ///
    /// "Not backgrounded" rather than "active", deliberately. Only a
    /// backgrounded app is refused the GPU; `willResignActive` also fires
    /// for Control Center, a notification banner, an incoming call and — on
    /// iPad — every time focus moves to the other Split View or Stage
    /// Manager app, and Metal accepts work in all of those. Keying on
    /// "active" handed every one of those sentences to the Apple voice for
    /// nothing, and on an iPad in Split View it did so for as long as the
    /// reader was typing next door. So the flag is false from
    /// `didEnterBackground` until `willEnterForeground`.
    ///
    /// Plus a head start for the lock: `didEnterBackground` arrives a few
    /// hundred milliseconds after `willResignActive`, and a synthesis
    /// started in that gap would be in flight when the GPU goes away. So
    /// `willResignActive` also makes this false, until `didBecomeActive` —
    /// or, if no `didEnterBackground` follows within `resignGracePeriod`
    /// (the Control Center case), on its own.
    var isForeground: Bool { foreground.isForeground }
    /// Thread-safe so the actor can re-check it from its own thread right
    /// before the first Metal call. The main thread is the only writer.
    private let foreground: ForegroundGate
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var resignGrace: Task<Void, Never>?

    // MARK: - State

    private let synthesizer = Synthesizer()
    private var initializeTask: Task<Void, Error>?
    /// Playback, shared with the CoreML engine.
    private let audio = SentenceAudioPlayer()

    override init() {
        // Main-thread-confined, like every engine; the model that builds the
        // router is @MainActor, which is what makes this assumption safe.
        let backgrounded = MainActor.assumeIsolated {
            UIApplication.shared.applicationState == .background
        }
        foreground = ForegroundGate(backgrounded: backgrounded)
        super.init()
        audio.onFinish = { [weak self] id in
            guard let self else { return }
            self.delegate?.speechEngine(self, didFinish: id)
        }
        audio.onFail = { [weak self] id, error in
            guard let self else { return }
            DiagnosticsLog.shared.record(
                .warning, .reader, "Readr Voice (MLX) could not speak a sentence", error: error
            )
            self.delegate?.speechEngine(self, didFail: id, error: error)
        }
        audio.onStart = { [weak self] id in
            guard let self else { return }
            self.delegate?.speechEngine(self, didBeginSpeaking: id)
        }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.didEnterBackground() },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.willEnterForeground() },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.willResignActive() },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.didBecomeActive() },
        ]
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        resignGrace?.cancel()
        // A download still in flight for an engine nobody owns must not go
        // on to load the weights onto the GPU: cancel it, and wake any wait
        // for the foreground with a cancellation so the task ends there.
        initializeTask?.cancel()
        foreground.cancelWaiters()
    }

    private func didEnterBackground() {
        resignGrace?.cancel()
        resignGrace = nil
        foreground.update(backgrounded: true, resigning: false)
    }

    private func willEnterForeground() {
        foreground.update(backgrounded: false)
    }

    private func willResignActive() {
        foreground.update(resigning: true)
        resignGrace?.cancel()
        resignGrace = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.resignGracePeriod * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // No didEnterBackground followed: Control Center, a banner, a
            // call, a Split View neighbour. The GPU was ours all along.
            self.resignGrace = nil
            self.foreground.update(resigning: false)
        }
    }

    private func didBecomeActive() {
        resignGrace?.cancel()
        resignGrace = nil
        foreground.update(resigning: false)
    }

    var state: SpeechEngineState { audio.state }

    // MARK: - SpeechEngine

    func speak(_ request: SpeechRequest) {
        // The router already routes an unsupported or backgrounded sentence
        // to the platform voice; this is the engine refusing on its own
        // account, so no caller can start GPU work with the screen locked.
        guard readiness != .unsupported else {
            delegate?.speechEngine(self, didFail: request.id, error: MLXKokoroError.unsupported)
            return
        }
        guard isForeground else {
            delegate?.speechEngine(self, didFail: request.id, error: MLXKokoroError.backgrounded)
            return
        }
        // Not in yet: the sentence waits for the download and the load
        // (started in `synthesize` if they haven't been), and the bar shows
        // the wait rather than an Apple voice reading meanwhile.
        if readiness != .ready {
            delegate?.speechEngine(self, isPreparing: request.id)
        }
        audio.speak(request) { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.synthesize(request)
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

    /// Start the download and (in the foreground) the GPU load without
    /// speaking — the explicit pick, and the Retry after a failure. Main-
    /// thread-confined like the rest of the engine; `readiness` leaves
    /// `.failed` before this returns.
    func prepare() {
        guard readiness != .unsupported else { return }
        MainActor.assumeIsolated {
            _ = startInitializing()
        }
    }

    // MARK: - Synthesis

    /// The `synthesize` half of `SentenceAudioPlayer.speak`: wait for the
    /// model, re-check that the request and the foreground still stand, then
    /// synthesize against a deadline.
    @MainActor
    private func synthesize(_ request: SpeechRequest) async throws -> Data {
        try await ensureInitialized()
        // A skip/stop may have replaced this request during the wait.
        guard audio.isCurrent(request) else { throw CancellationError() }
        // Re-checked after the wait: a first-use download is minutes long,
        // and the phone may have been locked meanwhile.
        guard isForeground else { throw MLXKokoroError.backgrounded }
        let voice = KokoroSpeechEngine.kokoroVoice(from: request.voiceID)
        // Kokoro takes the reader's multiplier directly (already clamped by
        // SpeechSettings, the single clamping authority).
        let speed = Float(request.rate)
        let text = request.text
        let synthesizer = self.synthesizer
        do {
            // The first of the synthesis or the deadline wins; a synthesis
            // that runs past the deadline keeps running (MLX has no mid-graph
            // cancellation) but nobody is waiting for it any more, and its
            // late result is dropped inside the helper.
            return try await raceAgainstDeadline(seconds: Self.synthesisTimeout) {
                try await synthesizer.synthesize(text: text, voice: voice, speed: speed)
            }
        } catch let deadline as DeadlineExceeded {
            // The actor is wedged behind a call that will not return, or not
            // soon. Mark the engine sick: `.failed` takes it out of the
            // router's per-sentence choice, so every following sentence goes
            // straight to the Apple voice instead of queueing 30s behind the
            // wedged call. The voice menu's failure note ("pick it again to
            // retry") is the way back — the re-pick runs `ensureInitialized`
            // afresh, which waits its turn on the actor and returns at once
            // if the model is already loaded.
            readiness = .failed
            initializeTask = nil
            throw MLXKokoroError.timedOut(deadline.seconds)
        }
    }

    @MainActor
    private func ensureInitialized() async throws {
        guard readiness != .unsupported else { throw MLXKokoroError.unsupported }
        try await startInitializing().value
    }

    /// The download and the load, started at most once at a time. Readiness
    /// moves to `.downloading` synchronously so a request routed in the same
    /// turn as a Retry sees an engine that is trying; the outcome is
    /// bookkept on the main actor when the task ends.
    @MainActor
    private func startInitializing() -> Task<Void, Error> {
        if let initializeTask { return initializeTask }
        readiness = .downloading
        downloadProgress = nil
        let synthesizer = self.synthesizer
        let foreground = self.foreground
        let voice = KokoroSpeechEngine.kokoroVoice(from: nil)
        let task = Task { [weak self] in
            // Network first, GPU second, and never the GPU with the screen
            // locked: the download is safe anywhere, the load is not.
            try await synthesizer.download(voice: voice) { fraction in
                self?.downloadProgress = fraction
            }
            // An engine that was deallocated while the download ran has no
            // business loading anything.
            guard let self else { throw CancellationError() }
            await MainActor.run { self.downloadProgress = nil }
            // Readiness stays `.downloading` while this waits: the bar's
            // "Preparing Readr Voice" is still true of what the reader will
            // see, and narration starts the moment the load lands.
            try await foreground.waitUntilForeground()
            try await synthesizer.load(
                isForeground: { foreground.isForeground }, warmUpVoice: voice
            )
        }
        initializeTask = task
        Task { @MainActor [weak self] in
            do {
                try await task.value
                self?.readiness = .ready
            } catch {
                guard let self, self.initializeTask == task else { return }
                self.initializeTask = nil
                self.downloadProgress = nil
                // A failure with the app in the foreground is a failure, and
                // the reader retries from the bar. A failure while
                // backgrounded — the download dropped with the phone in a
                // pocket, or the load refused for want of the GPU — must not
                // poison the session: back to `.notReady`, and the next
                // sentence tries again.
                self.readiness = self.isForeground ? .failed : .notReady
            }
        }
        return task
    }

    // MARK: - The model, off the main thread

    /// Owns the MLX model. An actor so the download, the load and every
    /// synthesis run off the main thread and one at a time.
    private actor Synthesizer {
        private let textProcessor = MisakiTextProcessor()
        private var modelDirectory: URL?
        private var model: KokoroModel?

        /// Weights, voice packs and G2P assets onto disk. No MLX involved.
        ///
        /// The package fetches every `*.safetensors` in the repo (the glob
        /// is unanchored, so `voices/*.safetensors` are included) but its
        /// own "is the cache complete" check looks at the top level of the
        /// model directory only — an interrupted first download can leave a
        /// directory it considers complete with no voice packs in it. So
        /// after resolving, the files the load and the first synthesis will
        /// open are checked here; if one is missing, both the working copy
        /// and the hub cache are cleared and the download runs once more.
        func download(
            voice: String, progress: @escaping @MainActor @Sendable (Double) -> Void
        ) async throws {
            guard let repo = Repo.ID(rawValue: MLXKokoroSpeechEngine.weightsRepo) else {
                throw MLXKokoroError.invalidRepository(MLXKokoroSpeechEngine.weightsRepo)
            }
            var directory = try await Self.resolve(repo, progress: progress)
            if let missing = Self.missingFile(in: directory, voice: voice) {
                DiagnosticsLog.shared.record(
                    .warning, .reader,
                    "Readr Voice (MLX) download is missing \(missing); clearing and retrying once"
                )
                Self.clearCaches(modelDirectory: directory, repo: repo)
                directory = try await Self.resolve(repo, progress: progress)
                if let stillMissing = Self.missingFile(in: directory, voice: voice) {
                    throw MLXKokoroError.incompleteDownload(stillMissing)
                }
            }
            modelDirectory = directory
            try await textProcessor.prepare()
        }

        /// The package's resolve-or-download, with the hub client's
        /// byte-weighted snapshot progress passed through for the bar. A
        /// cached model reports nothing and returns at once.
        private static func resolve(
            _ repo: Repo.ID, progress: @escaping @MainActor @Sendable (Double) -> Void
        ) async throws -> URL {
            let cache = HubCache.default
            return try await ModelUtils.resolveOrDownloadModel(
                client: HubClient(cache: cache),
                cache: cache,
                repoID: repo,
                requiredExtension: "safetensors",
                progressHandler: { snapshot in
                    progress(min(1, max(0, snapshot.fractionCompleted)))
                }
            )
        }

        /// The first file the load or the first synthesis would fail to
        /// open, or nil when everything is there: the weights
        /// (`model.safetensors`, or any top-level `.safetensors` that isn't a
        /// voice pack — what `KokoroModel.loadWeights` accepts), the config,
        /// and the requested voice pack.
        static func missingFile(in directory: URL, voice: String) -> String? {
            func hasBytes(_ url: URL) -> Bool {
                ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
            }
            if !hasBytes(directory.appendingPathComponent("model.safetensors")) {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey]
                )) ?? []
                let anyWeights = files.contains {
                    $0.pathExtension == "safetensors"
                        && !$0.lastPathComponent.contains("voices") && hasBytes($0)
                }
                if !anyWeights { return "model.safetensors" }
            }
            if !hasBytes(directory.appendingPathComponent("config.json")) {
                return "config.json"
            }
            let pack = "voices/\(voice).safetensors"
            if !hasBytes(directory.appendingPathComponent(pack)) {
                return pack
            }
            return nil
        }

        /// What the package does for an incomplete top level, done for the
        /// files it doesn't look at: the working copy AND the hub blobs, or
        /// the retry would just copy the same incomplete snapshot back.
        private static func clearCaches(modelDirectory: URL, repo: Repo.ID) {
            try? FileManager.default.removeItem(at: modelDirectory)
            let hubDirectory = HubCache.default.repoDirectory(repo: repo, kind: .model)
            try? FileManager.default.removeItem(at: hubDirectory)
        }

        /// Weights onto the GPU, then one warm-up sentence. Foreground only —
        /// see the type comment. `isForeground` is asked again here, on the
        /// actor, immediately before the first Metal call, which narrows the
        /// check-then-act window to the hop itself.
        func load(isForeground: @Sendable () -> Bool, warmUpVoice: String) async throws {
            guard model == nil else { return }
            guard let modelDirectory else { throw MLXKokoroError.notDownloaded }
            guard isForeground() else { throw MLXKokoroError.backgrounded }
            // Before the first allocation, so the pool never grows past it.
            Memory.cacheLimit = MLXKokoroSpeechEngine.gpuCacheLimit
            let loaded = try await KokoroModel.fromModelDirectory(
                modelDirectory, textProcessor: textProcessor
            )
            model = loaded
            // The warm-up is GPU work too. If the app went to the background
            // during the load, skip it — the first real sentence pays the
            // lexicon parse and kernel compile instead, which is only slower.
            guard isForeground() else { return }
            _ = try await samples(for: MLXKokoroSpeechEngine.warmUpText, voice: warmUpVoice, model: loaded)
        }

        /// A whole sentence as 16-bit WAV, ready for `AVAudioPlayer`. EMPTY
        /// for a sentence that produces no samples at all (punctuation-only):
        /// the player reports that as finished rather than building a
        /// 44-byte WAV for AVAudioPlayer to reject.
        func synthesize(text: String, voice: String, speed: Float) async throws -> Data {
            guard let model else { throw MLXKokoroError.notLoaded }
            model.speed = speed
            let samples = try await samples(for: text, voice: voice, model: model)
            guard !samples.isEmpty else { return Data() }
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

// MARK: - Foreground gate

/// `isForeground` as a value any thread may read, plus the waits on it.
/// The engine's lifecycle observers (main thread) are the only writers.
private final class ForegroundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var backgrounded: Bool
    private var resigning = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    init(backgrounded: Bool) {
        self.backgrounded = backgrounded
    }

    var isForeground: Bool {
        lock.withLock { !backgrounded && !resigning }
    }

    /// Apply what changed, and if that made the app foreground, wake
    /// everyone waiting for it.
    func update(backgrounded: Bool? = nil, resigning: Bool? = nil) {
        let woken: [CheckedContinuation<Void, any Error>] = lock.withLock {
            if let backgrounded { self.backgrounded = backgrounded }
            if let resigning { self.resigning = resigning }
            guard !self.backgrounded, !self.resigning else { return [] }
            defer { waiters = [] }
            return waiters
        }
        for waiter in woken {
            waiter.resume()
        }
    }

    /// Returns when the app is foreground — immediately if it already is —
    /// without polling: the next `update` that makes it so resumes this.
    /// Throws `CancellationError` if the owning engine goes away first.
    func waitUntilForeground() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyForeground: Bool = lock.withLock {
                if !backgrounded, !resigning { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyForeground {
                continuation.resume()
            }
        }
    }

    func cancelWaiters() {
        let cancelled: [CheckedContinuation<Void, any Error>] = lock.withLock {
            defer { waiters = [] }
            return waiters
        }
        for waiter in cancelled {
            waiter.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Errors

enum MLXKokoroError: Error, LocalizedError {
    /// This device cannot run MLX (the simulator, or no Metal GPU).
    case unsupported
    /// The app is backgrounded; Metal would refuse the GPU work.
    case backgrounded
    case timedOut(TimeInterval)
    case invalidRepository(String)
    /// A file the load or the first synthesis needs was missing after the
    /// download and its one retry.
    case incompleteDownload(String)
    case notDownloaded
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Readr Voice cannot run on this device"
        case .backgrounded:
            return "Readr Voice cannot synthesize while the app is in the background"
        case .timedOut(let seconds):
            return "Readr Voice synthesis exceeded \(Int(seconds))s"
        case .invalidRepository(let repo):
            return "Invalid model repository id: \(repo)"
        case .incompleteDownload(let file):
            return "Readr Voice model download is incomplete: \(file) is missing"
        case .notDownloaded:
            return "Readr Voice model has not been downloaded"
        case .notLoaded:
            return "Readr Voice model has not been loaded"
        }
    }
}
#endif
