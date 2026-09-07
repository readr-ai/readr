package com.readrai.readr

import com.readrai.readr.kit.OnDeviceModel
import com.readrai.readr.kit.OnDeviceSink
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * The phone's own model, standing in for Gemini Nano.
 *
 * No device CI runs on can generate: an emulator's AICore is a stub, and
 * [com.readrai.readr.kit.NanoModel] rightly answers `unsupported` there. So a
 * phone that CAN run the model has to be stated rather than found — and with
 * it the whole on-device path: the kit's prompt plan, its classifier hop, the
 * cumulative snapshots `SnapshotAnswerStream` reads, the repetition guard, and
 * the cancellation that has to reach a running generation.
 *
 * The answer is delivered the way a real runtime delivers one: growing
 * snapshots, on a thread of its own, a word at a time.
 */
class FakeOnDeviceModel(
    private val answer: String = DEFAULT_ANSWER,
    private val state: String = READY,
    /** Milliseconds between words; large enough to cancel in the middle of. */
    private val gapMillis: Long = 40,
    /** What the kit's one-word classifier call comes back with. */
    private val classification: String = "BOOK",
) : OnDeviceModel {

    /** Every instruction string the kit sent, in order. */
    val instructions = CopyOnWriteArrayList<String>()
    /** Every prompt the kit sent, in order. */
    val prompts = CopyOnWriteArrayList<String>()
    /** The answer-generation token caps the kit asked for. */
    val caps = CopyOnWriteArrayList<Long>()

    /**
     * True once a generation that was still running was cancelled. Not merely
     * "cancel was called": the facade also tears down a stream that has
     * already ended, and that is not the reader stopping an answer.
     */
    val stoppedMidAnswer = AtomicBoolean(false)

    private val handles = AtomicLong(1)
    private val threads = ConcurrentHashMap<Long, Thread>()
    private val stopped = ConcurrentHashMap.newKeySet<Long>()

    override fun readiness(): String = state

    override fun generate(
        instructions: String,
        prompt: String,
        maxOutputTokens: Long,
        sink: OnDeviceSink,
    ): Long {
        val handle = handles.getAndIncrement()
        this.instructions += instructions
        prompts += prompt
        // The kit's classifier: one short, passage-free call answered in one
        // word. It never streams, and it is not the answer under test.
        if (instructions.startsWith(CLASSIFIER_MARKER)) {
            sink.completed(classification)
            return handle
        }
        caps += maxOutputTokens
        val thread = Thread {
            val soFar = StringBuilder()
            for (word in answer.split(" ")) {
                if (handle in stopped) return@Thread
                try {
                    Thread.sleep(gapMillis)
                } catch (e: InterruptedException) {
                    return@Thread
                }
                if (handle in stopped) return@Thread
                if (soFar.isNotEmpty()) soFar.append(' ')
                soFar.append(word)
                // Cumulative, as the protocol says: the whole answer so far.
                sink.snapshot(soFar.toString())
            }
            if (handle in stopped) return@Thread
            sink.completed(soFar.toString())
        }
        thread.isDaemon = true
        threads[handle] = thread
        thread.start()
        return handle
    }

    override fun cancel(handle: Long) {
        stopped += handle
        val thread = threads.remove(handle) ?: return
        if (thread.isAlive) stoppedMidAnswer.set(true)
        thread.interrupt()
    }

    companion object {
        /** The bare tokens the facade parses; the sentence is the kit's. */
        const val READY = "ready"
        const val UNSUPPORTED = "unsupported"

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
