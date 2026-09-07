package com.readrai.readr

import com.readrai.readr.kit.OnDeviceProbe

/**
 * An on-device probe that answers whatever a test needs it to. The real
 * [com.readrai.readr.kit.NanoProbe] answers from the phone, and every phone
 * CI runs on says the same thing — so a "this one can run Nano" case has to
 * be stated rather than found.
 */
class FixedProbe(private val answer: String) : OnDeviceProbe {
    override fun readiness(): String = answer

    companion object {
        /** The bare tokens the facade parses; the sentence is the kit's. */
        val READY = FixedProbe("ready")
        val UNSUPPORTED = FixedProbe("unsupported")
    }
}
