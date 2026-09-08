package com.readrai.readr

import android.app.Instrumentation
import android.os.Bundle
import android.util.Log
import androidx.test.runner.AndroidJUnitRunner
import java.io.FileInputStream

/**
 * The runner every instrumented test runs under.
 *
 * It does one thing before the suite: switches the phone to [NoInputMethod],
 * a keyboard that never puts a window on screen, and puts the reader's own
 * back afterwards. The reason is in [NoInputMethod] — a soft keyboard's show
 * transition can wedge on a small screen, and a wedged one turns Compose's
 * unbounded `waitForIdle` into a test that never returns.
 *
 * The other half of that guard is not here but in `app/build.gradle.kts`:
 * `timeout_msec`, which fails any test that outlives it. This class removes
 * the known cause; the timeout catches the next one.
 *
 * Every command runs through `uiAutomation`, which executes as the shell user
 * — the only way an instrumented test may touch secure settings. A failure to
 * switch is logged rather than thrown: the suite is worth running with the
 * phone's own keyboard, it is only less reliable, and the timeout still holds.
 */
class ReadrTestRunner : AndroidJUnitRunner() {

    private var previousMethod: String? = null

    override fun onStart() {
        previousMethod = shell("settings get secure default_input_method").trim()
            .takeIf { it.isNotEmpty() && it != "null" }
        val enabled = shell("ime enable $NO_INPUT_METHOD")
        val set = shell("ime set $NO_INPUT_METHOD")
        val active = shell("settings get secure default_input_method").trim()
        if (active != NO_INPUT_METHOD) {
            Log.w(TAG, "could not silence the keyboard: enable=$enabled set=$set active=$active")
        }
        super.onStart()
    }

    override fun finish(resultCode: Int, results: Bundle?) {
        previousMethod?.let { shell("ime set $it") }
        shell("ime disable $NO_INPUT_METHOD")
        super.finish(resultCode, results)
    }

    private fun shell(command: String): String = runCatching {
        val fd = (this as Instrumentation).uiAutomation.executeShellCommand(command)
        FileInputStream(fd.fileDescriptor).use { it.readBytes().decodeToString() }
    }.getOrElse { failure ->
        Log.w(TAG, "shell command failed: $command", failure)
        ""
    }

    private companion object {
        const val TAG = "Readr.TestRunner"
        const val NO_INPUT_METHOD = "com.readrai.readr.test/com.readrai.readr.NoInputMethod"
    }
}
