import Foundation
import Combine
import ReadrKit

#if os(iOS)
import MediaPlayer
import UIKit
import UserNotifications
#endif

/// The reader's view of narration: a thin `ObservableObject` over
/// `NarrationController`, which owns every playback rule.
///
/// This layer does only what a controller can't — build the platform engine,
/// persist the reader's voice and speed between books, run the once-a-second
/// tick the sleep timer needs, and publish to the lock screen so a listener can
/// pause without unlocking the phone.
@MainActor
final class NarrationModel: ObservableObject {
    @Published private(set) var status: NarrationStatus = .idle
    /// The sentence being read, for the Listen bar's read-along line.
    @Published private(set) var currentSentence = ""
    @Published private(set) var chapterProgress: Double = 0
    @Published private(set) var sleepMode: SleepTimer = .off
    /// Seconds left on a timed sleep, refreshed on each tick.
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published private(set) var rate: Double
    @Published private(set) var voiceID: String?
    /// Voices offered for the open book, best match first.
    @Published private(set) var voices: [SpeechVoice] = []
    /// Where the Readr Voice model stands (first use is a download: ~104MB of
    /// CoreML weights on a Mac; ~330MB of MLX weights, ~60MB of voice packs
    /// and ~20MB of pronunciation assets on an iPhone or iPad). While it is
    /// on its way narration sits in `.preparing` — the bar shows the wait,
    /// with `readrVoiceDownloadProgress` when the download reports it — and
    /// starts the moment it is in; nothing else reads meanwhile.
    @Published private(set) var readrVoiceReadiness: ReadrVoiceReadiness = .notReady
    /// Fraction of the model download done, when the download library
    /// reports it; nil for an indeterminate wait.
    @Published private(set) var readrVoiceDownloadProgress: Double?
    /// True when this reader would otherwise use Readr Voice, but neither
    /// Kokoro runtime can serve here (macOS builds with the uncatchable Apple
    /// BNNS crash; an iOS device with no Metal GPU, or the simulator) and a
    /// platform voice must read.
    @Published private(set) var readrVoiceUnavailable = false
    /// Readr Voice is in the voice menu for this book: an English book on a
    /// platform where a Kokoro runtime can serve. The menu then shows Readr
    /// Voice alone with the Apple voices under "Other voices".
    @Published private(set) var readrVoiceOffered = false
    /// The runtime behind Readr Voice here, for copy that depends on it (the
    /// download size). Taken from the router rather than the static, so the
    /// UI-test stub (no router) never probes for a Metal device.
    private let readrVoiceRuntime: NarrationEnginePolicy.KokoroRuntime?
    /// On iPhone and iPad Readr Voice plays from its buffer with the screen
    /// locked and refills it on the CPU: the voice menu says "Keeps reading
    /// with the screen locked". True only with the MLX engine.
    let readrVoiceKeepsReadingWhenLocked: Bool
    /// Seconds of Readr Voice audio already synthesized for what follows the
    /// sentence being read — the Listen bar's "48 min ready". Zero for an
    /// Apple voice, and until the engine has anything.
    @Published private(set) var secondsAhead: TimeInterval = 0
    /// Why narration paused on its own, when it did (nil for the reader's
    /// pause): the bar and the lock screen show it.
    @Published private(set) var holdReason: NarrationHoldReason?

    /// The hold, as the bar, the lock screen and the notification say it.
    var holdText: String? {
        switch holdReason {
        case .needsForeground: return "Unlock Readr to keep listening"
        case nil: return nil
        }
    }

    private static let holdNotificationID = "readr.narration.hold"
    private static let notificationsRequestedKey = "narrationNotificationsRequested"
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Whether the current hold has been announced, so one hold posts one
    /// notification.
    private var announcedHold = false

    /// Where the voice is — the reader follows this to keep the page under it.
    var onPosition: ((NarrationPosition) -> Void)?

    private let defaults: UserDefaults
    /// The synthesizer behind narration. `-uiTestSilentNarration` swaps in a
    /// soundless stand-in so UI tests drive the real pipeline deterministically
    /// (see `UITestStubSpeechEngine`); normal launches always get the router.
    private let engine: any SpeechEngine
    /// The same engine, typed — router-only calls (audio-session teardown,
    /// Kokoro prefetch) go through this instead of scattered downcasts that
    /// would silently no-op if the engine type ever changed. Nil only under
    /// the UI-test stub.
    private let router: RoutingSpeechEngine?
    private var narration: NarrationController?
    private var book: Book?
    private var ticker: Timer?

    private static let rateKey = "narrationRate"
    /// Versioned deliberately. The first build chose voices by a rule that could
    /// land on a novelty voice, and a stored choice is honoured unconditionally
    /// as long as it is still installed — so every reader who ran that build
    /// would have kept Albert forever, with the fix helping only people who
    /// never ran it. A new key retires those choices exactly once; a reader who
    /// picked a voice on purpose re-picks it, which is a far smaller cost than
    /// a book narrated by a joke voice with no obvious way out.
    private static let voiceKey = "narrationVoiceID2"

    var isActive: Bool { status != .idle }
    var isSpeaking: Bool { status == .speaking }
    /// Waiting for the Readr Voice model before the first sentence can be
    /// heard — the bar's "Preparing Readr Voice" state.
    var isPreparing: Bool { status == .preparing }
    /// Speaking or preparing: what the play/pause control shows as Pause.
    var isUnderway: Bool { status == .speaking || status == .preparing }
    /// The selected narrator is Readr Voice.
    var usesReadrVoice: Bool { KokoroSpeechEngine.isKokoroVoiceID(voiceID) }
    /// Readr Voice is selected and its model could not be fetched (or a
    /// synthesis hung): narration is paused on the sentence and the bar
    /// offers Retry. No Apple voice reads in its place.
    var readrVoiceFailed: Bool { usesReadrVoice && readrVoiceReadiness == .failed }
    /// The Apple voices, for the "Other voices" disclosure.
    var platformVoices: [SpeechVoice] {
        voices.filter { !KokoroSpeechEngine.isKokoroVoiceID($0.id) }
    }
    /// What the first Listen fetches, for the preparing state's copy.
    var readrVoiceDownloadSize: String {
        readrVoiceRuntime == .mlx ? "410MB" : "104MB"
    }
    /// Where the voice is right now — for the reader to re-sync its page after
    /// an overlay kept `onPosition` unwired (events fired meanwhile are gone).
    var position: NarrationPosition? { narration?.position }

    /// Name of the chosen voice, for the picker's label.
    var voiceName: String? {
        guard let voiceID else { return nil }
        return voices.first { $0.id == voiceID }?.name
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if UITestStubSpeechEngine.isEnabled {
            self.engine = UITestStubSpeechEngine()
            self.router = nil
        } else {
            // Platform voices by default, Kokoro ("Readr Voice") when the
            // picker chooses it — routed per request by voice id.
            let router = RoutingSpeechEngine()
            self.engine = router
            self.router = router
        }
        readrVoiceRuntime = router?.readrVoiceRuntime
        readrVoiceKeepsReadingWhenLocked = router?.readrVoiceRuntime == .mlx
        // Speed and voice are the reader's, not the book's — carried across
        // books the way the reading theme is.
        self.rate = defaults.object(forKey: Self.rateKey) as? Double ?? 1
        self.voiceID = defaults.string(forKey: Self.voiceKey)
        // Readiness changes happen on the main thread (the engine is
        // main-confined), but hop explicitly so the published write is safe
        // whatever thread a future engine reports from.
        router?.onReadrVoiceReadinessChange = { [weak self] readiness in
            Task { @MainActor in self?.readrVoiceReadiness = readiness }
        }
        router?.onReadrVoiceDownloadProgressChange = { [weak self] progress in
            Task { @MainActor in self?.readrVoiceDownloadProgress = progress }
        }
        #if os(iOS)
        // Two things the lookahead and the hold need from the device: whether
        // it is charging (the horizon becomes the rest of the book) and when
        // the app comes back (a hold for the foreground resumes itself).
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyLookaheadHorizon() }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.didReturnToForeground() }
            },
        ]
        #endif
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // The backstop for narration outliving its reader. `ReaderView`'s
        // onDisappear deliberately skips `stop()` while something is presented
        // over the reader (asking about a passage must not cut the voice off)
        // — but on iPad/macOS the notes inspector is a *column*, so leaving
        // the reader with it open hit that skip and the voice kept reading
        // over the library, and reopening the book stacked a second voice on
        // top of the first: every sentence heard twice. The view layer can't
        // always tell "covered for a moment" from "gone"; deallocation can.
        // (`NarrationController` and `AVSpeechEngine` are main-thread-confined
        // plain classes, and the last reference is SwiftUI's, released on the
        // main thread.)
        // Global resources (the shared audio session, Now Playing) are torn
        // down ONLY if this model's narration was still live — SwiftUI
        // releases a departed reader's model lazily, often after the next
        // reader has started its own narration, and an unconditional teardown
        // here deactivated the session out from under the live voice.
        let wasNarrating = (narration?.status ?? .idle) != .idle
        ticker?.invalidate()
        narration?.stop()
        if wasNarrating {
            router?.endAudioSession()
        }
        #if os(iOS)
        // The command centre must not accumulate dead targets. Inlined rather
        // than calling `clearNowPlaying()`/`releaseRemoteCommands()` — those
        // are main-actor methods a nonisolated deinit can't call;
        // `MPNowPlayingInfoCenter` and `MPRemoteCommand.removeTarget` don't
        // need it. (The one piece left to the next session is
        // `endReceivingRemoteControlEvents`, which does need the main actor;
        // `registerRemoteCommands` re-begins it idempotently.)
        if wasNarrating {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        for (command, target) in remoteTargets {
            command.removeTarget(target)
        }
        #endif
    }

    // MARK: - Session

    /// Start (or restart) narration at a reading position — the Listen button.
    func start(book: Book, chapterIndex: Int, characterOffset: Int) {
        let narration = makeNarration(for: book)
        // Every start, not just the first: `stop()` hands the remote commands
        // back, and `makeNarration` early-returns for a book already set up —
        // so registering only there left the lock-screen and headphone
        // controls dead for every listening session after the first.
        // Idempotent (see the guard inside).
        registerRemoteCommands()
        narration.start(atChapter: chapterIndex, characterOffset: characterOffset)
        startTicking()
        refresh()
        updateNowPlaying()
        requestHoldNotificationsIfNeeded()
    }

    /// Tear narration down: closing the Listen bar, or leaving the reader.
    func stop() {
        // Same rule as deinit: only a model whose narration was live may
        // release the process-global session and lock-screen entry — a stale
        // model stopping must not silence another reader's voice.
        let wasNarrating = (narration?.status ?? .idle) != .idle
        narration?.stop()
        ticker?.invalidate()
        ticker = nil
        if wasNarrating {
            router?.endAudioSession()
            clearNowPlaying()
        }
        releaseRemoteCommands()
        refresh()
    }

    private func makeNarration(for book: Book) -> NarrationController {
        if let existing = narration, self.book?.id == book.id { return existing }

        self.book = book
        let selector = VoiceSelector()
        let installed = AVSpeechEngine.availableVoices()
        // A book that declares no language — most PDFs, plenty of EPUBs — would
        // otherwise offer every voice installed on the device, in every
        // language: a list well past a hundred rows on a stock iPhone, which is
        // not a picker so much as a wall. Fall back to the reader's own locale,
        // since a book whose language nobody recorded is most likely in the one
        // they read in.
        // Either spelling of this carries extensions a region override adds —
        // "en_US@rg=inzzzz" from `.identifier`, "en-US-u-rg-inzzzz" from the
        // BCP-47 form — and `SpeechVoice.normalized` strips both before
        // matching. Without that the exact-locale branch can never succeed on
        // such a device and every lookup falls through to a language-wide one.
        let language = book.metadata.language ?? Locale.current.identifier(.bcp47)
        let supportsReadrVoice = KokoroSpeechEngine.supports(language: language)
        // Offered when either Kokoro runtime can serve: MLX on an iOS device,
        // CoreML on a Mac outside the BNNS crash gate.
        let readrVoiceAvailable = supportsReadrVoice && RoutingSpeechEngine.isReadrVoiceAvailable
        // What the platform would pick for this language, which is a better
        // judge of "the sensible voice" than any ranking of ours: macOS ships
        // novelty voices that tie on quality and win on name.
        //
        // Asked with the extensions stripped, because AVFoundation *honours* a
        // region override rather than ignoring it: given `en-US-u-rg-inzzzz` it
        // answers Rishi (en-IN), which is not in the en-US pool the picker
        // lists — so the voice the picker checked and the voice at the top of
        // it were two different voices. Our own matching normalizes on the way
        // in, so `voices(matching:)` and `voice(for:)` still take the raw tag.
        let systemDefault = AVSpeechEngine.systemDefaultVoiceID(
            for: SpeechVoice.withoutExtensions(language)
        )
        var offered = selector.voices(
            matching: language, in: installed, systemDefault: systemDefault
        )
        // "Readr Voice" — the bundled Kokoro neural narrator, the DEFAULT for
        // English books (its model — ~104MB on a Mac, ~410MB on an iPhone or
        // iPad — downloads on first Listen; the router reads through the
        // platform voice until it's in — see RoutingSpeechEngine.speak).
        if readrVoiceAvailable {
            offered.insert(KokoroSpeechEngine.pickerVoice, at: 0)
        }
        voices = offered
        readrVoiceOffered = readrVoiceAvailable
        // Resolve from the PERSISTED preference ONLY — never the session's
        // last resolution. `voiceID` is per-book (a French book resolves to a
        // French voice), and any fallback to it lets one book in another
        // language veto the choice — or the un-persisted default — for every
        // later English book in the session. Defaults are written on every
        // explicit pick, so they are the whole story.
        let preferred = defaults.string(forKey: Self.voiceKey)
        readrVoiceUnavailable = supportsReadrVoice
            && !RoutingSpeechEngine.isReadrVoiceAvailable
            && (preferred == nil || KokoroSpeechEngine.isKokoroVoiceID(preferred))
        if readrVoiceAvailable,
           preferred == nil || KokoroSpeechEngine.isKokoroVoiceID(preferred) {
            // Readr Voice is the default narrator for English books — a
            // reader with no stored choice gets it, and a stored Readr Voice
            // pick keeps it. Only an explicit platform-voice choice (below)
            // overrides. The download starts with the first spoken sentence
            // (the engine waits for it); no separate prepare needed here.
            voiceID = KokoroSpeechEngine.isKokoroVoiceID(preferred)
                ? preferred : KokoroSpeechEngine.defaultVoiceID
        } else {
            // A stored voice may have been deleted since (voices are
            // downloadable), and a book in another language needs one that
            // can read it.
            // A Readr Voice id is not an installed platform voice. UserDefaults
            // is deliberately not rewritten, so the choice returns wherever a
            // Kokoro runtime can serve again.
            let platformPreferred = KokoroSpeechEngine.isKokoroVoiceID(preferred) ? nil : preferred
            voiceID = selector.voice(
                for: language, in: installed, preferring: platformPreferred,
                systemDefault: systemDefault
            )?.id
        }
        // The picker hides the accessibility/novelty families, but a stored
        // choice of one still narrates (an accessibility reader who set up
        // Eloquence keeps it) — so the picker must show that truth: append
        // the chosen voice when curation dropped it, or the menu would show
        // no checkmark at all.
        if let chosen = voiceID, !voices.contains(where: { $0.id == chosen }),
           let installedChoice = installed.first(where: { $0.id == chosen }) {
            voices.append(installedChoice)
        }

        let controller = NarrationController(
            book: book,
            engine: engine,
            settings: SpeechSettings(rate: rate, voiceID: voiceID)
        )
        controller.lookaheadHorizon = lookaheadHorizon()
        controller.onStatusChange = { [weak self] _ in
            self?.refresh()
            self?.updateNowPlaying()
        }
        controller.onPositionChange = { [weak self] position in
            self?.onPosition?(position)
            self?.refresh()
        }
        narration = controller
        registerRemoteCommands()
        return controller
    }

    // MARK: - Controls

    func togglePlayPause() {
        if narration?.isUnderway == true {
            pause()
        } else {
            play()
        }
    }

    func play() {
        retryReadrVoiceIfFailed()
        narration?.play()
        refresh()
    }

    /// The bar's Retry after a failed Readr Voice download: fetch again and
    /// pick narration back up on the same sentence.
    func retryReadrVoice() {
        play()
    }

    /// A Readr Voice request must never reach an engine that has given up —
    /// the policy's backstop would hand it to an Apple voice. So every play
    /// that would speak Readr Voice re-prepares a failed engine first; the
    /// engine leaves `.failed` synchronously, and the sentence routes to it
    /// and waits. Nothing to do when the engine is fine.
    private func retryReadrVoiceIfFailed() {
        guard usesReadrVoice, router?.readrVoiceReadiness == .failed else { return }
        router?.prepareKokoro()
    }

    func pause() {
        narration?.pause()
        refresh()
    }

    func skipForward() {
        narration?.skipToNextSentence()
        refresh()
    }

    func skipBackward() {
        narration?.skipToPreviousSentence()
        refresh()
    }

    func nextChapter() {
        narration?.skipToNextChapter()
        refresh()
    }

    func previousChapter() {
        narration?.skipToPreviousChapter()
        refresh()
    }

    func setRate(_ value: Double) {
        narration?.settings.rate = value
        // Read back rather than storing what was asked for — the settings
        // clamp it.
        rate = narration?.settings.rate ?? SpeechSettings(rate: value).rate
        defaults.set(rate, forKey: Self.rateKey)
        refresh()
    }

    /// Step to the next offered speed — the one-tap speed control.
    func cycleRate() {
        let current = narration?.settings ?? SpeechSettings(rate: rate)
        setRate(current.cyclingRate())
    }

    func setVoice(_ id: String?) {
        voiceID = id
        // Picking Readr Voice after a failure is the other Retry: re-prepare
        // BEFORE the settings change re-speaks the sentence, so the
        // re-spoken request finds an engine that is trying, not the backstop.
        if KokoroSpeechEngine.isKokoroVoiceID(id) {
            router?.prepareKokoro()
        }
        narration?.settings.voiceID = id
        if let id {
            defaults.set(id, forKey: Self.voiceKey)
        } else {
            defaults.removeObject(forKey: Self.voiceKey)
        }
        refresh()
    }

    func setSleepTimer(_ mode: SleepTimer) {
        narration?.setSleepTimer(mode)
        refresh()
    }

    // MARK: - State

    private func refresh() {
        guard let narration else {
            status = .idle
            currentSentence = ""
            chapterProgress = 0
            sleepMode = .off
            sleepRemaining = nil
            secondsAhead = 0
            holdReason = nil
            announcedHold = false
            return
        }
        status = narration.status
        holdReason = narration.holdReason
        if holdReason == nil {
            announcedHold = false
        } else if !announcedHold {
            announcedHold = true
            announceHold()
        }
        secondsAhead = usesReadrVoice
            ? (router?.secondsBuffered(ahead: narration.lookahead) ?? 0) : 0
        // Muted footnote markers leave runs of spaces in segment text
        // (length-preserving by design); collapse them for display only.
        // The contains-check matters: refresh runs on a once-a-second tick,
        // and the common sentence has no marker — don't pay a regex per tick.
        let sentence = narration.currentSegment?.text ?? ""
        currentSentence = sentence.contains("  ")
            ? sentence.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            : sentence
        chapterProgress = narration.chapterProgress
        sleepMode = narration.sleepTimer.mode
        sleepRemaining = narration.sleepTimerRemaining()
    }

    /// The sleep timer has no clock of its own — this is it. Also refreshes
    /// the countdown readout.
    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.narration?.tick()
                self.refresh()
            }
        }
    }

    // MARK: - Lookahead horizon

    /// An hour of listening, or the rest of the book while the device is
    /// charging — synthesis ahead costs battery, and a phone on a charger
    /// has none to save.
    private func lookaheadHorizon() -> NarrationController.LookaheadHorizon {
        #if os(iOS)
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return .restOfBook
        case .unplugged, .unknown:
            return .seconds(NarrationController.defaultLookaheadSeconds)
        @unknown default:
            return .seconds(NarrationController.defaultLookaheadSeconds)
        }
        #else
        return .seconds(NarrationController.defaultLookaheadSeconds)
        #endif
    }

    private func applyLookaheadHorizon() {
        narration?.lookaheadHorizon = lookaheadHorizon()
    }

    // MARK: - Holding for the foreground

    /// The app is back: a hold for the foreground resumes itself, and its
    /// notification, if one was posted, has served its purpose.
    private func didReturnToForeground() {
        #if os(iOS)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.holdNotificationID]
        )
        #endif
        guard narration?.holdReason == .needsForeground else { return }
        play()
    }

    /// Permission to say "Unlock Readr to keep listening" from the lock
    /// screen, asked once, the first time Listen is used with Readr Voice on
    /// a device where the hold can happen. Declined means the hold is
    /// silent: narration simply pauses.
    private func requestHoldNotificationsIfNeeded() {
        #if os(iOS)
        guard readrVoiceKeepsReadingWhenLocked, usesReadrVoice,
              !defaults.bool(forKey: Self.notificationsRequestedKey) else { return }
        defaults.set(true, forKey: Self.notificationsRequestedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// Narration held on its own. With the app backgrounded the bar cannot
    /// be seen, so the reason is posted where it can — and the lock screen's
    /// Now Playing carries it too.
    private func announceHold() {
        #if os(iOS)
        guard let holdText, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = holdText
        content.body = "Readr Voice ran out of prepared audio while the screen was locked."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.holdNotificationID, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    // MARK: - Lock screen & headphone controls

    #if os(iOS)
    /// Command/target pairs to unregister when narration ends, so opening a
    /// second book doesn't stack another set of handlers on the shared centre.
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    private func registerRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        let centre = MPRemoteCommandCenter.shared()

        func register(
            _ command: MPRemoteCommand, _ action: @escaping (NarrationModel) -> Void
        ) {
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in action(self) }
                return .success
            }
            remoteTargets.append((command, target))
        }

        register(centre.playCommand) { $0.play() }
        register(centre.pauseCommand) { $0.pause() }
        register(centre.togglePlayPauseCommand) { $0.togglePlayPause() }
        register(centre.nextTrackCommand) { $0.nextChapter() }
        register(centre.previousTrackCommand) { $0.previousChapter() }
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func releaseRemoteCommands() {
        for (command, target) in remoteTargets {
            command.removeTarget(target)
        }
        remoteTargets.removeAll()
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func updateNowPlaying() {
        guard let book, isActive else {
            clearNowPlaying()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.metadata.title,
            // Preparing counts as playing here, so the lock screen shows a
            // pause control for the wait rather than a play control that
            // would do nothing.
            MPNowPlayingInfoPropertyPlaybackRate: isUnderway ? rate : 0,
        ]
        if !book.metadata.authors.isEmpty {
            info[MPMediaItemPropertyArtist] = book.metadata.authors.joined(separator: ", ")
        }
        // A hold takes the second line: the lock screen is where the reader
        // is when it happens.
        if let holdText {
            info[MPMediaItemPropertyArtist] = holdText
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    #else
    // macOS narration runs in the app's own window; there is no lock screen to
    // publish to.
    private func registerRemoteCommands() {}
    private func releaseRemoteCommands() {}
    private func updateNowPlaying() {}
    private func clearNowPlaying() {}
    #endif
}
