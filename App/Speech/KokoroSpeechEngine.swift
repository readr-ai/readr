import Foundation
import AVFoundation
import FluidAudio
import ReadrKit

/// "Readr Voice (Beta)": Kokoro-82M neural narration behind ReadrKit's
/// `SpeechEngine` protocol, via FluidAudio's CoreML port (Apache-2.0,
/// espeak-free G2P). See docs/ROADMAP.md M10 — the A/B listen chose Kokoro
/// over the platform voices decisively.
///
/// Deliberately an *opt-in* voice, never the default: the ~104MB model
/// downloads on first use (the store copy's "nothing to download" holds for
/// the Apple-voice default), the G2P model's licence question is still with
/// legal, and FluidAudio warns of an intermittent BNNS crash on current iOS
/// (FluidAudio#844). Wiring it as one more voice in the picker keeps every
/// one of those a per-voice concern instead of a narration-wide one.
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
/// `KokoroAneManager` actor and back.
final class KokoroSpeechEngine: NSObject, SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    // MARK: - The picker's view of this engine

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
        name: "Readr Voice (Beta)",
        language: "en-US",
        quality: .premium,
        family: .modern
    )

    /// English only for now: af_heart is an English voice, and the spike only
    /// validated the espeak-free G2P path for English.
    static func supports(language: String?) -> Bool {
        guard let language else { return false }
        return SpeechVoice.withoutExtensions(language).lowercased().hasPrefix("en")
    }

    /// Kokoro voice-pack name from a sentinel id ("af_heart").
    private static func kokoroVoice(from id: String?) -> String {
        guard let id, isKokoroVoiceID(id) else { return "af_heart" }
        return String(id.dropFirst(voiceIDPrefix.count))
    }

    // MARK: - State

    private let manager = KokoroAneManager()
    private var initializeTask: Task<Void, Error>?
    private var player: AVAudioPlayer?
    /// The request being synthesized or played. Non-nil is what makes `state`
    /// report `.speaking` through the synthesis gap.
    private var activeRequest: SpeechRequest?
    private var synthesisTask: Task<Void, Never>?
    /// The controller paused while we were still synthesizing — hold the
    /// finished audio instead of starting it.
    private var pausedByCaller = false

    var state: SpeechEngineState {
        guard activeRequest != nil else { return .idle }
        return pausedByCaller ? .paused : .speaking
    }

    // MARK: - SpeechEngine

    func speak(_ request: SpeechRequest) {
        cancelInFlight()
        activeRequest = request
        pausedByCaller = false
        activateAudioSession()
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
        player?.play()
    }

    func stop() {
        cancelInFlight()
        activeRequest = nil
        pausedByCaller = false
        // The audio session stays up between sentences for the same reason
        // AVSpeechEngine's does; `endAudioSession()` ends it for real.
    }

    /// Start the model download/load without speaking — called when the
    /// reader picks this voice, so the first sentence doesn't carry the whole
    /// ~104MB wait.
    func prepare() {
        Task { @MainActor [weak self] in
            try? await self?.ensureInitialized()
        }
    }

    func endAudioSession() {
        deactivateAudioSession()
    }

    // MARK: - Synthesis

    @MainActor
    private func synthesizeThenPlay(_ request: SpeechRequest) async {
        do {
            try await ensureInitialized()
            // A skip/stop may have replaced this request during the wait.
            guard activeRequest?.id == request.id else { return }
            let wav = try await manager.synthesize(
                text: request.text,
                voice: Self.kokoroVoice(from: request.voiceID),
                // Kokoro takes the reader's multiplier directly — no
                // platform-rate curve like AVFoundation's.
                speed: Float(min(max(request.rate, 0.5), 2.0))
            )
            guard activeRequest?.id == request.id else { return }
            let player = try AVAudioPlayer(data: wav)
            player.volume = Float(min(max(request.volume, 0), 1))
            player.delegate = self
            self.player = player
            if pausedByCaller {
                player.prepareToPlay()
            } else {
                player.play()
            }
        } catch is CancellationError {
            // A skip/stop cancelled us; the controller already moved on.
        } catch {
            guard activeRequest?.id == request.id else { return }
            activeRequest = nil
            player = nil
            delegate?.speechEngine(self, didFail: request.id, error: error)
        }
    }

    @MainActor
    private func ensureInitialized() async throws {
        if let initializeTask {
            return try await initializeTask.value
        }
        let task = Task { try await manager.initialize() }
        initializeTask = task
        do {
            try await task.value
        } catch {
            // A failed download must not poison every later attempt.
            initializeTask = nil
            throw error
        }
    }

    private func cancelInFlight() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
    }

    // MARK: - Audio session

    /// Same session policy as `AVSpeechEngine`: spoken audio that keeps
    /// playing with the screen locked. macOS has no session to configure.
    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            DiagnosticsLog.shared.record(
                .warning, .reader, "Narration audio session unavailable", error: error
            )
        }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

// MARK: - AVAudioPlayerDelegate

extension KokoroSpeechEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onMain { [weak self] in
            guard let self, player === self.player,
                  let request = self.activeRequest else { return }
            self.player = nil
            self.activeRequest = nil
            self.delegate?.speechEngine(self, didFinish: request.id)
        }
    }

    /// Delegate thread is unspecified; everything downstream is
    /// main-thread-confined (same contract as `AVSpeechEngine`).
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
