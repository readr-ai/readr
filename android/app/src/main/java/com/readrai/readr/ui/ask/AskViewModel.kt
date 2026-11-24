package com.readrai.readr.ui.ask

import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.readrai.readr.ReadrApplication
import com.readrai.readr.data.AskCitation
import com.readrai.readr.data.AskEvent
import com.readrai.readr.data.AskFrontier
import com.readrai.readr.data.AskPosition
import com.readrai.readr.data.AskRepository
import com.readrai.readr.data.AskSelection
import com.readrai.readr.data.AskTier
import com.readrai.readr.data.AskTurn
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The book's Ask conversation, as a view model bound to this composition —
 * keyed by book, so two books never share a transcript, and scoped to the
 * reader's back-stack entry, so a trip to the provider settings and back
 * finds the same one.
 */
@Composable
fun rememberAskViewModel(bookId: String): AskViewModel {
    val app = LocalContext.current.applicationContext as ReadrApplication
    return viewModel(key = "ask/$bookId") {
        AskViewModel({ app.asks() }, app.askConversations.forBook(bookId))
    }
}

/**
 * The passages one answer leaned on, wrapped so the exchange around them can
 * be `@Immutable`: a bare `List` is not a stable type to Compose, and an
 * exchange holding one is re-composed on every state write in the sheet
 * whether or not anything about it changed.
 */
@Immutable
data class AskCitations(val items: List<AskCitation> = emptyList()) {
    val isEmpty: Boolean get() = items.isEmpty()
}

/**
 * One answer's structure, as the kit's Markdown parser cut it — wrapped for
 * the same reason [AskCitations] is: a bare `List` is not a stable type to
 * Compose, and an exchange holding one is re-composed on every state write in
 * the sheet.
 *
 * Empty while the answer is still streaming. The parse is a bridge call, so
 * it happens ONCE, off the main thread, when the answer is finished — until
 * then the sheet draws the text as paragraphs, which is all a half-written
 * answer has to show anyway.
 */
@Immutable
data class AnswerBlocks(val items: List<AnswerBlock> = emptyList()) {
    val isEmpty: Boolean get() = items.isEmpty()
}

/** One question and the answer streaming into it. */
@Immutable
data class AskExchange(
    val id: Long,
    /** Shown as sent the moment it is sent, not when the answer starts. */
    val question: String,
    /**
     * Whether this answer was held to what the reader had read. Kept per
     * exchange because the sheet's scope control can flip between questions,
     * and the note under an answer must describe that answer.
     */
    val scoped: Boolean,
    val answerText: String = "",
    val tier: String? = null,
    /** What the routed tier promises, in the kit's own words. */
    val providesCitations: Boolean? = null,
    val citations: AskCitations = AskCitations(),
    /**
     * The finished answer's blocks. Empty while it streams — the sheet draws
     * paragraphs then — and filled once, off the main thread, when it lands.
     */
    val blocks: AnswerBlocks = AnswerBlocks(),
    /**
     * Why this turn has no answer — the kit's sentence, kept ON the exchange
     * so it stays under the question it belongs to. The composer's error card
     * can be cleared by the next question; the transcript must still say what
     * happened to this one.
     */
    val failure: String? = null,
    val failureRecovery: String? = null,
    val isStreaming: Boolean = true,
) {
    val failed: Boolean get() = failure != null

    /** Nothing to show and nothing coming. */
    val isEmpty: Boolean get() = answerText.isBlank() && !isStreaming && !failed
}

/**
 * A book's Ask conversation, for the life of the process — the Apple app
 * keeps one per session the same way. It outlives the sheet and the reader's
 * view model, so closing Ask and opening it again on the next chapter
 * continues the conversation rather than starting a new one.
 */
class AskConversation(val bookId: String) {
    var exchanges by mutableStateOf<List<AskExchange>>(emptyList())
    /**
     * The reader's scope choice, kept with the transcript it describes: a
     * choice made for one question holds for the next opening rather than
     * snapping back while whole-book answers sit in the history the model
     * reads.
     */
    var wholeBook by mutableStateOf(false)

    private var nextId = 1L

    fun nextExchangeId(): Long = nextId++

    /** Start over, keeping the same object so open sheets stay bound to it. */
    fun clear() {
        exchanges = emptyList()
    }
}

/** The process's conversations, one per book. */
class AskConversations {
    private val byBook = HashMap<String, AskConversation>()

    @Synchronized
    fun forBook(bookId: String): AskConversation = byBook.getOrPut(bookId) { AskConversation(bookId) }

    /**
     * Drop a book's transcript. A removed book takes its conversation with
     * it: the answers quote a book nobody can open any more, and a re-import
     * is a new book with a new id in any case.
     */
    @Synchronized
    fun forget(bookId: String) {
        byBook.remove(bookId)
    }
}

/**
 * Everything one opening of the sheet needs, decided by whoever opens it: the
 * ✦ in the reader bar opens on the book at the reader's place, the capsule's
 * ✦ Ask opens on the passage.
 */
data class AskRequest(
    /** The passage the question is about, or null for a book-wide question. */
    val selection: AskSelection? = null,
    /**
     * How far the reader has read. Null means there is no reading position to
     * scope to, so every question is about the whole book and the scope
     * control is not offered.
     */
    val frontier: AskFrontier? = null,
)

/**
 * Drives one book's Ask conversation: streams each answer, keeps the
 * transcript so a follow-up can build on what came before, and remembers the
 * last request so a failure can be retried without retyping.
 *
 * Nothing here writes a reader-facing failure sentence: the facade hands over
 * ReadrKit's own message and recovery line, which is what the error card
 * shows.
 */
class AskViewModel(
    private val openRepository: suspend () -> AskRepository,
    private val conversation: AskConversation,
) : ViewModel() {

    val bookId: String get() = conversation.bookId
    val exchanges: List<AskExchange> get() = conversation.exchanges

    /** "Whole book" chosen over "Up to where I am". */
    var wholeBook: Boolean
        get() = conversation.wholeBook
        set(value) { conversation.wholeBook = value }

    var isStreaming by mutableStateOf(false)
        private set
    /** The book's retrieval index is being built; the answer waits on it. */
    var indexing by mutableStateOf(false)
        private set

    /** The kit's sentence for the failure, and the step it suggests. */
    var errorMessage by mutableStateOf<String?>(null)
        private set
    var errorRecovery by mutableStateOf<String?>(null)
        private set

    /** Null while the answer is still being fetched from the kit. */
    var hasProvider by mutableStateOf<Boolean?>(null)
        private set

    /**
     * True when the active model runs on the phone: it answers from the
     * passages and nothing else, and the grounding caption says exactly that
     * rather than promising a wider knowledge it does not have.
     */
    var answersFromBookOnly by mutableStateOf(false)
        private set

    /**
     * What to do about having nothing connected. The facade's sentence names
     * only the doors THIS phone has — a key, and the phone's own model where
     * it can run one — but the empty state must never be a heading over a
     * blank line, so it starts on the one door every build has and is
     * replaced only by a sentence that actually says something.
     */
    var setupGuidance by mutableStateOf(DEFAULT_SETUP_GUIDANCE)
        private set

    /** The passage this opening pointed the conversation at, or null. */
    var selection by mutableStateOf<AskSelection?>(null)
        private set
    var frontier by mutableStateOf<AskFrontier?>(null)
        private set
    /** "Chapter 7 of 24 · 31% · The Whale" — the kit's own line. */
    var position by mutableStateOf<AskPosition?>(null)
        private set

    /**
     * Whether the sheet should be showing. Kept here rather than in the
     * reader's composition so a trip to the provider settings and back comes
     * home to the sheet the reader left open.
     */
    var isOpen by mutableStateOf(false)
        private set

    /** The question, scope and passage to re-run after a failure. */
    var lastRequest: AskRequest? = null
        private set
    private var lastQuestion: String? = null

    private var repository: AskRepository? = null
    private var streamJob: Job? = null

    /** What the next question is allowed to see. */
    val scopedFrontier: AskFrontier? get() = frontier?.takeIf { !wholeBook }
    val isScoped: Boolean get() = scopedFrontier != null

    /** The most recently routed tier — what the tier label describes. */
    val tier: String? get() = exchanges.lastOrNull { it.tier != null }?.tier

    /**
     * What the last routed tier promises about citations, in the kit's own
     * answer — null until something has actually been routed, which is what
     * keeps the caption from promising anything before then.
     */
    val providesCitations: Boolean?
        get() = exchanges.lastOrNull { it.providesCitations != null }?.providesCitations

    /**
     * Point the conversation at a new opening. The transcript stays; a stale
     * error does not — it was about the last question, not this opening.
     */
    fun open(request: AskRequest) {
        selection = request.selection
        frontier = request.frontier
        errorMessage = null
        errorRecovery = null
        position = null
        isOpen = true
        refresh()
        loadPosition()
        parseMissingBlocks()
    }

    /**
     * The sheet went away. A stream in flight is left running — the answer
     * belongs to the conversation, not to the sheet, and it will be there
     * when the reader comes back.
     */
    fun close() {
        isOpen = false
    }

    /** Re-resolve the provider, and the sentence the empty state shows. */
    fun refresh() {
        viewModelScope.launch {
            val repo = repository() ?: return@launch
            hasProvider = runCatching { repo.hasProvider() }.getOrDefault(false)
            answersFromBookOnly = runCatching { repo.answersFromBookOnly() }.getOrDefault(false)
            runCatching { repo.setupGuidance("ask questions") }
                .getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let { setupGuidance = it }
        }
    }

    /** Start over: cancel anything in flight and empty the transcript. */
    fun startOver() {
        cancel()
        conversation.clear()
        errorMessage = null
        errorRecovery = null
        lastRequest = null
        lastQuestion = null
    }

    /** Stop the stream in flight. The answer keeps whatever arrived. */
    fun cancel() {
        streamJob?.cancel()
        streamJob = null
        isStreaming = false
        indexing = false
        // What arrived before the stop is the answer now; the stream's own
        // `finally` gets the last word on it, including its blocks.
        update(exchanges.lastOrNull()?.id) { it.copy(isStreaming = false) }
    }

    /** Ask, under the current scope and about the current passage. */
    fun submit(question: String) {
        val request = AskRequest(selection = selection, frontier = scopedFrontier)
        streamJob = viewModelScope.launch { run(question, request, replacingLast = false) }
    }

    /** Re-run the last question exactly as it was asked. */
    fun retry() {
        val request = lastRequest ?: return
        val question = lastQuestion ?: return
        streamJob = viewModelScope.launch { run(question, request, replacingLast = true) }
    }

    /** Static starters, worded for the scope and the passage. */
    val suggestions: List<String>
        get() = when {
            selection != null -> listOf(
                "What does this passage mean?",
                if (isScoped) "How does this connect to what I've read so far?"
                else "How does this connect to the rest of the book?",
            )
            isScoped -> listOf(
                RECAP_QUESTION,
                "Summarize what I've read so far",
                "What are the key themes so far?",
                "Who are the main characters so far?",
            )
            else -> listOf(
                "Summarize this book",
                "What are the key themes?",
                "Who are the main characters?",
            )
        }

    // MARK: - Streaming

    private suspend fun run(question: String, request: AskRequest, replacingLast: Boolean) {
        val trimmed = question.trim()
        if (trimmed.isEmpty() || isStreaming) return
        lastRequest = request
        lastQuestion = trimmed
        errorMessage = null
        errorRecovery = null

        // A retry re-runs the SAME turn: drop the failed one rather than
        // stacking a second copy of the question in the transcript.
        if (replacingLast && conversation.exchanges.lastOrNull()?.answerText.isNullOrBlank()) {
            conversation.exchanges = conversation.exchanges.dropLast(1)
        }
        val id = conversation.nextExchangeId()
        val scoped = request.frontier != null
        conversation.exchanges = conversation.exchanges + AskExchange(id = id, question = trimmed, scoped = scoped)

        val repo = repository()
        if (repo == null) {
            fail(id, COULD_NOT_OPEN, null)
            return
        }
        isStreaming = true
        val history = historyBefore(id)
        // Deltas arrive a few characters at a time and each one would
        // otherwise be a state write, a re-parse of the answer and a re-layout
        // of the sheet. They are joined here and written at most this often,
        // which is still faster than anyone reads.
        val pending = StringBuilder()
        var lastWrite = 0L
        fun flush() {
            if (pending.isEmpty()) return
            val delta = pending.toString()
            pending.setLength(0)
            update(id) { it.copy(answerText = it.answerText + delta) }
        }
        try {
            repo.ask(bookId, trimmed, request.frontier, request.selection, history).collect { event ->
                when (event) {
                    AskEvent.Indexing -> indexing = true
                    is AskEvent.Routed -> {
                        indexing = false
                        update(id) { it.copy(tier = event.tier, providesCitations = event.providesCitations) }
                    }
                    is AskEvent.Citations -> update(id) { it.copy(citations = AskCitations(event.citations)) }
                    is AskEvent.Token -> {
                        pending.append(event.text)
                        val now = System.currentTimeMillis()
                        if (now - lastWrite >= COALESCE_MILLIS) {
                            lastWrite = now
                            flush()
                        }
                    }
                    // Authoritative final text — it covers providers that do
                    // not stream incremental deltas.
                    is AskEvent.Completed -> {
                        pending.setLength(0)
                        update(id) { it.copy(answerText = event.text) }
                    }
                    is AskEvent.Failed -> {
                        flush()
                        fail(id, event.message, event.recovery)
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // The class, never the message: an exception on this path can
            // carry a URL or a payload, and a log is not a place for either.
            Log.w(TAG, "ask failed: ${e.javaClass.simpleName}")
            fail(id, COULD_NOT_OPEN, null)
        } finally {
            flush()
            isStreaming = false
            indexing = false
            update(id) { it.copy(isStreaming = false) }
            // The answer is whatever arrived — completed, failed part-way, or
            // stopped by the reader. Whatever it is, it is finished, so it is
            // parsed now rather than by the composition drawing it.
            parseBlocks(id)
        }
    }

    /**
     * The answered turns before `id`, oldest first. A failed or empty turn
     * carries no answer and is left out; each surviving turn says whether it
     * was answered under a scope, and the facade drops the unscoped ones from
     * a scoped question's history.
     */
    private fun historyBefore(id: Long): List<AskTurn> =
        conversation.exchanges
            .takeWhile { it.id != id }
            .filter { !it.failed && it.answerText.isNotBlank() }
            .map {
                AskTurn(
                    question = it.question,
                    answerText = it.answerText,
                    tier = it.tier ?: AskTier.RETRIEVAL,
                    citations = it.citations.items,
                    scoped = it.scoped,
                )
            }

    private suspend fun repository(): AskRepository? {
        repository?.let { return it }
        return try {
            openRepository().also { repository = it }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "ask repository failed: ${e.javaClass.simpleName}")
            hasProvider = false
            null
        }
    }

    private fun loadPosition() {
        val place = frontier ?: return
        viewModelScope.launch {
            val repo = repository() ?: return@launch
            position = runCatching { repo.positionSummary(bookId, place.chapterIndex, place.utf16Offset) }.getOrNull()
        }
    }

    /**
     * Cut a finished answer into the kit's blocks and hang them on the
     * exchange it belongs to.
     *
     * Once, and off the main thread: the parse is a JNI call and a JSON
     * decode, and the sheet used to make it from composition — on every
     * delta, on the thread that then had to lay the result out. Composition
     * now reads what is already on the exchange and never crosses the bridge
     * at all. The text is checked again on the way back, so an answer that
     * moved on meanwhile keeps its own blocks.
     */
    private fun parseBlocks(id: Long) {
        val text = conversation.exchanges.firstOrNull { it.id == id }?.answerText ?: return
        if (text.isBlank()) return
        viewModelScope.launch {
            val repo = repository() ?: return@launch
            // `Default`, not `IO`: the bridge call is a parse — CPU, no disk
            // and no socket — and it must not sit behind a provider request.
            val parsed = runCatching {
                withContext(Dispatchers.Default) {
                    AnswerMarkdown.blocks(repo.answerBlocksJSON(text), fallback = text)
                }
            }.getOrElse { listOf(AnswerBlock.Paragraph(text)) }
            update(id) { if (it.answerText == text) it.copy(blocks = AnswerBlocks(parsed)) else it }
        }
    }

    /**
     * Blocks for answers that are already in the transcript without them — a
     * conversation restored on a later opening of the sheet, and an answer
     * whose stream was cancelled rather than completed.
     */
    private fun parseMissingBlocks() {
        for (exchange in conversation.exchanges) {
            if (exchange.blocks.isEmpty && !exchange.isStreaming && exchange.answerText.isNotBlank()) {
                parseBlocks(exchange.id)
            }
        }
    }

    private fun update(id: Long?, change: (AskExchange) -> AskExchange) {
        if (id == null) return
        conversation.exchanges = conversation.exchanges.map { if (it.id == id) change(it) else it }
    }

    private fun fail(id: Long, message: String, recovery: String?) {
        errorMessage = message
        errorRecovery = recovery
        update(id) { it.copy(failure = message, failureRecovery = recovery, isStreaming = false) }
    }

    companion object {
        /**
         * The recap, word for word — the first suggestion chip when answers
         * are scoped, and the same sentence the Apple reader sends.
         */
        const val RECAP_QUESTION = "Recap what I've read so far — no spoilers"

        /** The only sentence this class writes, and only when the kit is unreachable. */
        private const val COULD_NOT_OPEN = "Readr couldn't reach the model. Try asking again."
        private const val TAG = "Readr.Ask"

        /** One state write per frame or two, however fast the tokens come. */
        private const val COALESCE_MILLIS = 50L

        /**
         * The empty state's opening sentence, before the facade has said what
         * this phone offers. Every build of this app has the key path, so it
         * is true of all of them; the facade's own sentence replaces it as
         * soon as it arrives.
         */
        const val DEFAULT_SETUP_GUIDANCE = "Add an API key to ask questions."
    }
}
