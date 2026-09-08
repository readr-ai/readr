package com.readrai.readr

import com.readrai.readr.kit.OnDeviceModel
import com.readrai.readr.kit.OnDeviceSink
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * The phone's own model, standing in for Gemini Nano.
 *
 * No device CI runs on can generate: an emulator's AICore is a stub, and
 * [com.readrai.readr.kit.NanoModel] rightly answers `unsupported` there. So a
 * phone that CAN run the model has to be stated rather than found — and with
 * it the whole on-device path: the kit's prompt plan, its classifier hop, the
 * deltas the facade adds up, the repetition guard, and the cancellation that
 * has to reach a running generation.
 *
 * The answer is delivered the way a real runtime delivers one: the new words
 * only, on a thread of its own, one at a time.
 */
class FakeOnDeviceModel(
    private val answer: String = DEFAULT_ANSWER,
    /**
     * What this "phone" says about itself — a `var`, because a phone changes
     * its mind: a model finishes downloading, AICore is updated out from
     * under the app. Writing it is how a test moves the answer the facade's
     * cache is standing in front of.
     */
    @Volatile var state: String = READY,
    /** Milliseconds between words; large enough to cancel in the middle of. */
    private val gapMillis: Long = 40,
    /** What the kit's one-word classifier call comes back with. */
    private val classification: String = "BOOK",
    /** The window this "phone" reports, in tokens. `0` is "cannot say". */
    private val window: Long = DEFAULT_WINDOW,
    /**
     * How long a readiness check takes. Zero on a healthy phone; on a real
     * one it is a bind to AICore, which a broken or half-installed AICore can
     * sit inside for the whole five seconds of `NanoModel`'s leash. What that
     * models here is where the facade may make the call from.
     */
    private val readinessDelayMillis: Long = 0,
) : OnDeviceModel {

    /** Every instruction string the kit sent, in order. */
    val instructions = CopyOnWriteArrayList<String>()
    /** Every prompt the kit sent, in order — the classifier's included. */
    val prompts = CopyOnWriteArrayList<String>()
    /** The prompts for the ANSWER, without the classifier's short hop. */
    val answerPrompts = CopyOnWriteArrayList<String>()
    /** The answer-generation token caps the kit asked for. */
    val caps = CopyOnWriteArrayList<Long>()
    /** The decoding warmth asked for, per call, in order. */
    val temperatures = CopyOnWriteArrayList<Double>()

    /**
     * True once `cancel` arrived for a generation that was STILL RUNNING.
     * Deliberately not "cancel was called": the facade also tears a stream
     * down after it ended, and that is not the reader stopping an answer.
     */
    val cancelledWhileGenerating = AtomicBoolean(false)

    /** How many generations ran to their own end — a separate fact entirely. */
    val generationsEnded = AtomicInteger(0)

    /**
     * How many times the phone has actually been asked about its own model.
     *
     * On a real phone every one of these is a JNI upcall into ML Kit's
     * `checkStatus`, which binds to AICore and may sit there for five
     * seconds — so where the facade asks, and where it merely reads what it
     * was last told, is a fact worth counting rather than assuming.
     */
    val readinessCalls = AtomicInteger(0)

    private val handles = AtomicLong(1)
    private val threads = ConcurrentHashMap<Long, Thread>()
    private val generating = ConcurrentHashMap.newKeySet<Long>()
    private val stopped = ConcurrentHashMap.newKeySet<Long>()

    override fun readiness(): String {
        readinessCalls.incrementAndGet()
        if (readinessDelayMillis > 0) {
            try {
                Thread.sleep(readinessDelayMillis)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        return state
    }

    override fun windowTokens(): Long = window

    override fun generate(
        instructions: String,
        prompt: String,
        maxOutputTokens: Long,
        temperature: Double,
        sink: OnDeviceSink,
    ): Long {
        val handle = handles.getAndIncrement()
        this.instructions += instructions
        prompts += prompt
        temperatures += temperature
        // The kit's classifier: one short, passage-free call answered in one
        // word. It never streams, and it is not the answer under test.
        if (instructions.startsWith(CLASSIFIER_MARKER)) {
            sink.completed(classification)
            return handle
        }
        answerPrompts += prompt
        caps += maxOutputTokens
        generating += handle
        val thread = Thread {
            try {
                val words = answer.split(" ")
                for ((index, word) in words.withIndex()) {
                    if (handle in stopped) return@Thread
                    try {
                        Thread.sleep(gapMillis)
                    } catch (e: InterruptedException) {
                        return@Thread
                    }
                    if (handle in stopped) return@Thread
                    // Deltas, as the protocol says: the new text and no more.
                    sink.delta(if (index == 0) word else " $word")
                }
                if (handle in stopped) return@Thread
                sink.completed(answer)
                generationsEnded.incrementAndGet()
            } finally {
                generating -= handle
            }
        }
        thread.isDaemon = true
        threads[handle] = thread
        thread.start()
        return handle
    }

    /**
     * Stops, and — as the protocol requires — comes back only once the
     * generation's thread is done and the sink can no longer be called.
     */
    override fun cancel(handle: Long) {
        stopped += handle
        if (handle in generating) cancelledWhileGenerating.set(true)
        val thread = threads.remove(handle) ?: return
        thread.interrupt()
        thread.join(CANCEL_JOIN_MS)
    }

    companion object {
        /** The bare tokens the facade parses; the sentence is the kit's. */
        const val READY = "ready"
        const val UNSUPPORTED = "unsupported"

        /**
         * What a phone that can run the model reports. The same figure Apple's
         * FoundationModels answers with, and the facade's own fallback.
         */
        const val DEFAULT_WINDOW = 4_096L

        /** Bounded, so a wedged fake fails a test rather than hanging it. */
        const val CANCEL_JOIN_MS = 2_000L

        /** Two settled sentences, so the stream has an order to keep. */
        const val FIRST_SENTENCE = "Alice follows the White Rabbit down a hole."
        const val SECOND_SENTENCE = "She lands in a long hall lined with locked doors."
        const val DEFAULT_ANSWER = "$FIRST_SENTENCE $SECOND_SENTENCE"

        /** One sentence, over and over — what the repetition guard is for. */
        const val LOOPING_ANSWER =
            "$FIRST_SENTENCE $FIRST_SENTENCE $FIRST_SENTENCE $FIRST_SENTENCE"

        /** Long enough that a cancellation lands well before the end. */
        const val LONG_ANSWER =
            "$FIRST_SENTENCE $SECOND_SENTENCE " +
                "A caterpillar on a mushroom asks her who she is. " +
                "The Cheshire Cat grins at her from the branch of a tree. " +
                "A mad tea party goes round and round without ever ending. " +
                "The Queen of Hearts calls for somebody's head to come off."

        /**
         * The opening of `SmallModelPrompt.classifierInstructions`. Matching on
         * it is how the fake tells the kit's routing question from the reader's.
         */
        const val CLASSIFIER_MARKER = "You sort a reader's questions."
    }
}
