import Foundation
import AVFoundation
import ReadrKit

/// What a synthesizer hands the player for one sentence.
enum PlayableAudio {
    /// Nothing to say (a punctuation-only "sentence"): finished at once.
    case nothing
    /// WAV bytes at the speed they were synthesized at — the CoreML engine,
    /// which bakes the reader's speed into the synthesis.
    case data(Data)
    /// A compressed file synthesized at 1×, played at `rate` — the MLX
    /// engine's buffer, where one file serves every speed.
    case file(URL, rate: Float)
}

/// The one `AVAudioPlayer` contract behind both Kokoro engines — CoreML on
/// macOS, MLX on iPhone and iPad. Each engine supplies a `synthesize`
/// closure that turns a request into playable audio; everything after that
/// (the synthesis gap, the activate-then-play step, pause/resume/stop, the
/// refused-play failure, both `AVAudioPlayerDelegate` callbacks) lives here
/// once, so the two engines cannot drift apart on the parts that were
/// hardened over three releases:
///
/// - `activeRequest != nil` is what makes `state` report `.speaking` through
///   the synthesis gap (and, on first use, the model download), so
///   `NarrationController`'s silent-engine watchdog doesn't mistake the wait
///   for a finished utterance.
/// - `state` reads `player.isPlaying`, not a flag of ours: an audio
///   interruption (phone call, Siri) pauses an `AVAudioPlayer` silently — no
///   delegate callback, no auto-resume — and a self-reported `.speaking`
///   would blind the watchdog.
/// - A refused `play()` is a `didFail`, not a silent no-op the watchdog has
///   to discover two ticks later.
/// - State is cleared BEFORE every hook fires, so a hook that starts the
///   next sentence sees an idle player.
///
/// Main-thread-confined like every engine; synthesis hops away and back.
final class SentenceAudioPlayer: NSObject {

    /// Audio for the request has started coming out — after the synthesis
    /// gap and, on first use, the model download. Fired on the main thread;
    /// also on every resume, which the controller ignores unless it was
    /// showing the wait.
    var onStart: ((UUID) -> Void)?
    /// Playback of the request finished (or there was nothing to play).
    /// Fired on the main thread with the player already idle.
    var onFinish: ((UUID) -> Void)?
    /// Synthesis or playback failed. Fired on the main thread with the player
    /// already idle.
    var onFail: ((UUID, any Error) -> Void)?

    private var player: AVAudioPlayer?
    /// The request being synthesized or played.
    private(set) var activeRequest: SpeechRequest?
    private var synthesisTask: Task<Void, Never>?
    /// The controller paused while we were still synthesizing — hold the
    /// finished audio instead of starting it.
    private var pausedByCaller = false
    /// A speed change that arrived for this request, applied to the player
    /// now if there is one and when it is made if not.
    private var rateOverride: Float?

    var state: SpeechEngineState {
        guard activeRequest != nil else { return .idle }
        if pausedByCaller { return .paused }
        if let player {
            return player.isPlaying ? .speaking : .paused
        }
        // Synthesizing (or, on first use, downloading the model). Reported as
        // speaking so the watchdog doesn't mistake the wait for a finished
        // utterance; a failed download/synthesis ends it via `onFail`.
        return .speaking
    }

    /// Whether `request` is still the one this player is on — for a
    /// `synthesize` closure to check after an await, since a skip/stop may
    /// have replaced it meanwhile.
    func isCurrent(_ request: SpeechRequest) -> Bool {
        activeRequest?.id == request.id
    }

    /// Synthesize, then play. A `CancellationError` from `synthesize` is a
    /// skip/stop the controller already moved on from and is reported to
    /// nobody; any other error is `onFail`.
    func speak(
        _ request: SpeechRequest,
        synthesize: @escaping @MainActor (SpeechRequest) async throws -> PlayableAudio
    ) {
        cancelInFlight()
        activeRequest = request
        pausedByCaller = false
        rateOverride = nil
        synthesisTask = Task { @MainActor [weak self] in
            await self?.synthesizeThenPlay(request, synthesize)
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
        guard let player, let request = activeRequest else { return }
        if player.play() {
            onStart?(request.id)
        } else {
            // Same contract as the speak path: a refused start is a failure,
            // not a silent no-op the watchdog has to discover two ticks later.
            self.player = nil
            activeRequest = nil
            onFail?(request.id, SpeechEngineError.audioUnavailable)
        }
    }

    func stop() {
        cancelInFlight()
        activeRequest = nil
        pausedByCaller = false
        rateOverride = nil
        // The audio session stays up between sentences for the same reason
        // AVSpeechEngine's does; `RoutingSpeechEngine.endAudioSession()` ends
        // it for real.
    }

    /// Change speed in place. Applies to the player if it is up, and to the
    /// one about to be made if the audio is still on its way. False with no
    /// request in hand — nothing to apply it to. Only meaningful for
    /// `.file` audio, which is synthesized at 1×; an engine that bakes speed
    /// into its synthesis does not offer this.
    func setRate(_ rate: Float) -> Bool {
        guard activeRequest != nil else { return false }
        rateOverride = rate
        if let player, player.enableRate {
            player.rate = rate
        }
        return true
    }

    // MARK: - Synthesis

    @MainActor
    private func synthesizeThenPlay(
        _ request: SpeechRequest,
        _ synthesize: @MainActor (SpeechRequest) async throws -> PlayableAudio
    ) async {
        do {
            let audio = try await synthesize(request)
            // A skip/stop may have replaced this request during synthesis.
            guard activeRequest?.id == request.id else { return }
            let player: AVAudioPlayer
            switch audio {
            case .nothing:
                // Nothing to play: report the finish now rather than handing
                // AVAudioPlayer a 44-byte header to reject.
                activeRequest = nil
                onFinish?(request.id)
                return
            case .data(let wav):
                guard !wav.isEmpty else {
                    activeRequest = nil
                    onFinish?(request.id)
                    return
                }
                player = try AVAudioPlayer(data: wav)
            case .file(let url, let rate):
                player = try AVAudioPlayer(contentsOf: url)
                player.enableRate = true
                player.rate = rateOverride ?? rate
            }
            // Claimed only once audio is ready to play: activating on
            // `speak()` interrupted whatever the reader was listening to for
            // the whole first-use model download, for nothing.
            NarrationAudioSession.activate()
            player.volume = Float(request.volume)
            player.delegate = self
            self.player = player
            if pausedByCaller {
                player.prepareToPlay()
            } else if player.play() {
                onStart?(request.id)
            } else {
                // The session refused to start audio; pretending to speak
                // would wedge narration on a silent "playing".
                self.player = nil
                activeRequest = nil
                onFail?(request.id, SpeechEngineError.audioUnavailable)
            }
        } catch is CancellationError {
            // A skip/stop cancelled us; the controller already moved on.
        } catch {
            guard activeRequest?.id == request.id else { return }
            activeRequest = nil
            player = nil
            onFail?(request.id, error)
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

extension SentenceAudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onNarrationMain { [weak self] in
            guard let self, player === self.player,
                  let request = self.activeRequest else { return }
            self.player = nil
            self.activeRequest = nil
            if flag {
                self.onFinish?(request.id)
            } else {
                // Playback died partway (route/decoder failure). Reporting a
                // finish would advance past text the listener never heard;
                // a failure holds narration in place instead.
                self.onFail?(request.id, SpeechEngineError.audioUnavailable)
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onNarrationMain { [weak self] in
            guard let self, player === self.player,
                  let request = self.activeRequest else { return }
            self.player = nil
            self.activeRequest = nil
            self.onFail?(request.id, error ?? SpeechEngineError.audioUnavailable)
        }
    }
}
