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

    /// Kokoro voice-pack name from a sentinel id ("af_heart").
    private static func kokoroVoice(from id: String?) -> String {
        guard let id, isKokoroVoiceID(id) else { return "af_heart" }
        return String(id.dropFirst(voiceIDPrefix.count))
    }

    // MARK: - Readiness

    /// Where the voice stands between "picked" and "audible": the model is a
    /// ~104MB first-use download, and the Listen bar shows this so the wait
    /// is never silent. While it isn't `.ready`, `RoutingSpeechEngine` narrates
    /// through the platform voice and switches over at a sentence boundary.
    enum Readiness: Equatable {
        case notReady
        case downloading
        case ready
        case failed
    }

    private(set) var readiness: Readiness = .notReady {
        didSet {
            guard readiness != oldValue else { return }
            onReadinessChange?(readiness)
        }
    }
    /// Fires on the main thread (readiness only changes inside @MainActor
    /// paths); the model publishes it to the Listen bar.
    var onReadinessChange: ((Readiness) -> Void)?
    var isReady: Bool { readiness == .ready }

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
        if pausedByCaller { return .paused }
        if let player {
            // The player's own state, not ours: an audio interruption (phone
            // call, Siri) pauses an AVAudioPlayer silently — no delegate
            // callback, no auto-resume. Self-reported state would say
            // `.speaking` forever and blind the controller's silent-engine
            // watchdog; reading the player lets the watchdog hold narration
            // as paused, exactly as it does for the platform synthesizer.
            return player.isPlaying ? .speaking : .paused
        }
        // Synthesizing (or, on first use, downloading the model). Reported as
        // speaking so the watchdog doesn't mistake the wait for a finished
        // utterance; a failed download/synthesis ends it via `didFail`.
        return .speaking
    }

    // MARK: - SpeechEngine

    func speak(_ request: SpeechRequest) {
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
            // Same contract as the speak path: a refused start is a failure,
            // not a silent no-op the watchdog has to discover two ticks later.
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
        // The audio session stays up between sentences for the same reason
        // AVSpeechEngine's does; `RoutingSpeechEngine.endAudioSession()` ends
        // it for real.
    }

    /// Start the model download/load without speaking — called when the
    /// reader picks this voice, so the first sentence doesn't carry the whole
    /// ~104MB wait.
    func prepare() {
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
            let wav = try await manager.synthesize(
                text: request.text,
                voice: Self.kokoroVoice(from: request.voiceID),
                // Kokoro takes the reader's multiplier directly — no
                // platform-rate curve like AVFoundation's. Already in range:
                // SpeechSettings is the single clamping authority (init,
                // didSet, and decode), and every request is built from it.
                speed: Float(request.rate)
            )
            guard activeRequest?.id == request.id else { return }
            // Claimed only once audio is ready to play: activating on
            // `speak()` interrupted whatever the reader was listening to for
            // the whole first-use model download, for nothing.
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
            delegate?.speechEngine(self, didFail: request.id, error: error)
        }
    }

    @MainActor
    private func ensureInitialized() async throws {
        if let initializeTask {
            return try await initializeTask.value
        }
        readiness = .downloading
        let task = Task { try await manager.initialize() }
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

    private func cancelInFlight() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
    }

}

// MARK: - AVAudioPlayerDelegate

extension KokoroSpeechEngine: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onNarrationMain { [weak self] in
            guard let self, player === self.player,
                  let request = self.activeRequest else { return }
            self.player = nil
            self.activeRequest = nil
            if flag {
                self.delegate?.speechEngine(self, didFinish: request.id)
            } else {
                // Playback died partway (route/decoder failure). Reporting a
                // finish would advance past text the listener never heard;
                // a failure holds narration in place instead.
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
