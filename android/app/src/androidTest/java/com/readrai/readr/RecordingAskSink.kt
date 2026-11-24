package com.readrai.readr

import com.readrai.readr.kit.AskSink
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * An [AskSink] that writes down what the facade told it, and when.
 *
 * The "when" is the point: a token that arrived before the server sent the
 * next chunk is proof the answer streamed rather than being handed over in
 * one piece at the end.
 */
class RecordingAskSink : AskSink {

    data class Call(
        val kind: String,
        val text: String,
        val recovery: String = "",
        val at: Long = System.currentTimeMillis(),
    )

    val calls = CopyOnWriteArrayList<Call>()

    override fun indexing() { calls += Call(INDEXING, "") }
    override fun contextAssembled(json: String) { calls += Call(TIER, json) }
    override fun citations(json: String) { calls += Call(CITATIONS, json) }
    override fun token(text: String) { calls += Call(TOKEN, text) }
    override fun completed(text: String) { calls += Call(COMPLETED, text) }
    override fun failed(message: String, recovery: String) { calls += Call(FAILED, message, recovery) }

    fun of(kind: String): List<Call> = calls.filter { it.kind == kind }

    /**
     * Waits for at least `count` calls of `kind`; false if they never come.
     *
     * Suspending, and on `Dispatchers.Default` on purpose: inside `runTest`
     * a bare `delay` runs on the virtual clock and would skip the whole wait
     * without a millisecond passing, while `Thread.sleep` blocks the test's
     * only thread — which is where the collection it is waiting for runs.
     */
    suspend fun await(kind: String, count: Int = 1, timeout: Duration = 3.minutes): Boolean =
        withContext(Dispatchers.Default) {
            withTimeoutOrNull(timeout) {
                while (of(kind).size < count) delay(25)
                true
            } ?: false
        }

    /** The tier JSON of the last routing, decoded by the caller. */
    fun lastTierJSON(): String = of(TIER).lastOrNull()?.text ?: ""

    /** Everything recorded, for an assertion message worth reading. */
    override fun toString(): String = calls.joinToString("; ") { "${it.kind}=${it.text.take(60)}" }

    companion object {
        const val INDEXING = "indexing"
        const val TIER = "tier"
        const val CITATIONS = "citations"
        const val TOKEN = "token"
        const val COMPLETED = "completed"
        const val FAILED = "failed"
    }
}
