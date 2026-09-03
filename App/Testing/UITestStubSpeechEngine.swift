import Foundation
import ReadrKit

/// A speech engine that makes no sound, used ONLY when the app is launched
/// with `-uiTestSilentNarration`.
///
/// It exists for the same reason `UITestStubProvider` does: the UI tests need
/// to drive the real narration pipeline — the controller, the bar, the
/// follow-along page turns — without depending on something the CI simulator
/// can't be trusted to do. A real synthesizer on a headless runner may refuse
/// to speak and report every utterance finished immediately, which would race
/// narration to the end of the book before a test could tap anything.
///
/// It records the same state a real engine does and simply never completes an
/// utterance on its own, so narration stays exactly where a test put it.
/// Normal launches never construct it (see `NarrationModel`).
final class UITestStubSpeechEngine: SpeechEngine {
    weak var delegate: (any SpeechEngineDelegate)?
    private(set) var state: SpeechEngineState = .idle

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestSilentNarration")
    }

    /// `-uiTestNarrationPreparing`: every utterance reports `isPreparing` and
    /// never follows it with `didBeginSpeaking`, so the Listen bar's
    /// "Preparing Readr Voice…" state (ListenBar.preparingLine) can be
    /// asserted deterministically. A real first-use model download can't be
    /// driven from a UI test — this is the smallest hook that stands in for
    /// it, using the same `SpeechEngineDelegate.isPreparing` callback a real
    /// engine sends.
    static var preparingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestNarrationPreparing")
    }

    /// `-uiTestNarrationHold`: every utterance is immediately suspended for
    /// `.needsForeground`, so the hold state (ListenBar.holdLine, the
    /// Now Playing title) can be asserted without backgrounding the app for
    /// real — XCUITest cannot reliably drive a device background/foreground
    /// cycle against the buffer running out. Same `didSuspend` callback a
    /// real engine sends when it has nothing prepared.
    static var holdEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestNarrationHold")
    }

    func speak(_ request: SpeechRequest) {
        if Self.holdEnabled {
            state = .paused
            delegate?.speechEngine(self, didSuspend: request.id, reason: .needsForeground)
            return
        }
        state = .speaking
        if Self.preparingEnabled {
            delegate?.speechEngine(self, isPreparing: request.id)
        }
    }

    func pause() {
        state = .paused
    }

    func resume() {
        state = .speaking
    }

    func stop() {
        state = .idle
    }
}
