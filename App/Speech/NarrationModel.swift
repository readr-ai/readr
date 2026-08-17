import Foundation
import Combine
import ReadrKit

#if os(iOS)
import MediaPlayer
import UIKit
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

    /// Where the voice is — the reader follows this to keep the page under it.
    var onPosition: ((NarrationPosition) -> Void)?

    private let defaults: UserDefaults
    /// The synthesizer behind narration. `-uiTestSilentNarration` swaps in a
    /// soundless stand-in so UI tests drive the real pipeline deterministically
    /// (see `UITestStubSpeechEngine`); normal launches always get AVFoundation.
    private let engine: any SpeechEngine
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

    /// Name of the chosen voice, for the picker's label.
    var voiceName: String? {
        guard let voiceID else { return nil }
        return voices.first { $0.id == voiceID }?.name
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if UITestStubSpeechEngine.isEnabled {
            self.engine = UITestStubSpeechEngine()
        } else {
            self.engine = AVSpeechEngine()
        }
        // Speed and voice are the reader's, not the book's — carried across
        // books the way the reading theme is.
        self.rate = defaults.object(forKey: Self.rateKey) as? Double ?? 1
        self.voiceID = defaults.string(forKey: Self.voiceKey)
    }

    deinit {
        ticker?.invalidate()
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
    }

    /// Tear narration down: closing the Listen bar, or leaving the reader.
    func stop() {
        narration?.stop()
        ticker?.invalidate()
        ticker = nil
        (engine as? AVSpeechEngine)?.endAudioSession()
        clearNowPlaying()
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
        // What the platform would pick for this language, which is a better
        // judge of "the sensible voice" than any ranking of ours: macOS ships
        // novelty voices that tie on quality and win on name.
        let systemDefault = AVSpeechEngine.systemDefaultVoiceID(for: language)
        voices = selector.voices(
            matching: language, in: installed, systemDefault: systemDefault
        )
        // A stored voice may have been deleted since (voices are downloadable),
        // and a book in another language needs one that can read it.
        voiceID = selector.voice(
            for: language, in: installed, preferring: voiceID, systemDefault: systemDefault
        )?.id

        let controller = NarrationController(
            book: book,
            engine: engine,
            settings: SpeechSettings(rate: rate, voiceID: voiceID)
        )
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
        narration?.togglePlayPause()
        refresh()
    }

    func play() {
        narration?.play()
        refresh()
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
            return
        }
        status = narration.status
        currentSentence = narration.currentSegment?.text ?? ""
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
            MPNowPlayingInfoPropertyPlaybackRate: isSpeaking ? rate : 0,
        ]
        if !book.metadata.authors.isEmpty {
            info[MPMediaItemPropertyArtist] = book.metadata.authors.joined(separator: ", ")
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
