package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.kit.NanoModel
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The real ML Kit path, on the device the suite is running on.
 *
 * Every emulator (and every Firebase Test Lab device) ships a stub AICore: the
 * package is there and does nothing, and ML Kit's own `checkStatus` answers
 * UNAVAILABLE. What is pinned here is that the check *runs* and comes back
 * `unsupported` rather than throwing — a model this phone cannot drive must
 * never be offered as one Ask could be pointed at, and a crash inside a
 * settings screen is not an answer.
 */
@RunWith(AndroidJUnit4::class)
class NanoModelTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun anEmulatorsStubAICoreReadsAsUnsupported() {
        assertEquals("unsupported", NanoModel(context).readiness())
    }

    /** Asked twice, it answers the same way — no state is left behind. */
    @Test
    fun theCheckCanBeRepeated() {
        val model = NanoModel(context)
        assertEquals("unsupported", model.readiness())
        assertEquals("unsupported", model.readiness())
    }
}
