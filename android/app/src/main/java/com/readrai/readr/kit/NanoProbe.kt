package com.readrai.readr.kit

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * What this phone can say about Gemini Nano — the kit's `OnDeviceProbe`, and
 * the only thing that decides whether the "On this phone" card offers a model
 * or explains why it cannot.
 *
 * The answer is a bare token: the sentence the reader sees is the kit's, and
 * lives in the facade, so this class never writes copy. What it can see is
 * the *system*: Android 14 or newer, and AICore actually installed (the app
 * declares that package in `<queries>`, or Android hides it).
 *
 * The stub matters: Firebase Test Lab devices (and some emulator images) ship
 * a `com.google.android.aicore` package that exists and does nothing, with
 * "stub" in its version name. Treating it as present would put a card on the
 * screen promising a model that is not there.
 */
class NanoProbe(context: Context) : OnDeviceProbe {
    private val packages = context.applicationContext.packageManager

    override fun readiness(): String = when {
        !hasSystemSupport() -> UNSUPPORTED
        // A3C REPLACES THIS BRANCH: it asks ML Kit whether the model is
        // downloaded and this app may drive it, and answers READY when it is.
        // Until then even a phone that could run Nano reports `unsupported` —
        // this build cannot drive the model, and any softer answer would let
        // the card be made active and point Ask at a provider that can only
        // refuse to answer.
        else -> UNSUPPORTED
    }

    /** Android 14+, and AICore installed — not the do-nothing stub. */
    private fun hasSystemSupport(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && hasAICore()

    private fun hasAICore(): Boolean {
        val info = try {
            packages.getPackageInfo(AICORE_PACKAGE, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            return false
        }
        return info.versionName?.contains("stub", ignoreCase = true) != true
    }

    private companion object {
        const val AICORE_PACKAGE = "com.google.android.aicore"

        /**
         * One of the three tokens the facade parses — `ready`,
         * `unavailable`, `unsupported`. Not a sentence: what a reader is told
         * about a phone that cannot run its own model is the kit's line,
         * shared with the Apple app.
         */
        const val UNSUPPORTED = "unsupported"
    }
}
