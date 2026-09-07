package com.readrai.readr

import com.readrai.readr.kit.AskSink
import java.util.concurrent.CopyOnWriteArrayList

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

    override fun contextAssembled(tier: String) { calls += Call(TIER, tier) }
    override fun citations(json: String) { calls += Call(CITATIONS, json) }
    override fun token(text: String) { calls += Call(TOKEN, text) }
    override fun completed(text: String) { calls += Call(COMPLETED, text) }
    override fun failed(message: String, recovery: String) { calls += Call(FAILED, message, recovery) }

    fun of(kind: String): List<Call> = calls.filter { it.kind == kind }

    /** Waits for at least `count` calls of `kind`; false if they never come. */
    fun await(kind: String, count: Int = 1, timeoutMillis: Long = 60_000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (of(kind).size >= count) return true
            Thread.sleep(25)
        }
        return false
    }

    /** Everything recorded, for an assertion message worth reading. */
    override fun toString(): String = calls.joinToString("; ") { "${it.kind}=${it.text.take(60)}" }

    companion object {
        const val TIER = "tier"
        const val CITATIONS = "citations"
        const val TOKEN = "token"
        const val COMPLETED = "completed"
        const val FAILED = "failed"
    }
}
