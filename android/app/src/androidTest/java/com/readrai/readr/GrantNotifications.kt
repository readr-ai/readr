package com.readrai.readr

import android.Manifest
import android.os.Build
import androidx.test.platform.app.InstrumentationRegistry

/**
 * Grant `POST_NOTIFICATIONS` before a test presses Listen.
 *
 * The reader is asked for it the first time they start the voice, and a system
 * dialog in the middle of an instrumented run is a test that hangs rather than
 * one that fails. Granting it up front is also the honest case to test: the
 * refusal path is that the voice reads anyway (a media-playback foreground
 * service shows its own notification either way), which is a claim about the
 * platform rather than about this code.
 */
fun grantNotifications() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    runCatching {
        instrumentation.uiAutomation.grantRuntimePermission(
            instrumentation.targetContext.packageName,
            Manifest.permission.POST_NOTIFICATIONS,
        )
    }
}
