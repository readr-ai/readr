package com.readrai.readr.data

import com.readrai.readr.kit.AskSink
import com.readrai.readr.kit.Kit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
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
    /** The router settled: `retrieval` or `wholeBook`. */
    data class Routed(val tier: String) : AskEvent
    data class Citations(val citations: List<AskCitation>) : AskEvent
    data class Token(val text: String) : AskEvent
    data class Completed(val text: String) : AskEvent
    data class Failed(val message: String, val recovery: String?) : AskEvent
}

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
            override fun contextAssembled(tier: String) {
                trySend(if (tier == INDEXING) AskEvent.Indexing else AskEvent.Routed(tier))
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
        val handle = withContext(Dispatchers.IO) {
            kit.library.ask(bookId, question, scopeJson, selectionJson, historyJson, kit.providers, sink)
        }
        awaitClose { if (handle != 0L) kit.library.cancelAsk(handle) }
    }.flowOn(Dispatchers.IO)

    /** Whether Ask has a model to put a question to at all. */
    suspend fun hasProvider(): Boolean = withContext(Dispatchers.IO) { kit.providers.hasAnyProvider() }

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

    private companion object {
        /** The facade's stand-in tier while a book's index is being built. */
        const val INDEXING = "indexing"
    }
}
