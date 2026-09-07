package com.readrai.readr.data

import com.readrai.readr.kit.AskSink
import com.readrai.readr.kit.Kit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

/**
 * One passage of the book an answer leaned on. `chapterIndex`/`utf16Offset`
 * are the place to open — absent for a citation the tier assembled without a
 * passage behind it, in which case the pill quotes but does not travel.
 */
@Serializable
data class AskCitation(
    val locator: String,
    val quotedText: String,
    val chapterIndex: Int? = null,
    val utf16Offset: Int? = null,
) {
    /** Whether "Show in book" has somewhere to go. */
    val isLocated: Boolean get() = chapterIndex != null && utf16Offset != null
}

/** How far the reader has read: the spoiler boundary, in Compose's offsets. */
@Serializable
data class AskFrontier(val chapterIndex: Int, val utf16Offset: Int)

/**
 * The passage the question is about. `quotedText` is for the sheet's context
 * header; the facade reads the words out of the book itself, so what is sent
 * here is never what the model is shown.
 */
@Serializable
data class AskSelection(
    val chapterIndex: Int,
    val utf16Start: Int,
    val utf16End: Int,
    val quotedText: String = "",
)

/** Mirrors ReadrAndroid's `AskScopeWire`: whole book, or up to the frontier. */
@Serializable
private data class ScopeWire(val wholeBook: Boolean? = null, val frontier: AskFrontier? = null)

/** One answered turn, as the facade wants the conversation so far. */
@Serializable
data class AskTurn(
    val question: String,
    val answerText: String,
    val tier: String? = null,
    val citations: List<AskCitation> = emptyList(),
    /**
     * Whether this turn was answered under a frontier. The facade drops
     * unscoped turns from the history of a scoped question — the no-spoilers
     * promise covers what the model reads, not only the passages it is
     * handed — so the scope has to travel with the turn.
     */
    val scoped: Boolean = false,
)

/**
 * Mirrors ReadrAndroid's `AskPositionWire` — the kit's `ReadingPositionSummary`.
 * `caption` is "Chapter 7 of 24 · 31% · The Whale", the same line the Apple
 * panel shows and the same one the model is told.
 */
@Serializable
data class AskPosition(
    val caption: String,
    val chapterLine: String,
    val chapterTitle: String,
    val chapterNumber: Int,
    val chapterCount: Int,
    val percent: Int,
    val titleIsFallback: Boolean = false,
)

/**
 * What the facade says while an answer is being put together. `Completed` and
 * `Failed` are the two ways a stream ends, and exactly one of them arrives —
 * unless the ask is cancelled, which ends the flow without either.
 */
sealed interface AskEvent {
    /** The book's retrieval index is being built; the answer waits on it. */
    data object Indexing : AskEvent
    /**
     * The router settled. [tier] is `retrieval` or `wholeBook`, and
     * [providesCitations] is the kit's own answer about that tier — the
     * caption follows it rather than re-deriving the rule here.
     */
    data class Routed(val tier: String, val providesCitations: Boolean) : AskEvent
    data class Citations(val citations: List<AskCitation>) : AskEvent
    data class Token(val text: String) : AskEvent
    data class Completed(val text: String) : AskEvent
    data class Failed(val message: String, val recovery: String?) : AskEvent
}

/** Mirrors ReadrAndroid's `AskTierWire`: the tier, and what it promises. */
@Serializable
private data class TierWire(val tier: String, val providesCitations: Boolean = false)

/** The routing tiers the facade reports, by their kit raw values. */
object AskTier {
    const val RETRIEVAL = "retrieval"
    const val WHOLE_BOOK = "wholeBook"
}

/**
 * Asking the book, over the kit's `AskService`.
 *
 * The answer arrives as a [Flow] of [AskEvent]: the facade streams into a
 * Swift-side sink this class implements, and each call is forwarded onto the
 * channel — so the sheet collects on the main thread while the model streams
 * on Swift's executor. Cancelling the collection cancels the ask itself
 * (`awaitClose`), which is what closing the sheet or starting a new
 * conversation does.
 */
class AskRepository(private val kit: Kit) {

    /**
     * Ask `question` about the book. `frontier` null means the whole book —
     * the scope is named on every call, as the kit requires, and there is no
     * default that could quietly send what the reader has not read past.
     */
    fun ask(
        bookId: String,
        question: String,
        frontier: AskFrontier?,
        selection: AskSelection?,
        history: List<AskTurn>,
    ): Flow<AskEvent> = callbackFlow {
        val sink = object : AskSink {
            override fun indexing() {
                trySend(AskEvent.Indexing)
            }

            override fun contextAssembled(json: String) {
                val wire = runCatching { kitJson.decodeFromString<TierWire>(json) }.getOrNull() ?: return
                trySend(AskEvent.Routed(wire.tier, wire.providesCitations))
            }

            override fun citations(json: String) {
                val decoded = runCatching { kitJson.decodeFromString<List<AskCitation>>(json) }.getOrDefault(emptyList())
                trySend(AskEvent.Citations(decoded))
            }

            override fun token(text: String) {
                trySend(AskEvent.Token(text))
            }

            override fun completed(text: String) {
                trySend(AskEvent.Completed(text))
                close()
            }

            override fun failed(message: String, recovery: String) {
                trySend(AskEvent.Failed(message, recovery.ifBlank { null }))
                close()
            }
        }
        val scopeJson = kitJson.encodeToString(
            if (frontier == null) ScopeWire(wholeBook = true) else ScopeWire(frontier = frontier)
        )
        val selectionJson = selection?.let { kitJson.encodeToString(it) }.orEmpty()
        val historyJson = if (history.isEmpty()) "" else kitJson.encodeToString(history)
        // The facade may refuse before it starts anything (no provider): it
        // says so through the sink and hands back 0, and the flow is already
        // closed by the time this returns.
        //
        // `NonCancellable`: this call hands back the handle that owns the
        // Swift task, and a cancellation that landed while it was in flight
        // would drop that handle on the floor — leaving a stream running with
        // nothing able to stop it. It runs to completion, and a collector
        // that went away meanwhile is answered with the stop it missed.
        var handle = 0L
        var refusal: Throwable? = null
        try {
            handle = withContext(Dispatchers.IO + NonCancellable) {
                kit.library.ask(bookId, question, scopeJson, selectionJson, historyJson, kit.providers, sink)
            }
        } catch (e: Throwable) {
            refusal = e
        }
        if (!currentCoroutineContext().isActive && handle != 0L) kit.library.cancelAsk(handle)
        refusal?.let { close(it) }
        // Reached however the start went, so the ask is always stopped when
        // the collection ends.
        awaitClose { if (handle != 0L) kit.library.cancelAsk(handle) }
    }
        // Unlimited, not the default 64: the sink is called from Swift's
        // executor and cannot suspend, so a `trySend` that finds the buffer
        // full DROPS the token — a fast provider streaming a long answer into
        // a main thread busy laying out the sheet would lose the middle of it.
        .buffer(Channel.UNLIMITED)
        .flowOn(Dispatchers.IO)

    /** Whether Ask has a model to put a question to at all. */
    suspend fun hasProvider(): Boolean = withContext(Dispatchers.IO) { kit.providers.hasAnyProvider() }

    /**
     * The answer's Markdown cut into blocks by the kit's own parser, as JSON.
     *
     * Not suspending, because there is nothing to wait for: it touches
     * neither the disk nor the network — it is a parse, and the only cost is
     * CPU. It is still a call across the bridge, so the caller makes it once
     * per finished answer on a worker thread ([AskViewModel] does), never
     * from a composition and never per streamed delta.
     */
    fun answerBlocksJSON(markdown: String): String = kit.library.answerBlocksJSON(markdown)

    /**
     * The kit's empty-state sentence: the ways this build can be connected on
     * THIS phone — an API key, and the phone's own model where it is one this
     * phone can actually run — joined into one line ending in [toDo]. What it
     * names therefore differs from phone to phone, which is the point of
     * asking the facade rather than writing it here.
     */
    suspend fun setupGuidance(toDo: String): String = withContext(Dispatchers.IO) {
        kit.providers.setupGuidance(toDo)
    }

    /**
     * Whether the model Ask would use runs on the phone itself — which is
     * what decides between the two grounding sentences the sheet shows.
     */
    suspend fun answersFromBookOnly(): Boolean = withContext(Dispatchers.IO) { kit.providers.isActiveOnDevice() }

    /** "Chapter 7 of 24 · 31% · The Whale", or null for a book with no linear chapters. */
    suspend fun positionSummary(bookId: String, chapterIndex: Int, utf16Offset: Int): AskPosition? =
        withContext(Dispatchers.IO) {
            kit.library.positionSummaryJSON(bookId, chapterIndex.toLong(), utf16Offset.toLong())
                .takeIf { it.isNotEmpty() }
                ?.let { runCatching { kitJson.decodeFromString<AskPosition>(it) }.getOrNull() }
        }

}
