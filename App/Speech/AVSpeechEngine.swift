import Foundation
import AVFoundation
import ReadrKit

/// `AVSpeechSynthesizer` behind ReadrKit's `SpeechEngine` protocol.
///
/// Apple's on-device voices are the right back end for Readr: they speak
/// without a network round trip, which keeps listening inside the same
/// zero-egress promise reading and local-LLM answers already make (PRIVACY.md)
/// — nothing about the book leaves the device to be read aloud. They are also
/// the only synthesizer that ships with the OS, so a reader gets narration with
/// nothing to download, and better voices are a system setting away
/// (Settings → Accessibility → Spoken Content → Voices).
///
/// Everything here is glue: choosing an utterance's voice, mapping the reader's
/// speed onto AVFoundation's scale, and translating boundary callbacks from
/// UTF-16 into the character offsets ReadrKit addresses text with. The playback
/// rules live in `NarrationController`, where they are testable.
final class AVSpeechEngine: NSObject, SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?

    private let synthesizer = AVSpeechSynthesizer()

    /// Asked of the synthesizer rather than tracked alongside it.
    ///
    /// This is what the controller's stall watchdog reads, and a completion
    /// callback going missing is exactly the case it exists for — so state kept
    /// in a variable that only those callbacks update would report "speaking"
    /// forever precisely when it mattered. `isSpeaking` stays true through the
    /// post-utterance delay, so a truthful idle here means the utterance really
    /// is over.
    var state: SpeechEngineState {
        if synthesizer.isPaused { return .paused }
        if synthesizer.isSpeaking { return .speaking }
        return .idle
    }
    /// The request being spoken, with the exact string handed to the engine —
    /// the boundary callback reports offsets into it.
    private var activeRequest: SpeechRequest?
    private var activeText = ""
    /// The utterance carrying `activeRequest`. Delegate callbacks arrive
    /// asynchronously from a background thread, so a callback for an utterance
    /// this engine already replaced can land *after* the swap — matching on
    /// the request alone attributed that stale callback to the new request,
    /// which finished sentences the voice never spoke and moved word
    /// boundaries into the wrong text. Only callbacks for this exact utterance
    /// count; everything else is stale by construction.
    private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - SpeechEngine

    func speak(_ request: SpeechRequest) {
        // Replace whatever is in flight. The cancellation callback that
        // follows is deliberately not reported as a finish.
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activateAudioSession()

        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = Self.voice(for: request)
        utterance.rate = Float(request.rate.platformSpeechRate)
        utterance.pitchMultiplier = Float(min(max(request.pitch, 0.5), 2.0))
        utterance.volume = Float(min(max(request.volume, 0), 1))
        // A beat between sentences: narration reads one sentence per utterance,
        // and back-to-back utterances otherwise run together.
        utterance.postUtteranceDelay = 0.05

        activeRequest = request
        activeText = request.text
        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    /// Deliberately unguarded (`pauseSpeaking`/`continueSpeaking` are no-ops
    /// when they don't apply): a pause at a word boundary lands
    /// asynchronously, so `isPaused` still reads false for a moment after the
    /// reader taps pause. Gating resume on it would swallow a quick
    /// pause-then-play and leave the controller believing it is speaking while
    /// the synthesizer sits paused. The controller is the authority on state.
    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        activeRequest = nil
        activeText = ""
        activeUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // The audio session deliberately stays up: `stop()` is what every
        // interrupting control does before speaking the next sentence, and
        // tearing the session down and back up between sentences makes other
        // audio duck in and out. `endAudioSession()` ends it for real.
    }

    /// Narration is over (the Listen bar closed): hand the audio session back.
    func endAudioSession() {
        deactivateAudioSession()
    }

    // MARK: - Voices

    /// Every installed voice, in ReadrKit's platform-agnostic shape.
    static func availableVoices() -> [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            SpeechVoice(
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: quality(of: voice),
                family: family(of: voice)
            )
        }
    }

    /// Which generation of voice this is, from its identifier's family prefix.
    ///
    /// macOS installs three side by side and reports them all at the same
    /// quality tier, so the identifier is the only thing that separates a
    /// narration voice from a novelty one. On the machine this was measured on:
    /// six `com.apple.voice.*` (Daniel, Karen, Moira, Rishi, Samantha, Tessa —
    /// exactly the voices you would read a book in), sixteen
    /// `com.apple.eloquence.*` (DECtalk-style, legitimate for accessibility but
    /// not for an hour of prose), and the `com.apple.speech.synthesis.voice.*`
    /// legacy set that holds Albert, Bad News and Bubbles — the same family
    /// whose speaking-rate curve is 26–39% off the others.
    ///
    /// A prefix rather than a list of names, so it keeps working when Apple
    /// ships more of any of them. Anything unrecognised is treated as modern:
    /// a new family is far more likely to be a real voice than a joke one.
    private static func family(of voice: AVSpeechSynthesisVoice) -> SpeechVoice.Family {
        if voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.") { return .legacy }
        if voice.identifier.hasPrefix("com.apple.eloquence.") { return .alternate }
        return .modern
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> SpeechVoice.Quality {
        switch voice.quality {
        case .enhanced: return .enhanced
        case .premium: return .premium
        default: return .standard
        }
    }

    /// The voice the platform itself would use for a language — Samantha for
    /// en-US, not Albert. `NarrationModel` feeds this to `VoiceSelector` as the
    /// tie-break, because on macOS every English voice reports the same quality
    /// tier and the alphabetical fallback picked novelty voices.
    static func systemDefaultVoiceID(for language: String?) -> String? {
        guard let language else { return nil }
        return AVSpeechSynthesisVoice(language: language)?.identifier
    }

    /// The named voice if it is still installed, else the platform's default
    /// for the book's language, else nil — which leaves AVFoundation to use the
    /// device default rather than refusing to speak.
    ///
    /// No ranking happens here: `NarrationModel` already chose, with the whole
    /// installed list and the reader's stored preference in hand. Choosing
    /// again from a second, subtly different rule was how an English book ended
    /// up in a novelty voice.
    private static func voice(for request: SpeechRequest) -> AVSpeechSynthesisVoice? {
        if let voiceID = request.voiceID,
           let named = AVSpeechSynthesisVoice(identifier: voiceID) {
            return named
        }
        guard let language = request.language else { return nil }
        return AVSpeechSynthesisVoice(language: language)
    }

    // MARK: - Audio session

    /// Spoken-audio playback: narration keeps going with the screen locked and
    /// ducks other audio rather than being ducked by it. macOS has no audio
    /// session to configure.
    private func activateAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            // Narration still plays through whatever session is current; only
            // background and lock-screen playback are lost, which is not worth
            // failing the whole feature over.
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

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechEngine: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        onMain { [weak self] in
            guard let self, utterance === self.activeUtterance,
                  let request = self.activeRequest else { return }
            self.activeRequest = nil
            self.activeUtterance = nil
            self.delegate?.speechEngine(self, didFinish: request.id)
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        // Cancellation is always something the controller asked for (a skip, a
        // speed change, the sleep timer). Reporting it as a finish would
        // advance the book by a sentence the reader never heard.
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        onMain { [weak self] in
            guard let self, utterance === self.activeUtterance,
                  let request = self.activeRequest,
                  // AVFoundation reports UTF-16 offsets; ReadrKit addresses
                  // text by character — the same conversion the selection code
                  // does.
                  let range = TextRangeConvert.characterRange(
                      from: characterRange, in: self.activeText
                  )
            else { return }
            self.delegate?.speechEngine(self, willSpeak: range, of: request.id)
        }
    }

    /// AVFoundation does not promise which thread delegate callbacks arrive
    /// on, and everything downstream — the controller and the SwiftUI state it
    /// drives — is main-thread-confined.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

// MARK: - Rate mapping

private extension Double {
    /// The reader's speed multiplier on AVFoundation's 0...1 rate scale, where
    /// `AVSpeechUtteranceDefaultSpeechRate` (0.5) is the voice's normal pace.
    var platformSpeechRate: Double {
        SpeechSettings(rate: self).platformRate(
            normal: Double(AVSpeechUtteranceDefaultSpeechRate),
            minimum: Double(AVSpeechUtteranceMinimumSpeechRate),
            maximum: Double(AVSpeechUtteranceMaximumSpeechRate)
        )
    }
}
