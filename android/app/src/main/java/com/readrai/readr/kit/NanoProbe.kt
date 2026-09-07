package com.readrai.readr.kit

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * What this phone can say about Gemini Nano — the kit's `OnDeviceProbe`, and
 * the only thing that decides whether the "On this phone" card offers a model
 * or explains why it cannot.
 *
 * This slice answers from what the *system* has, not from the model itself:
 * Android 14 or newer, and AICore actually installed. That is enough to rule
 * the card out honestly on every phone that could never run it. A phone that
 * passes both tests says `unavailable` — "checking" — rather than `ready`,
 * because whether the model is downloaded and this app is allowed to use it
 * is an ML Kit question, and A3c is where it gets asked.
 *
 * The stub matters: Firebase Test Lab devices (and some emulator images) ship
 * an `com.google.android.aicore` package that exists and does nothing, with
 * "stub" in its version name. Treating it as present would put a card on the
 * screen promising a model that is not there.
 */
class NanoProbe(context: Context) : OnDeviceProbe {
    private val packages = context.applicationContext.packageManager

    override fun readiness(): String = when {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> UNSUPPORTED
        !hasAICore() -> UNSUPPORTED
        else -> CHECKING
    }

    /** AICore installed, and not the do-nothing stub some images carry. */
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
         * Both sentences are reader-facing: the kit hands them straight to
         * the card as the status line, so they say what is true of the phone
         * rather than naming an API.
         */
        const val UNSUPPORTED = "unsupported:Gemini Nano isn't available on this phone."
        const val CHECKING = "unavailable:Checking Gemini Nano…"
    }
}
