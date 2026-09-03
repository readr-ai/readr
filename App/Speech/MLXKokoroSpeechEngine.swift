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
// mlx-swift's `Cmlx` C target has no product entry in Package.swift, but
// the "MLX" product depends on it, so its module map is in the build graph
// for anything that (transitively) links "MLX" — this compiles even though
// Cmlx is not one of the package's declared libraries. `mlx_disable_compile`
// / `mlx_enable_compile` (Source/Cmlx/mlx-c/mlx/c/compile.h) have no Swift
// wrapper in mlx-swift; see the CPU-compile note below for why they're used.
import Cmlx

/// "Readr Voice" on iPhone and iPad: the same Kokoro-82M as
/// `KokoroSpeechEngine`, run through MLX (Blaizzy/mlx-audio-swift) instead
/// of CoreML. On iOS 26.4+ Apple's CoreML CPU path segfaults inside libBNNS
/// during Kokoro inference — uncatchable, three App Store crash logs,
/// FluidAudio#817/#844 — and MLX never touches BNNS. See
/// docs/research/MLX-KOKORO-IOS.md for the decision and the alternatives
/// that lost.
///
/// Since 3.3.1 this engine is the only voice an English book is heard in,
/// and three things make that hold with the phone in a pocket:
///
/// - **A buffer on disk.** Every sentence synthesized — the one being said
///   and the ones the controller hands over ahead of it (`prefetch`) — is
///   filed in `ReadrVoiceAudioCache` as compressed audio at 1×, keyed by
///   book, voice and text. A sentence that is already there plays at once,
///   whatever the app's state; the reader's speed is applied at playback,
///   so a speed change keeps the buffer. A pump works through the lookahead
///   on the same device split as playback (`PrefetchDevicePolicy.
///   gpuWhileActive`, the default): GPU while the app is foreground, CPU
///   while it isn't; the sentence being spoken always goes first, and
///   always wins the actor.
/// - **The GPU only in the foreground.** A sentence is synthesized on the
///   GPU only while the app is foreground — active, not backgrounded, not
///   resigning (`isForeground`). That is the one place the GPU is used at
///   all; every use is logged at `.info` with its duration so the exposure
///   the lock race depends on is visible after the fact. `readrVoice.
///   prefetchOnCPUOnly` (default off) forces the pump onto the CPU even in
///   the foreground, for measuring `cpuRealtimeFactor` against a live GPU
///   baseline; `readrVoice.prefetchOnGPU` is kept as a no-op alias for the
///   (now default) GPU-while-active behaviour.
/// - **The CPU with the screen locked, compiled out.** Metal refuses
///   command buffers from a backgrounded app and MLX surfaces that as a
///   C++ `runtime_error` inside Metal's completion handler — a
///   `std::terminate`, not something Swift can catch (mlx-swift#274,
///   #407). So from `didEnterBackground` to `willEnterForeground` (plus a
///   head start on `willResignActive` for the lock) every synthesis runs
///   on MLX's CPU device instead, chosen on the actor immediately before
///   the call. Kokoro's layers compile their activation functions
///   (`compile(shapeless:)`, MLXNN/Activations.swift) and on-device
///   evidence shows some hardware cannot JIT those on the CPU backend at
///   all (`[Compiled::eval_cpu] CPU compilation not supported on the
///   platform`, mlx-c array.cpp:352) — an uncaught error that used to
///   reach MLX's default handler. Every CPU synthesis now runs with MLX
///   compilation globally disabled (`mlx_disable_compile`/
///   `mlx_enable_compile`, `Cmlx` — no Swift wrapper exists) around
///   exactly that one admitted graph; the actor never admits a second, so
///   the global toggle never crosses a GPU synthesis, which keeps
///   compilation on. If a CPU synthesis still throws — compilation
///   disabled or not — the session marks the CPU unavailable, logs it, and
///   never tries the CPU again: playback then relies on the buffer alone,
///   with a hold when it runs dry (below). Playback carries on from the
///   buffer while the CPU refills it — only while the buffer ahead is
///   below `backgroundRefillStartsBelow`, and until it reaches
///   `backgroundRefillStopsAt`, and only while the CPU hasn't been marked
///   unavailable this session. The weights are still loaded (and warmed,
///   on the CPU first — see `scheduleCPUWarmUpIfPossible`) on the GPU in
///   the foreground only.
/// - **A hold, not a substitute.** Nothing buffered for the next sentence
///   with the screen locked — and no CPU synthesis of it about to land — is
///   reported to the controller as a suspension: narration pauses on the
///   sentence with "Paused — unlock Readr to keep listening", and play on return
///   speaks it on the GPU. No Apple voice reads in its place.
///
/// Per sentence the device, synthesis time and audio length are measured
/// and logged to `DiagnosticsLog` at `.info` — every sentence, not one in
/// ten: the file sink caps its size and rotates on its own, so the fuller
/// record is what makes a pause between sentences legible after the fact.
/// A sentence played straight from the buffer is logged with how far ahead
/// it left the voice, and a playback that has to wait on a synthesis in
/// progress is logged with how long it waited. `cpuRealtimeFactor` is the
/// rolling ratio of audio to synthesis time over the last
/// `cpuRealtimeWindow` CPU sentences.
///
/// Every call into MLX — the model load, a warm-up, and every synthesis —
/// runs inside mlx-swift's scoped `withError`, so an MLX-reported error
/// (a shape mismatch, an unsupported op) becomes a thrown Swift error the
/// engine turns into `didFail` or a hold, never the process trap of MLX's
/// default handler. `withError` cannot reach an error thrown from inside
/// Metal's own completion handler off the cooperative thread pool — see
/// the note on the residual GPU exposure below.
///
/// Same shape and contract as the CoreML engine otherwise — playback is
/// the shared `SentenceAudioPlayer`, `.speaking` is reported through the
/// synthesis/download gap so the controller's silent-engine watchdog holds
/// off, `isPreparing` while the model is not in, `didFail` on any error.
/// Main-thread-confined; synthesis hops to the `Synthesizer` actor and back.
///
/// **No simulator.** MLX cannot run on the iOS Simulator at all
/// (mlx#2605); `isAvailableOnThisDevice` is false there, this engine is
/// never constructed, and the router narrates through the platform voice.
/// Nothing here touches MLX before the first load — `init` observes four
/// notifications and reads a directory listing — so a launch, and the UI
/// tests' `-uiTestSilentNarration` stub, never load the runtime.
///
/// MLX cannot cancel a Metal graph already submitted, and a C++ exception
/// thrown from inside Metal's completion handler for one that failed is
/// uncatchable — `std::terminate`, not a Swift error `withError` can turn
/// into a throw (mlx-swift#274, #407). The engine therefore admits exactly
/// one GPU sentence at a time and never queues a second, and now reaches
/// for the GPU only for a sentence that must play immediately — prefetch's
/// default move to the CPU shrinks the window in which a lock can land on
/// a live GPU graph, it does not close it. A lock that still lands during
/// that one graph is warning-logged with its elapsed time for the device
/// smoke test.
final class MLXKokoroSpeechEngine:
    NSObject, ReadrVoiceEngine, SpeechPrefetching, SpeechRateAdjusting
{
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

    /// Kokoro refuses more than 510 phonemes per call; a GPU synthesis over
    /// this long has hung, not stalled. The engine marks itself `.failed` —
    /// see `synthesizeAndStore`.
    static let gpuSynthesisTimeout: TimeInterval = 30
    /// The CPU is slower by an amount only the device can tell us; the
    /// deadline is generous so a slow-but-honest synthesis is not mistaken
    /// for a hang.
    static let cpuSynthesisTimeout: TimeInterval = 180

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

    /// Used only for the lazy CPU warm-up after real playback has begun. The
    /// first real GPU sentence is deliberately its own warm-up.
    static let warmUpText = "Ready."

    enum PrefetchDevicePolicy: Sendable, Equatable {
        case gpuWhileActive
        case cpuAlways

        /// GPU-while-active by default: prefetch takes the same
        /// foreground/backgrounded split as playback, since CPU synthesis
        /// now runs with MLX compilation disabled (see the type's doc
        /// comment) and a CPU failure degrades to buffer-only listening
        /// instead of taking the process down — the 3.3.1 rationale for
        /// always parking prefetch on the CPU (never holding a GPU graph
        /// Metal could be asked to drop mid-flight) no longer outweighs the
        /// cost of a slower CPU-only lookahead in the foreground.
        /// `readrVoice.prefetchOnCPUOnly` (true) forces the pump onto the
        /// CPU even while active, to measure `cpuRealtimeFactor` against a
        /// live GPU baseline. `readrVoice.prefetchOnGPU` is read but is now
        /// a no-op — it forced this same behaviour pre-fix — kept only so
        /// the device smoke test's existing scripts don't need editing.
        static func configured(defaults: UserDefaults = .standard) -> Self {
            if defaults.bool(forKey: "readrVoice.prefetchOnCPUOnly") {
                return .cpuAlways
            }
            _ = defaults.bool(forKey: "readrVoice.prefetchOnGPU")
            return .gpuWhileActive
        }
    }

    /// How long a `willResignActive` counts as "about to be backgrounded".
    /// The lock sends `willResignActive` and then `didEnterBackground`
    /// within a few hundred milliseconds; Control Center, a notification
    /// banner and an incoming call send `willResignActive` alone. After this
    /// long with no `didEnterBackground`, the app is taken to be still in
    /// the foreground.
    static let resignGracePeriod: TimeInterval = 1.5

    // MARK: - Buffer policy

    /// With the screen locked the CPU refills only while the buffer ahead
    /// of the voice is below this…
    static let backgroundRefillStartsBelow: TimeInterval = 30 * 60
    /// …and stops once it reaches this. In the foreground the pump works to
    /// the controller's horizon (and never past the cache's capacity).
    static let backgroundRefillStopsAt: TimeInterval = 60 * 60
    /// How many CPU sentences the realtime factor is averaged over.
    static let cpuRealtimeWindow = 5
    /// A CPU synthesis of the next sentence is worth waiting for only if
    /// the CPU has been producing audio at least this fast relative to
    /// playback; below it, the hold is the better experience.
    static let cpuKeepsUpFactor = 0.8
    /// Below this a playback wait is not worth a diagnostics line — the
    /// join of an already in-flight synthesis is essentially instant and
    /// would otherwise dominate the log.
    static let waitLogThreshold: TimeInterval = 0.05

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
    /// nil before it starts, once it ends (the cached G2P check and weight
    /// load that follow are short and indeterminate), and outside `.downloading`.
    private(set) var downloadProgress: Double? {
        didSet {
            guard downloadProgress != oldValue else { return }
            onDownloadProgressChange?(downloadProgress)
        }
    }
    var onDownloadProgressChange: ((Double?) -> Void)?

    // MARK: - Foreground

    /// The app is NOT backgrounded, so Metal will accept GPU work. Read by
    /// the actor right before every synthesis to choose the device, and
    /// before every load.
    ///
    /// "Not backgrounded" rather than "active", deliberately. Only a
    /// backgrounded app is refused the GPU; `willResignActive` also fires
    /// for Control Center, a notification banner, an incoming call and — on
    /// iPad — every time focus moves to the other Split View or Stage
    /// Manager app, and Metal accepts work in all of those. So the flag is
    /// false from `didEnterBackground` until `willEnterForeground`.
    ///
    /// Plus a head start for the lock: `didEnterBackground` arrives a few
    /// hundred milliseconds after `willResignActive`, and a GPU synthesis
    /// started in that gap would be in flight when the GPU goes away. So
    /// `willResignActive` also makes this false, until `didBecomeActive` —
    /// or, if no `didEnterBackground` follows within `resignGracePeriod`
    /// (the Control Center case), on its own.
    var isForeground: Bool { foreground.isForeground }
    private let foreground: ForegroundGate
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var resignGrace: Task<Void, Never>?

    // MARK: - State

    private let synthesizer = Synthesizer()
    private let cache = ReadrVoiceAudioCache.shared
    private let gpuWork = GPUWorkTracker()
    private let prefetchDevicePolicy: PrefetchDevicePolicy
    private var initializeTask: Task<Void, Error>?
    /// Playback, shared with the CoreML engine.
    private let audio = SentenceAudioPlayer()

    /// The sentences after the current one, as the controller last handed
    /// them over; the pump works through it from the front.
    private var lookahead: [SpeechRequest] = []
    /// Cache keys by request id, computed as they are first needed — the
    /// list is walked from the front and stops at the first miss, so most
    /// of a long list is never hashed.
    private var keys: [UUID: ReadrVoiceAudioCache.Key] = [:]
    private var pump: Task<Void, Never>?
    /// Exclusive end of the bounded prefix and the next index never attempted.
    private var windowEnd = 0
    private var synthesizedFrontier = 0
    private var protectedWindowKeys: Set<ReadrVoiceAudioCache.Key> = []
    /// The background refill's hysteresis: on below one threshold, off at
    /// the other.
    private var refilling = false
    /// The synthesis the actor is on (or about to be), so a `speak` of that
    /// very sentence awaits it rather than queueing a second one.
    private var inFlight: (
        key: ReadrVoiceAudioCache.Key,
        purpose: SynthesisPurpose,
        task: Task<Synthesis, Error>
    )?
    /// Kept separately because a playback task can supersede `inFlight`
    /// while this prefetch is still queued at the actor.
    private var prefetchTask: Task<Synthesis, Error>?
    /// Sentences waiting to be spoken NOW — while any, the pump does not
    /// start another prefetch.
    private var speakWaiting = 0
    /// Sentences this session could not synthesize; the pump skips them
    /// rather than retrying every pass.
    private var unsynthesizable: Set<ReadrVoiceAudioCache.Key> = []
    private var hasStartedPlayback = false
    /// `Error?` rather than `Void`: `warmUpCPU` reports its failure (if any)
    /// so it can be routed to `markCPUUnavailable`.
    private var cpuWarmUpTask: Task<Error?, Never>?
    /// Set once a CPU synthesis has thrown this session — the warm-up, a
    /// prefetch, or an on-demand synthesis — even with MLX compilation
    /// disabled. Sticky for the engine's lifetime: the pump stops trying
    /// the CPU, background refill is skipped, and locked-screen listening
    /// becomes buffer-only, holding (`didSuspend(.needsForeground)`) when
    /// the buffer runs out rather than reaching for a device that keeps
    /// failing.
    ///
    /// Starts TRUE unless `readrVoice.cpuContinuation` (UserDefaults) is on:
    /// on the owner's iPhone 17 Pro a "CPU" synthesis still finalized a
    /// Metal stream from the background (`mlx::core::gpu::finalize` →
    /// `check_error` throwing in the completion handler, uncatchable), so
    /// no MLX work of any kind runs while the app is backgrounded. The key
    /// exists for measuring a future MLX that keeps the CPU path off Metal.
    private(set) var cpuUnavailable: Bool =
        !UserDefaults.standard.bool(forKey: "readrVoice.cpuContinuation")

    // MARK: - Measurement

    /// Audio seconds produced per second of CPU synthesis, over the last
    /// `cpuRealtimeWindow` CPU sentences; nil until the CPU has done one.
    /// 1.0 is exactly realtime.
    private(set) var cpuRealtimeFactor: Double?
    private var cpuWindow: [(synthesis: TimeInterval, audio: TimeInterval)] = []
    private var sentenceCount = 0

    override convenience init() {
        self.init(prefetchDevicePolicy: .configured())
    }

    init(prefetchDevicePolicy: PrefetchDevicePolicy) {
        // Main-thread-confined, like every engine; the model that builds the
        // router is @MainActor, which is what makes this assumption safe.
        let backgrounded = MainActor.assumeIsolated {
            UIApplication.shared.applicationState == .background
        }
        foreground = ForegroundGate(backgrounded: backgrounded)
        self.prefetchDevicePolicy = prefetchDevicePolicy
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
            MainActor.assumeIsolated {
                self.hasStartedPlayback = true
                self.scheduleCPUWarmUpIfPossible()
            }
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
        // The buffer's index is a directory listing; take it off the main
        // thread now rather than on the first sentence.
        let cache = self.cache
        Task.detached(priority: .utility) { cache.loadIndex() }
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        resignGrace?.cancel()
        pump?.cancel()
        cpuWarmUpTask?.cancel()
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
        if let elapsed = gpuWork.elapsedIfInFlight {
            DiagnosticsLog.shared.record(
                .warning,
                .reader,
                "Readr Voice (MLX) GPU synthesis was in flight at background entry: "
                    + "\(Int(elapsed * 1000))ms elapsed"
            )
        }
        // The refill decision changes with the device.
        kickPump()
    }

    private func willEnterForeground() {
        foreground.update(backgrounded: false)
        refilling = false
        kickPump()
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
        guard readiness != .unsupported else {
            delegate?.speechEngine(self, didFail: request.id, error: MLXKokoroError.unsupported)
            return
        }
        let cacheKey = key(for: request)
        // Already audio: play it, whatever the app's state and whether or
        // not the model is even loaded this launch.
        if let entry = cache.entry(for: cacheKey) {
            DiagnosticsLog.shared.record(
                .info, .reader,
                "Readr Voice (MLX) sentence played from cache; "
                    + "\(Int(secondsBuffered(ahead: lookahead)))s ahead"
            )
            audio.speak(request) { request in Self.playable(entry, rate: request.rate) }
            kickPump()
            return
        }
        // Nothing buffered with the screen locked. A CPU synthesis of this
        // very sentence that is keeping up is worth the wait; anything else
        // — no synthesis, a CPU that has been falling behind, a model not
        // yet loaded — is a hold: pause here and say so, rather than a
        // silence of unknown length or another voice.
        if !isForeground, !(inFlight?.key == cacheKey && cpuKeepsUp) {
            DiagnosticsLog.shared.record(
                .info, .reader,
                "Readr Voice (MLX) holding for the foreground: nothing buffered for the next "
                    + "sentence, cpu rtf "
                    + (cpuRealtimeFactor.map { String(format: "%.2f", $0) } ?? "n/a")
            )
            delegate?.speechEngine(self, didSuspend: request.id, reason: .needsForeground)
            return
        }
        // Not in yet: the sentence waits for the download and the load
        // (started in `synthesizeForPlayback` if they haven't been), and the
        // bar shows the wait rather than an Apple voice reading meanwhile.
        if readiness != .ready {
            delegate?.speechEngine(self, isPreparing: request.id)
        }
        audio.speak(request) { [weak self] request in
            guard let self else { throw CancellationError() }
            let synthesis = try await self.synthesizeForPlayback(request, key: cacheKey)
            return Self.playable(synthesis.entry, rate: request.rate)
        }
        kickPump()
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
        pump?.cancel()
        pump = nil
        lookahead = []
        keys = [:]
        protectedWindowKeys = []
        synthesizedFrontier = 0
        windowEnd = 0
        refilling = false
        if inFlight?.purpose == .prefetch {
            inFlight?.task.cancel()
        }
        prefetchTask?.cancel()
        prefetchTask = nil
        cpuWarmUpTask?.cancel()
        cpuWarmUpTask = nil
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

    // MARK: - SpeechRateAdjusting

    /// The buffer is at 1×; the player takes the speed. Nothing to re-speak.
    func adjustRate(_ rate: Double) -> Bool {
        audio.setRate(Float(rate))
    }

    // MARK: - SpeechPrefetching

    func prefetch(_ requests: [SpeechRequest]) {
        let completed = completedKeyCounts()
        lookahead = requests
        let listed = Set(requests.map(\.id))
        keys = keys.filter { listed.contains($0.key) }
        if requests.isEmpty {
            pump?.cancel()
            pump = nil
            refilling = false
            protectedWindowKeys = []
            synthesizedFrontier = 0
            windowEnd = 0
        } else {
            configureWindow(retaining: completed)
            kickPump()
        }
    }

    func secondsBuffered(ahead requests: [SpeechRequest]) -> TimeInterval {
        var total: TimeInterval = 0
        for request in requests {
            guard let entry = cache.entry(for: key(for: request)) else { break }
            total += SpeechPrefetchWindow.playbackSeconds(
                audioSeconds: entry.seconds,
                rate: request.rate
            )
        }
        return total
    }

    private func completedKeyCounts() -> [ReadrVoiceAudioCache.Key: Int] {
        var counts: [ReadrVoiceAudioCache.Key: Int] = [:]
        for request in lookahead.prefix(synthesizedFrontier) {
            counts[key(for: request), default: 0] += 1
        }
        return counts
    }

    private func configureWindow(retaining completed: [ReadrVoiceAudioCache.Key: Int]) {
        var remaining = completed
        synthesizedFrontier = 0
        for request in lookahead {
            let cacheKey = key(for: request)
            guard remaining[cacheKey, default: 0] > 0 else { break }
            remaining[cacheKey, default: 0] -= 1
            synthesizedFrontier += 1
        }

        let estimated = lookahead.map {
            Double($0.text.count) / NarrationController.charactersPerSecond
        }
        let provisionalEnd = SpeechPrefetchWindow.endIndex(
            forAudioSeconds: estimated,
            capacitySeconds: ReadrVoiceAudioCache.capacitySeconds
        )
        let provisionalKeys = Set(lookahead.prefix(provisionalEnd).map { key(for: $0) })
        let firstSentence = estimated.first ?? 0
        cache.trimToCapacity(
            protecting: provisionalKeys,
            reserving: firstSentence
        )
        let secondsBehind = cache.secondsOutside(provisionalKeys)
        windowEnd = SpeechPrefetchWindow.endIndex(
            forAudioSeconds: estimated,
            capacitySeconds: ReadrVoiceAudioCache.capacitySeconds,
            secondsBehindCursor: secondsBehind
        )
        protectedWindowKeys = Set(lookahead.prefix(windowEnd).map { key(for: $0) })
        advanceFrontierPastCachedEntries()
    }

    private func advanceFrontierPastCachedEntries() {
        while synthesizedFrontier < windowEnd {
            let request = lookahead[synthesizedFrontier]
            guard cache.entry(for: key(for: request)) != nil else { return }
            synthesizedFrontier += 1
        }
    }

    private func key(for request: SpeechRequest) -> ReadrVoiceAudioCache.Key {
        if let key = keys[request.id] { return key }
        let key = ReadrVoiceAudioCache.key(for: request)
        keys[request.id] = key
        return key
    }

    private static func playable(
        _ entry: ReadrVoiceAudioCache.Entry,
        rate: Double
    ) -> PlayableAudio {
        entry.seconds > 0 ? .file(entry.url, rate: Float(rate)) : .nothing
    }

    // MARK: - The pump

    /// Synthesize ahead, one sentence at a time, while there is something
    /// to synthesize and a reason to: in the foreground, to the horizon; in
    /// the background, on the CPU, between the two refill thresholds. The
    /// sentence being spoken always goes first — the pump waits it out.
    private func kickPump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            await self?.runPump()
            self?.pump = nil
        }
    }

    @MainActor
    private func runPump() async {
        while !Task.isCancelled {
            guard shouldRefill(), let next = nextToSynthesize() else {
                refilling = false
                return
            }
            if speakWaiting > 0 || inFlight != nil {
                // The current sentence, or a synthesis already running,
                // comes first.
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            // A failed engine does not retry its download on its own — that
            // hammered flaky connections once already; the bar's Retry is
            // the way back.
            guard readiness != .failed else { return }
            do {
                try await ensureInitialized()
            } catch {
                return
            }
            // Re-checked after the wait: the load may have taken a while,
            // and the world moved — the list, the device, a sentence the
            // reader is waiting on.
            guard !Task.isCancelled, shouldRefill(), speakWaiting == 0, inFlight == nil,
                  let ready = nextToSynthesize()
            else { continue }
            _ = next
            do {
                _ = try await synthesizeAndStore(ready, purpose: .prefetch)
                advanceFrontier(after: ready)
            } catch is CancellationError {
                return
            } catch {
                unsynthesizable.insert(key(for: ready))
                advanceFrontier(after: ready)
                DiagnosticsLog.shared.record(
                    .warning, .reader, "Readr Voice (MLX) could not synthesize ahead", error: error
                )
            }
        }
    }

    /// Whether the pump has a reason to work right now.
    private func shouldRefill() -> Bool {
        guard !lookahead.isEmpty else { return false }
        // Backgrounded refill is CPU-only (see the type's doc comment); once
        // the CPU has failed this session there is nothing left to refill
        // with, and trying again would just fail again.
        guard isForeground || !cpuUnavailable else { return false }
        let ahead = secondsBuffered(ahead: lookahead)
        let refill = SpeechPrefetchWindow.shouldRefill(
            frontier: synthesizedFrontier,
            windowEnd: windowEnd,
            bufferedSeconds: ahead,
            isForeground: isForeground,
            wasRefilling: refilling,
            startsBelow: Self.backgroundRefillStartsBelow,
            stopsAt: Self.backgroundRefillStopsAt
        )
        refilling = refill && !isForeground
        return refill
    }

    private func nextToSynthesize() -> SpeechRequest? {
        advanceFrontierPastCachedEntries()
        while synthesizedFrontier < windowEnd {
            let request = lookahead[synthesizedFrontier]
            if !unsynthesizable.contains(key(for: request)) {
                return request
            }
            synthesizedFrontier += 1
        }
        return nil
    }

    private func advanceFrontier(after request: SpeechRequest) {
        guard synthesizedFrontier < windowEnd,
              key(for: lookahead[synthesizedFrontier]) == key(for: request)
        else { return }
        synthesizedFrontier += 1
        advanceFrontierPastCachedEntries()
    }

    // MARK: - Synthesis

    /// The `synthesize` half of `SentenceAudioPlayer.speak` for a sentence
    /// not yet in the buffer: wait for the model, re-check that the request
    /// still stands, then synthesize — unless the pump landed it meanwhile,
    /// or is on it now. Every call here is, by construction, a sentence
    /// `speak` did not find already buffered — a heading synthesized on
    /// demand while the pump was aimed further ahead is exactly this path —
    /// so the whole duration is logged as a wait when it is not negligible;
    /// that is the heading-to-paragraph pause the device smoke test looks for.
    @MainActor
    private func synthesizeForPlayback(
        _ request: SpeechRequest, key: ReadrVoiceAudioCache.Key
    ) async throws -> Synthesis {
        speakWaiting += 1
        let waitStarted = Date()
        defer {
            speakWaiting -= 1
            let waited = Date().timeIntervalSince(waitStarted)
            if waited > Self.waitLogThreshold {
                DiagnosticsLog.shared.record(
                    .info, .reader,
                    "Readr Voice (MLX) playback waited \(Int(waited * 1000))ms for synthesis"
                )
            }
        }
        if let inFlight, inFlight.key == key {
            return try await inFlight.task.value
        }
        try await ensureInitialized()
        // A skip/stop may have replaced this request during the wait.
        guard audio.isCurrent(request) else { throw CancellationError() }
        if let entry = cache.entry(for: key) {
            return Synthesis(entry: entry, device: nil, seconds: 0)
        }
        if let inFlight, inFlight.key == key {
            return try await inFlight.task.value
        }
        return try await synthesizeAndStore(request, purpose: .playback)
    }

    enum SynthesisPurpose: Sendable, Equatable {
        case playback
        case prefetch
    }

    /// One synthesis admitted by the actor, filed into the buffer and measured.
    /// The actor chooses the device and matching deadline only after higher-
    /// priority playback requests have reached its queue.
    @MainActor
    private func synthesizeAndStore(
        _ request: SpeechRequest,
        purpose: SynthesisPurpose
    ) async throws -> Synthesis {
        let cacheKey = key(for: request)
        let synthesizer = self.synthesizer
        let cache = self.cache
        let foreground = self.foreground
        let gpuWork = self.gpuWork
        let policy = prefetchDevicePolicy
        let protectedKeys = protectedWindowKeys
        let voice = KokoroSpeechEngine.kokoroVoice(from: request.voiceID)
        let text = request.text
        let task = Task<Synthesis, Error> {
            try await synthesizer.synthesize(
                text: text, voice: voice, key: cacheKey, into: cache,
                protecting: protectedKeys,
                purpose: purpose,
                prefetchDevicePolicy: policy,
                isForeground: { foreground.isForeground },
                gpuWork: gpuWork
            )
        }
        inFlight = (cacheKey, purpose, task)
        if purpose == .prefetch {
            prefetchTask = task
        }
        defer {
            if inFlight?.key == cacheKey { inFlight = nil }
            if prefetchTask == task { prefetchTask = nil }
        }
        do {
            let synthesis = try await task.value
            record(synthesis)
            return synthesis
        } catch MLXKokoroError.timedOut(let seconds) {
            readiness = .failed
            initializeTask = nil
            throw MLXKokoroError.timedOut(seconds)
        } catch MLXKokoroError.cpuSynthesisFailed(let underlying) {
            markCPUUnavailable(underlying)
            throw underlying
        }
    }

    /// A CPU synthesis — the warm-up, a prefetch, or an on-demand one —
    /// failed even with MLX compilation disabled (`performGraph`). CPU is
    /// not tried again this session: further background refill is skipped
    /// (`shouldRefill`), the warm-up stops rescheduling itself
    /// (`scheduleCPUWarmUpIfPossible`), and a locked-screen sentence with
    /// nothing buffered falls straight to the existing
    /// `didSuspend(.needsForeground)` hold rather than waiting on a device
    /// that keeps failing. Never an Apple voice in its place.
    @MainActor
    private func markCPUUnavailable(_ error: Error) {
        guard !cpuUnavailable else { return }
        cpuUnavailable = true
        DiagnosticsLog.shared.record(
            .warning, .reader,
            "Readr Voice (MLX) CPU synthesis failed with MLX compilation disabled; "
                + "CPU unavailable for the rest of this session",
            error: error
        )
        pump?.cancel()
        pump = nil
    }

    /// Bookkeeping for one synthesis: the sentence count, the CPU window,
    /// and the diagnostics line the owner reads the realtime factor and the
    /// device (so every GPU use, now rare, is visible with its duration)
    /// from — every sentence, not one in ten; the file sink caps its size
    /// and rotates, so the fuller record is affordable. Numbers only, never
    /// text.
    @MainActor
    private func record(_ synthesis: Synthesis) {
        guard let device = synthesis.device else { return }
        sentenceCount += 1
        let audioSeconds = synthesis.entry.seconds
        if device == .cpu {
            cpuWindow.append((synthesis.seconds, audioSeconds))
            if cpuWindow.count > Self.cpuRealtimeWindow {
                cpuWindow.removeFirst(cpuWindow.count - Self.cpuRealtimeWindow)
            }
            let synthesisTotal = cpuWindow.reduce(0) { $0 + $1.synthesis }
            let audioTotal = cpuWindow.reduce(0) { $0 + $1.audio }
            cpuRealtimeFactor = synthesisTotal > 0 ? audioTotal / synthesisTotal : nil
        }
        let factor = synthesis.seconds > 0 ? audioSeconds / synthesis.seconds : 0
        let rolling = cpuRealtimeFactor.map { String(format: "%.2f", $0) } ?? "n/a"
        DiagnosticsLog.shared.record(
            .info, .reader,
            "Readr Voice (MLX) sentence \(sentenceCount): \(device.rawValue) "
                + "\(Int(synthesis.seconds * 1000))ms for \(Int(audioSeconds * 1000))ms of audio "
                + "(\(String(format: "%.1f", factor))× realtime); cpu rtf over last "
                + "\(cpuWindow.count): \(rolling); \(Int(secondsBuffered(ahead: lookahead)))s ahead"
        )
    }

    /// Whether a CPU synthesis is worth waiting for: the rolling factor is
    /// at or above `cpuKeepsUpFactor`. Unknown counts as no — a hold is
    /// recovered in a tap; a silence of unknown length is not.
    private var cpuKeepsUp: Bool {
        (cpuRealtimeFactor ?? 0) >= Self.cpuKeepsUpFactor
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
            try await synthesizer.load(isForeground: { foreground.isForeground })
        }
        initializeTask = task
        Task { @MainActor [weak self] in
            do {
                try await task.value
                guard let self else { return }
                // Weight evaluation is complete. No throwaway inference holds
                // readiness hostage; the first real sentence warms the GPU.
                self.readiness = .ready
                self.scheduleCPUWarmUpIfPossible()
                self.kickPump()
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

    /// CPU compilation is best-effort and begins only after real audio has
    /// started. Actor admission keeps a waiting playback request ahead of
    /// it, but the pump's own prefetch shares the warm-up's `.prefetch`
    /// priority and would only win a race for the one admitted graph by
    /// luck — that race, landing right as the first sentence starts
    /// playing, is what starved the very next sentence's prefetch and
    /// produced the pause the owner heard between a heading and the
    /// paragraph after it. So the warm-up defers, and is retried from every
    /// later `onStart`, while the pump still has a real sentence to
    /// synthesize: prefetch always gets the CPU first.
    @MainActor
    private func scheduleCPUWarmUpIfPossible() {
        guard hasStartedPlayback, readiness == .ready, cpuWarmUpTask == nil, !cpuUnavailable
        else { return }
        guard !(shouldRefill() && nextToSynthesize() != nil) else { return }
        let synthesizer = self.synthesizer
        let gpuWork = self.gpuWork
        let voice = KokoroSpeechEngine.kokoroVoice(from: nil)
        let task = Task {
            await synthesizer.warmUpCPU(voice: voice, gpuWork: gpuWork)
        }
        cpuWarmUpTask = task
        Task { @MainActor [weak self] in
            let error = await task.value
            guard let self, self.cpuWarmUpTask == task else { return }
            self.cpuWarmUpTask = nil
            // The warm-up is deliberately the first CPU use (see the doc
            // comment above), so its own failure is exactly what should
            // surface before the buffer needs the CPU for real.
            if let error, case MLXKokoroError.cpuSynthesisFailed(let underlying) = error {
                self.markCPUUnavailable(underlying)
            }
        }
    }

    /// One synthesis, as the actor reports it.
    struct Synthesis: Sendable {
        let entry: ReadrVoiceAudioCache.Entry
        /// Nil when the audio was already in the buffer — nothing was
        /// synthesized, so there is nothing to measure.
        let device: DeviceType?
        /// Wall-clock seconds the synthesis took.
        let seconds: TimeInterval
    }

    // MARK: - The model, off the main thread

    /// Owns the MLX model. An actor so the download, the load and every
    /// synthesis run off the main thread and one at a time.
    private actor Synthesizer {
        private let textProcessor = PreparingOnceTextProcessor()
        private var modelDirectory: URL?
        private var model: KokoroModel?
        private var graphIsRunning = false
        /// So the `.info` "CPU synthesis starting with MLX compilation
        /// disabled" line (see `performGraph`) is logged once, not once per
        /// sentence.
        private var hasLoggedCPUCompileDisabled = false
        private var playbackWaiters: [CheckedContinuation<Void, Never>] = []
        private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

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
            // `fromModelDirectory` must call the processor's prepare hook to
            // install its private resource URL. Avoid doing it once here and
            // again there when all four files are already in the package's
            // working cache. The idempotent wrapper also makes the second hook
            // a no-op after a first-use download.
            if !Self.g2pAssetsAreCached() {
                try await textProcessor.prepare()
            }
        }

        private static let g2pFiles = [
            "us_bart.safetensors",
            "us_bart_config.json",
            "us_gold.json",
            "us_silver.json",
        ]

        private static var g2pDirectory: URL {
            HubCache.default.cacheDirectory
                .appendingPathComponent("mlx-audio", isDirectory: true)
                .appendingPathComponent("beshkenadze_kitten-tts-g2p", isDirectory: true)
        }

        private static func g2pAssetsAreCached() -> Bool {
            g2pFiles.allSatisfy { name in
                let url = g2pDirectory.appendingPathComponent(name)
                return ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
            }
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

        /// Load and evaluate the weights. No throwaway inference runs here;
        /// readiness follows this return and the first real sentence warms GPU.
        /// `withError` scopes MLX's error handler around the call so a
        /// malformed checkpoint reports as a thrown Swift error instead of
        /// MLX's default handler taking down the process.
        func load(isForeground: @Sendable () -> Bool) async throws {
            guard model == nil else { return }
            guard let modelDirectory else { throw MLXKokoroError.notDownloaded }
            guard isForeground() else { throw MLXKokoroError.backgrounded }
            // Before the first allocation, so the pool never grows past it.
            Memory.cacheLimit = MLXKokoroSpeechEngine.gpuCacheLimit
            let loaded = try await withError {
                try await KokoroModel.fromModelDirectory(
                    modelDirectory, textProcessor: textProcessor
                )
            }
            model = loaded
        }

        /// The same warm-up on the CPU device, so the first locked-screen
        /// sentence is not a cold compile — and, deliberately, so a CPU
        /// that cannot synthesize at all fails here first, on a throwaway
        /// sentence, rather than on one the reader is waiting for. Safe
        /// anywhere; the caller decides what a failure means (it marks the
        /// session's CPU unavailable — see `markCPUUnavailable`) and logs
        /// it, so nothing is logged here.
        func warmUpCPU(voice: String, gpuWork: GPUWorkTracker) async -> Error? {
            guard let model else { return nil }
            do {
                _ = try await performGraph(
                    text: MLXKokoroSpeechEngine.warmUpText,
                    voice: voice,
                    model: model,
                    purpose: .prefetch,
                    fixedDevice: .cpu,
                    prefetchDevicePolicy: .cpuAlways,
                    isForeground: { false },
                    gpuWork: gpuWork
                )
                return nil
            } catch {
                return error
            }
        }

        /// A whole sentence synthesized at 1× on whichever device the app's
        /// state allows at this moment — the GPU in the foreground, the CPU
        /// otherwise — and filed into the buffer. The reader's speed is the
        /// player's business.
        func synthesize(
            text: String, voice: String, key: ReadrVoiceAudioCache.Key,
            into cache: ReadrVoiceAudioCache,
            protecting protectedKeys: Set<ReadrVoiceAudioCache.Key>,
            purpose: SynthesisPurpose,
            prefetchDevicePolicy: PrefetchDevicePolicy,
            isForeground: @Sendable () -> Bool,
            gpuWork: GPUWorkTracker
        ) async throws -> Synthesis {
            guard let model else { throw MLXKokoroError.notLoaded }
            model.speed = 1
            let result = try await performGraph(
                text: text,
                voice: voice,
                model: model,
                purpose: purpose,
                fixedDevice: nil,
                prefetchDevicePolicy: prefetchDevicePolicy,
                isForeground: isForeground,
                gpuWork: gpuWork
            )
            let entry = try cache.store(
                samples: result.samples,
                sampleRate: model.sampleRate,
                for: key,
                protecting: protectedKeys
            )
            return Synthesis(entry: entry, device: result.device, seconds: result.elapsed)
        }

        private struct GraphResult: Sendable {
            let samples: [Float]
            let device: DeviceType
            let elapsed: TimeInterval
        }

        /// Admit one graph at a time. Playback waiters are resumed before any
        /// queued prefetch or warm-up. Device selection and its matching clock
        /// both happen only after this admission point.
        private func performGraph(
            text: String,
            voice: String,
            model: KokoroModel,
            purpose: SynthesisPurpose,
            fixedDevice: DeviceType?,
            prefetchDevicePolicy: PrefetchDevicePolicy,
            isForeground: @Sendable () -> Bool,
            gpuWork: GPUWorkTracker
        ) async throws -> GraphResult {
            await acquireGraph(for: purpose)
            if Task.isCancelled {
                releaseGraph()
                throw CancellationError()
            }

            let device: DeviceType
            if let fixedDevice {
                device = fixedDevice
            } else if purpose == .prefetch, prefetchDevicePolicy == .cpuAlways {
                device = .cpu
            } else {
                device = isForeground() ? .gpu : .cpu
            }
            let timeout = device == .gpu
                ? MLXKokoroSpeechEngine.gpuSynthesisTimeout
                : MLXKokoroSpeechEngine.cpuSynthesisTimeout
            let mlxDevice: Device = device == .cpu ? Device.cpu : Device.gpu
            let started = Date()
            if device == .gpu {
                gpuWork.begin(at: started)
            }
            // Kokoro's layers compile their activation functions
            // (`compile(shapeless:)`, MLXNN/Activations.swift), and some
            // hardware cannot JIT-compile on MLX's CPU backend at all
            // (`[Compiled::eval_cpu] CPU compilation not supported on the
            // platform`, mlx-c array.cpp:352) — device evidence, not a
            // simulator-only limit. So every CPU synthesis disables MLX
            // compilation globally for exactly the one graph this call
            // admits, and restores it once that graph — including a late
            // result after a timeout, below — has fully finished. Safe as a
            // global toggle only because `acquireGraph`/`releaseGraph` above
            // admit one graph at a time, so this never overlaps a GPU
            // synthesis and GPU compilation stays on.
            if device == .cpu {
                if !hasLoggedCPUCompileDisabled {
                    hasLoggedCPUCompileDisabled = true
                    DiagnosticsLog.shared.record(
                        .info, .reader,
                        "Readr Voice (MLX) CPU synthesis starting with MLX compilation disabled"
                    )
                }
                mlx_disable_compile()
            }
            // `samples` is `nonisolated`: run here, on the Task's own
            // executor, never on the actor's. Before this the call to
            // `self.samples(...)` needed the actor's executor to run at
            // all — pinning it for the whole synthesis — so a CPU warm-up
            // or an earlier prefetch already admitted could hold the actor
            // through its entire compute and starve a concurrently arriving
            // playback request of even a chance to reach `acquireGraph`.
            // `withError` turns an MLX-reported error (a shape mismatch, an
            // unsupported op) into a thrown Swift error instead of letting
            // MLX's default handler abort the process.
            let work = Task<[Float], Error> {
                defer {
                    if device == .gpu {
                        gpuWork.end()
                    }
                }
                return try await withError {
                    try await Device.withDefaultDevice(mlxDevice) {
                        try await self.samples(for: text, voice: voice, model: model)
                    }
                }
            }

            do {
                let produced = try await raceAgainstDeadline(seconds: timeout) {
                    try await work.value
                }
                let elapsed = Date().timeIntervalSince(started)
                releaseGraph()
                if device == .cpu { mlx_enable_compile() }
                return GraphResult(samples: produced, device: device, elapsed: elapsed)
            } catch let deadline as DeadlineExceeded {
                // MLX cannot cancel a submitted graph. Keep the admission
                // lock — and compilation disabled, if this is a CPU graph —
                // until its late result lands, while the caller fails on time.
                Task {
                    _ = try? await work.value
                    if device == .cpu { mlx_enable_compile() }
                    self.releaseGraphAfterLateResult()
                }
                throw MLXKokoroError.timedOut(deadline.seconds)
            } catch {
                releaseGraph()
                if device == .cpu {
                    mlx_enable_compile()
                    // A cancellation is not a CPU failure — the request was
                    // superseded or the engine went away, not the hardware
                    // refusing to synthesize. Only a real synthesis error
                    // marks the session's CPU unavailable (see
                    // `MLXKokoroSpeechEngine.markCPUUnavailable`).
                    if !(error is CancellationError) {
                        throw MLXKokoroError.cpuSynthesisFailed(underlying: error)
                    }
                }
                throw error
            }
        }

        private func acquireGraph(for purpose: SynthesisPurpose) async {
            if !graphIsRunning {
                graphIsRunning = true
                return
            }
            await withCheckedContinuation { continuation in
                if purpose == .playback {
                    playbackWaiters.append(continuation)
                } else {
                    backgroundWaiters.append(continuation)
                }
            }
        }

        private func releaseGraphAfterLateResult() {
            releaseGraph()
        }

        private func releaseGraph() {
            let next: CheckedContinuation<Void, Never>?
            if !playbackWaiters.isEmpty {
                next = playbackWaiters.removeFirst()
            } else if !backgroundWaiters.isEmpty {
                next = backgroundWaiters.removeFirst()
            } else {
                graphIsRunning = false
                return
            }
            next?.resume()
        }

        /// The segmenter caps sentences at 320 characters, which keeps nearly
        /// every one under Kokoro's 510-phoneme limit; the rest are cut at a
        /// clause and synthesized in pieces.
        ///
        /// `nonisolated` deliberately: this is where the actual MLX graph
        /// runs, and it touches no actor state — only `model`, handed in by
        /// the caller. Kept off the actor's executor so that the (possibly
        /// multi-second) compute never pins the actor and blocks a
        /// concurrently arriving playback request from even reaching
        /// `acquireGraph`. `performGraph` still serializes admission to one
        /// graph at a time and gives playback priority; this only frees the
        /// actor to keep running while a graph is in flight.
        private nonisolated func samples(
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

/// The package invokes `prepare()` again from `fromModelDirectory`. Keep the
/// required first invocation, but collapse every later hook in this process.
private final class PreparingOnceTextProcessor: TextProcessor, @unchecked Sendable {
    private let processor = MisakiTextProcessor()
    private let lock = NSLock()
    private var isPrepared = false

    func prepare() async throws {
        if lock.withLock({ isPrepared }) { return }
        try await processor.prepare()
        lock.withLock { isPrepared = true }
    }

    func process(text: String, language: String?) throws -> String {
        try processor.process(text: text, language: language)
    }
}

/// Thread-safe observation of the single submitted GPU graph. Lifecycle
/// notifications read this without crossing the synthesizer actor.
private final class GPUWorkTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var startedAt: Date?

    func begin(at date: Date) {
        lock.withLock { startedAt = date }
    }

    func end() {
        lock.withLock { startedAt = nil }
    }

    var elapsedIfInFlight: TimeInterval? {
        lock.withLock { startedAt.map { Date().timeIntervalSince($0) } }
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
    /// The app is backgrounded; Metal would refuse the GPU load.
    case backgrounded
    case timedOut(TimeInterval)
    case invalidRepository(String)
    /// A file the load or the first synthesis needs was missing after the
    /// download and its one retry.
    case incompleteDownload(String)
    case notDownloaded
    case notLoaded
    /// A CPU synthesis threw even with MLX compilation disabled
    /// (`Synthesizer.performGraph`) — a real synthesis failure, not a
    /// cancellation. `MLXKokoroSpeechEngine.markCPUUnavailable` catches
    /// this to stop trying the CPU for the rest of the session.
    case cpuSynthesisFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Readr Voice cannot run on this device"
        case .backgrounded:
            return "Readr Voice cannot load its model while the app is in the background"
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
        case .cpuSynthesisFailed(let underlying):
            return "Readr Voice CPU synthesis failed: \(underlying.localizedDescription)"
        }
    }
}
#endif
