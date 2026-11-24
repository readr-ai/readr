package com.readrai.readr

import android.inputmethodservice.InputMethodService
import android.view.View

/**
 * A keyboard that is never on screen — the one [ReadrTestRunner] switches the
 * phone to for the length of an instrumented run.
 *
 * Nothing in this suite types on a *soft* keyboard: `performTextInput` hands
 * Compose the characters directly. What the on-screen keyboard does bring is
 * a window that slides up over the page, and on CI's 320×640 emulator that
 * transition intermittently never finishes — the app's `ViewRootImpl` goes on
 * scheduling frames for a resize that never lands, so the main looper is
 * never idle, and Compose's `waitForIdle` (inside every `performClick`,
 * `performScrollToNode`, `assertExists`) waits on `Espresso.onIdle()`, which
 * has no timeout. That is a test that hangs until the CI job's own cap
 * instead of failing: run 34167244349 sat for 74 minutes on
 * `AskSheetTest.aFailedTurnKeepsItsReasonInTheTranscript`.
 *
 * An input method that declines to show an input view has no such window, so
 * there is no transition to wedge. The reader's own keyboard is put back when
 * the run ends (see [ReadrTestRunner]).
 */
class NoInputMethod : InputMethodService() {

    /** A view is required; a zero-size one that is never shown will do. */
    override fun onCreateInputView(): View = View(this)

    /** The whole point: no window ever slides up over the app. */
    override fun onEvaluateInputViewShown(): Boolean = false

    override fun onEvaluateFullscreenMode(): Boolean = false
}
