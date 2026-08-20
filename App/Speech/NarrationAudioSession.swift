import Foundation
import AVFoundation
import ReadrKit

/// The one audio session narration uses, shared by every speech engine.
///
/// Spoken-audio playback: narration keeps going with the screen locked and
/// ducks other audio rather than being ducked by it. Owned here rather than
/// per-engine because the session is process-global — two engines each
/// activating and deactivating it independently meant the policy was defined
/// twice (and drifted), `setActive` round-tripped to mediaserverd on every
/// sentence, and closing the Listen bar deactivated the same session twice.
/// The `isActive` flag makes activation once-per-listening-session; the
/// router's `endAudioSession()` is the single deactivation point.
///
/// macOS has no audio session to configure. Main-thread-confined, like the
/// engines that call it (deinit teardown included — the last reference to a
/// narration model is SwiftUI's, released on the main thread).
enum NarrationAudioSession {
    #if os(iOS)
    nonisolated(unsafe) private static var isActive = false

    static func activate() {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            isActive = true
        } catch {
            // Narration still plays through whatever session is current; only
            // background and lock-screen playback are lost, which is not worth
            // failing the whole feature over.
            DiagnosticsLog.shared.record(
                .warning, .reader, "Narration audio session unavailable", error: error
            )
        }
    }

    static func deactivate() {
        guard isActive else { return }
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
    #else
    static func activate() {}
    static func deactivate() {}
    #endif
}

/// Hop to the main thread for a speech-engine delegate callback. AVFoundation
/// does not promise which thread its delegates arrive on, and everything
/// downstream — the controller and the SwiftUI state it drives — is
/// main-thread-confined. Shared so the contract lives in one place.
func onNarrationMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
        work()
    } else {
        DispatchQueue.main.async(execute: work)
    }
}
