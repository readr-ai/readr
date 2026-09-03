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
///   so a speed change keeps the buffer. In the foreground a pump works
///   through the lookahead on the GPU until the horizon is met; the sentence
///   being spoken always goes first.
/// - **The CPU with the screen locked.** Metal refuses command buffers
///   from a backgrounded app and MLX surfaces that as a C++ `runtime_error`
///   inside Metal's completion handler — a `std::terminate`, not something
///   Swift can catch (mlx-swift#274, #407). So from `didEnterBackground` to
///   `willEnterForeground` (plus a head start on `willResignActive` for the
///   lock) every synthesis runs on MLX's CPU device instead, chosen on the
///   actor immediately before the call. Playback carries on from the
///   buffer while the CPU refills it — only while the buffer ahead is below
///   `backgroundRefillStartsBelow`, and until it reaches
///   `backgroundRefillStopsAt`. The weights are still loaded (and warmed)
///   on the GPU in the foreground only.
/// - **A hold, not a substitute.** Nothing buffered for the next sentence
///   with the screen locked — and no CPU synthesis of it about to land — is
///   reported to the controller as a suspension: narration pauses on the
///   sentence with "Unlock Readr to keep listening", and play on return
///   speaks it on the GPU. No Apple voice reads in its place.
///
/// Per sentence the device, synthesis time and audio length are measured;
/// one line in ten (and the first after a device switch) goes to
/// `DiagnosticsLog`, and `cpuRealtimeFactor` is the rolling ratio of audio
/// to synthesis time over the last `cpuRealtimeWindow` CPU sentences.
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
final class MLXKokoroSpeechEngine: NSObject, ReadrVoiceEngine, SpeechPrefetching, SpeechRateAdjusting {
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

    /// Spoken once on each device right after the load and thrown away:
    /// `KokoroModel.fromModelDirectory` re-runs the G2P's `prepare()`, the
    /// Misaki lexicons and the BART fallback are built lazily on the first
    /// `process`, and each device compiles the model's kernels on first
    /// use. Paying for all of that here means the first real sentence — and
    /// the first backgrounded one — carries none of it.
    static let warmUpText = "Ready."

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
    /// One measurement line per this many sentences.
    static let logEverySentences = 10

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
    /// The background refill's hysteresis: on below one threshold, off at
    /// the other.
    private var refilling = false
    /// The synthesis the actor is on (or about to be), so a `speak` of that
    /// very sentence awaits it rather than queueing a second one.
    private var inFlight: (key: ReadrVoiceAudioCache.Key, task: Task<Synthesis, Error>)?
    /// Sentences waiting to be spoken NOW — while any, the pump does not
    /// start another prefetch.
    private var speakWaiting = 0
    /// Sentences this session could not synthesize; the pump skips them
    /// rather than retrying every pass.
    private var unsynthesizable: Set<ReadrVoiceAudioCache.Key> = []

    // MARK: - Measurement

    /// Audio seconds produced per second of CPU synthesis, over the last
    /// `cpuRealtimeWindow` CPU sentences; nil until the CPU has done one.
    /// 1.0 is exactly realtime.
    private(set) var cpuRealtimeFactor: Double?
    private var cpuWindow: [(synthesis: TimeInterval, audio: TimeInterval)] = []
    private var sentenceCount = 0
    private var lastDevice: DeviceType?

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
                    + "sentence, cpu rtf \(cpuRealtimeFactor.map { String(format: "%.2f", $0) } ?? "n/a")"
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
        lookahead = requests
        let listed = Set(requests.map(\.id))
        keys = keys.filter { listed.contains($0.key) }
        if requests.isEmpty {
            pump?.cancel()
            pump = nil
            refilling = false
        } else {
            kickPump()
        }
    }

    func secondsBuffered(ahead requests: [SpeechRequest]) -> TimeInterval {
        var total: TimeInterval = 0
        for request in requests {
            guard let entry = cache.entry(for: key(for: request)) else { break }
            total += entry.seconds
        }
        return total
    }

    private func key(for request: SpeechRequest) -> ReadrVoiceAudioCache.Key {
        if let key = keys[request.id] { return key }
        let key = ReadrVoiceAudioCache.key(for: request)
        keys[request.id] = key
        return key
    }

    private static func playable(_ entry: ReadrVoiceAudioCache.Entry, rate: Double) -> PlayableAudio {
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
                _ = try await synthesizeAndStore(ready)
            } catch is CancellationError {
                return
            } catch {
                unsynthesizable.insert(key(for: ready))
                DiagnosticsLog.shared.record(
                    .warning, .reader, "Readr Voice (MLX) could not synthesize ahead", error: error
                )
            }
        }
    }

    /// Whether the pump has a reason to work right now.
    private func shouldRefill() -> Bool {
        guard !lookahead.isEmpty else { return false }
        let ahead = secondsBuffered(ahead: lookahead)
        // Past the cache's capacity, more audio ahead only evicts the head.
        guard ahead < ReadrVoiceAudioCache.capacitySeconds else { return false }
        guard !isForeground else { return true }
        if refilling {
            if ahead >= Self.backgroundRefillStopsAt {
                refilling = false
                return false
            }
            return true
        }
        if ahead < Self.backgroundRefillStartsBelow {
            refilling = true
            return true
        }
        return false
    }

    private func nextToSynthesize() -> SpeechRequest? {
        lookahead.first { request in
            let cacheKey = key(for: request)
            return cache.entry(for: cacheKey) == nil && !unsynthesizable.contains(cacheKey)
        }
    }

    // MARK: - Synthesis

    /// The `synthesize` half of `SentenceAudioPlayer.speak` for a sentence
    /// not yet in the buffer: wait for the model, re-check that the request
    /// still stands, then synthesize — unless the pump landed it meanwhile,
    /// or is on it now.
    @MainActor
    private func synthesizeForPlayback(
        _ request: SpeechRequest, key: ReadrVoiceAudioCache.Key
    ) async throws -> Synthesis {
        speakWaiting += 1
        defer { speakWaiting -= 1 }
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
        return try await synthesizeAndStore(request)
    }

    /// One synthesis on the actor, against a deadline, filed into the
    /// buffer, measured. The device is the actor's choice at the moment it
    /// starts; the deadline is this thread's guess at it.
    @MainActor
    private func synthesizeAndStore(_ request: SpeechRequest) async throws -> Synthesis {
        let cacheKey = key(for: request)
        let synthesizer = self.synthesizer
        let cache = self.cache
        let foreground = self.foreground
        let voice = KokoroSpeechEngine.kokoroVoice(from: request.voiceID)
        let text = request.text
        let task = Task<Synthesis, Error> {
            try await synthesizer.synthesize(
                text: text, voice: voice, key: cacheKey, into: cache,
                isForeground: { foreground.isForeground }
            )
        }
        inFlight = (cacheKey, task)
        defer {
            if inFlight?.key == cacheKey { inFlight = nil }
        }
        let timeout = foreground.isForeground ? Self.gpuSynthesisTimeout : Self.cpuSynthesisTimeout
        do {
            // The first of the synthesis or the deadline wins; a synthesis
            // that runs past the deadline keeps running (MLX has no mid-graph
            // cancellation) but nobody is waiting for it any more, and its
            // late result is dropped inside the helper.
            let synthesis = try await raceAgainstDeadline(seconds: timeout) {
                try await task.value
            }
            record(synthesis)
            return synthesis
        } catch let deadline as DeadlineExceeded {
            // The actor is wedged behind a call that will not return, or not
            // soon. Mark the engine sick: `.failed` takes it out of the
            // router's choice, so no following sentence queues behind the
            // wedged call. The bar's Retry is the way back — it runs
            // `startInitializing` afresh, which returns at once if the
            // model is already loaded.
            readiness = .failed
            initializeTask = nil
            throw MLXKokoroError.timedOut(deadline.seconds)
        }
    }

    /// Bookkeeping for one synthesis: the sentence count, the CPU window,
    /// and — one line in ten, plus the first after a device switch — the
    /// diagnostics line the owner reads the realtime factor from. Numbers
    /// only, never text.
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
        let switched = lastDevice != device
        lastDevice = device
        guard switched || sentenceCount % Self.logEverySentences == 0 else { return }
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
            try await synthesizer.load(
                isForeground: { foreground.isForeground }, warmUpVoice: voice
            )
        }
        initializeTask = task
        Task { @MainActor [weak self] in
            do {
                try await task.value
                guard let self else { return }
                self.readiness = .ready
                // The CPU's kernels and lexicons, compiled now rather than
                // on the first locked-screen sentence. Queued on the actor
                // behind whatever the reader is waiting to hear.
                Task { await synthesizer.warmUpCPU(voice: voice) }
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

        /// The same warm-up on the CPU device, so the first locked-screen
        /// sentence is not a cold compile. Safe anywhere; failures are
        /// logged and otherwise ignored — the CPU path is best-effort.
        func warmUpCPU(voice: String) async {
            guard let model else { return }
            do {
                let _: [Float] = try await Device.withDefaultDevice(Device.cpu) {
                    try await self.samples(
                        for: MLXKokoroSpeechEngine.warmUpText, voice: voice, model: model
                    )
                }
            } catch {
                DiagnosticsLog.shared.record(
                    .warning, .reader, "Readr Voice (MLX) CPU warm-up failed", error: error
                )
            }
        }

        /// A whole sentence synthesized at 1× on whichever device the app's
        /// state allows at this moment — the GPU in the foreground, the CPU
        /// otherwise — and filed into the buffer. The reader's speed is the
        /// player's business.
        func synthesize(
            text: String, voice: String, key: ReadrVoiceAudioCache.Key,
            into cache: ReadrVoiceAudioCache, isForeground: @Sendable () -> Bool
        ) async throws -> Synthesis {
            guard let model else { throw MLXKokoroError.notLoaded }
            model.speed = 1
            let device: DeviceType = isForeground() ? .gpu : .cpu
            let mlxDevice: Device = device == .cpu ? Device.cpu : Device.gpu
            let started = Date()
            let produced: [Float] = try await Device.withDefaultDevice(mlxDevice) {
                try await self.samples(for: text, voice: voice, model: model)
            }
            let elapsed = Date().timeIntervalSince(started)
            let entry = try cache.store(samples: produced, sampleRate: model.sampleRate, for: key)
            return Synthesis(entry: entry, device: device, seconds: elapsed)
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
    /// The app is backgrounded; Metal would refuse the GPU load.
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
        }
    }
}
#endif
