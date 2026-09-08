package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.mlkit.genai.common.GenAiException
import com.readrai.readr.kit.NanoModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The real ML Kit path, on the device the suite is running on.
 *
 * Every emulator (and every Firebase Test Lab device) ships a stub AICore: the
 * package is there and does nothing, and ML Kit's own `checkStatus` answers
 * UNAVAILABLE. So nothing here can generate — but the two pieces of the class
 * that decide what the reader is told are pure functions of their input, and
 * those are pinned on the real class rather than on the fake that stands in
 * for a phone CI cannot have.
 */
@RunWith(AndroidJUnit4::class)
class NanoModelTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val model get() = NanoModel(context)

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

    /**
     * A phone with no model to ask cannot report a window, and says so with
     * `0` rather than a guess — the facade then uses its own documented
     * fallback, which is a decision that belongs on the Swift side.
     */
    @Test
    fun aPhoneThatCannotSayReportsNoWindow() {
        assertEquals(0L, model.windowTokens())
    }

    // ---- The reason codes ------------------------------------------------

    /**
     * A cancelled generation is NOT a failure: it is the reader stopping an
     * answer, and the protocol says such a generation reports neither ending.
     * `null` is that "say nothing".
     */
    @Test
    fun aCancelledGenerationIsNotReportedAtAll() {
        assertNull(model.code(genAi(GenAiException.ErrorCode.CANCELLED)))
    }

    @Test
    fun everyFailureCodeTheFacadeHasASentenceFor() {
        val model = model
        assertEquals("background", model.code(genAi(GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED)))
        assertEquals("busy", model.code(genAi(GenAiException.ErrorCode.BUSY)))
        assertEquals(
            "busy",
            model.code(genAi(GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED)),
        )
        assertEquals("tooLong", model.code(genAi(GenAiException.ErrorCode.REQUEST_TOO_LARGE)))
        for (unavailable in listOf(
            GenAiException.ErrorCode.NOT_AVAILABLE,
            GenAiException.ErrorCode.NOT_SUPPORTED,
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE,
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
        )) {
            assertEquals("unavailable", model.code(genAi(unavailable)))
        }
    }

    /** Anything unmapped is the facade's generic sentence, never a stack trace. */
    @Test
    fun anythingElseIsTheGenericFailure() {
        val model = model
        assertEquals("", model.code(genAi(GenAiException.ErrorCode.UNKNOWN)))
        assertEquals("", model.code(genAi(GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR)))
        assertEquals("", model.code(IllegalStateException("no on-device model")))
    }

    // ---- Deltas on the wire ----------------------------------------------

    /**
     * ML Kit's `onNewText` is read as the new text, which is what its name
     * says and all the documentation the AAR carries. The deltas go over the
     * wire untouched and the Swift side adds them up.
     */
    @Test
    fun newTextIsPassedOnAsTheDeltaItIs() {
        val model = model
        assertEquals("Alice", model.delta("", "Alice"))
        assertEquals(" follows", model.delta("Alice", " follows"))
        assertEquals(" the White Rabbit.", model.delta("Alice follows", " the White Rabbit."))
    }

    /**
     * The hedge, for a runtime that streams the whole answer each time:
     * appending it would double every word, so only its tail travels.
     */
    @Test
    fun aCumulativeSnapshotIsReadAsItsTail() {
        val model = model
        assertEquals(" follows", model.delta("Alice", "Alice follows"))
        assertEquals(
            " the White Rabbit.",
            model.delta("Alice follows", "Alice follows the White Rabbit."),
        )
    }

    /** A chunk that is not a continuation of what was sent is its own delta. */
    @Test
    fun aChunkThatIsNoContinuationIsAFreshDelta() {
        val model = model
        assertEquals(" again", model.delta("Alice follows", " again"))
        assertEquals("Alice", model.delta("Alice", "Alice"))
        assertEquals("", model.delta("Alice", ""))
    }

    /** Deltas add up to the answer, whichever shape the runtime streams in. */
    @Test
    fun theDeltasAddUpToTheAnswer() {
        val whole = "Alice follows the White Rabbit down a hole."
        for (cumulative in listOf(false, true)) {
            val model = model
            val sent = StringBuilder()
            var written = 0
            while (written < whole.length) {
                written = minOf(written + 7, whole.length)
                val chunk = if (cumulative) whole.take(written) else whole.substring(sent.length, written)
                sent.append(model.delta(sent.toString(), chunk))
            }
            assertEquals("cumulative=$cumulative", whole, sent.toString())
        }
    }

    private fun genAi(code: Int): GenAiException = GenAiException(RuntimeException("boom"), code)
}
