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

    func speak(_ request: SpeechRequest) {
        state = .speaking
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
