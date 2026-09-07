package com.readrai.readr.ui.listen

import android.content.Context
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.readrai.readr.ReadrApplication
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.AndroidNarration
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NarrationEvents
import com.readrai.readr.kit.NarrationObserver
import com.readrai.readr.kit.PlatformSpeechBackend
import com.readrai.readr.kit.SpeechBackend
import com.readrai.readr.ui.reader.ReaderSettings
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import org.swift.swiftkit.core.SwiftArena

/** The sleep timer as the facade reports it — the kit's `SleepTimerState`. */
@Serializable
data class NarrationSleep(
    val mode: String = OFF,
    val minutes: Int? = null,
    val remainingSeconds: Int? = null,
) {
    val isOn: Boolean get() = mode != OFF

    /** mm:ss left on a timed sleep; null for Off and End of chapter. */
    val countdown: String?
        get() = remainingSeconds?.takeIf { mode == AFTER }
            ?.let { "%d:%02d".format(it / 60, it % 60) }

    /** "Off", "15 min", "End of chapter" — the kit's own `displayName`. */
    val displayName: String
        get() = when (mode) {
            AFTER -> "${(minutes ?: 1).coerceAtLeast(1)} min"
            END_OF_CHAPTER -> "End of chapter"
            else -> "Off"
        }

    companion object {
        const val OFF = "off"
        const val AFTER = "after"
        const val END_OF_CHAPTER = "endOfChapter"

        /** The durations the sleep control offers — the kit's `minuteOptions`. */
        val minuteOptions = listOf(5, 10, 15, 30, 45, 60)
    }
}

/** What the facade's `setSleepTimer` takes. */
@Serializable
private data class SleepRequest(val mode: String, val minutes: Int? = null)

/** Everything the Listen card draws, as `AndroidNarration.stateJSON` reports it. */
@Serializable
data class NarrationState(
    val status: String = NarrationModel.IDLE,
    val holdReason: String? = null,
    /** Why narration stopped by itself, in the facade's words — never Kotlin's. */
    val holdText: String? = null,
    val chapterIndex: Int = -1,
    val utf16Offset: Int = 0,
    val utf16SentenceStart: Int = 0,
    val sentence: String = "",
    val chapterProgress: Double = 0.0,
    val sleepTimer: NarrationSleep = NarrationSleep(),
    val rate: Double = 1.0,
    val voiceID: String? = null,
)

/** The sentence being read, as a chapter range — what Ask quotes mid-listen. */
@Serializable
data class NarrationSentence(val chapterIndex: Int, val utf16Start: Int, val utf16End: Int)

/**
 * The reader's view of narration: a thin layer over the facade's
 * `AndroidNarration`, which owns every playback rule.
 *
 * It does only what the kit cannot — build the platform synthesizer, run the
 * once-a-second tick the sleep timer has no clock for, persist the reader's
 * speed and voice between books under the keys the iOS app uses, and hold the
 * Ask pause so the voice picks up where a question left it.
 *
 * **Main thread.** `NarrationController` is main-thread-confined and there is
 * no queue on the Swift side to hop with, so every call into the facade
 * happens on `Dispatchers.Main.immediate` and every callback out of it arrives
 * there (see `PlatformSpeechBackend`). Nothing here is synchronised, because
 * nothing here is ever on two threads.
 */
class NarrationModel(
    private val context: Context,
    private val openKit: suspend () -> Kit,
    val bookId: String,
    private val settings: ReaderSettings,
    /** Swapped for a deterministic stand-in by the instrumented tests. */
    private val backends: (NarrationEvents) -> SpeechBackend = { events ->
        PlatformSpeechBackend(context, events)
    },
) : NarrationObserver {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val arena = SwiftArena.ofAuto()
    private var events: NarrationEvents? = null
    private var backend: SpeechBackend? = null
    private var narration: AndroidNarration? = null
    private var opening: Job? = null
    private var ticker: Job? = null

    var status by mutableStateOf(IDLE)
        private set
    /** The sentence being read, collapsed for display by the facade. */
    var sentence by mutableStateOf("")
        private set
    var chapterIndex by mutableIntStateOf(-1)
        private set
    /** Where the voice is, to the word — what the page follows. */
    var utf16Offset by mutableIntStateOf(0)
        private set
    /** Where the sentence began — the resume anchor, and the offset to persist. */
    var utf16SentenceStart by mutableIntStateOf(0)
        private set
    var chapterProgress by mutableDoubleStateOf(0.0)
        private set
    var sleep by mutableStateOf(NarrationSleep())
        private set
    /** The sentence shown in place of the text when narration stopped by itself. */
    var holdText by mutableStateOf<String?>(null)
        private set
    var rate by mutableDoubleStateOf(settings.narrationRate)
        private set
    var voiceID by mutableStateOf(settings.narrationVoiceID)
        private set

    /** True whenever the Listen card should be on screen. */
    val isActive: Boolean get() = status != IDLE
    /** Speaking, or about to be — what the play/pause control shows as Pause. */
    val isUnderway: Boolean get() = status == SPEAKING || status == PREPARING

    /**
     * Where the voice is, for the page to follow: the chapter, the word, and
     * the sentence's start. Wired by the reader while it is on screen.
     */
    var onPosition: ((chapterIndex: Int, utf16Offset: Int, utf16SentenceStart: Int) -> Unit)? = null

    // MARK: Session

    /**
     * Read aloud from a place in the book. `anchor` is [NEXT_SENTENCE_START]
     * (the top of the visible page, or a chapter picked from Contents) or
     * [SENTENCE_CONTAINING] (a selection — the reader means the sentence their
     * finger is on).
     */
    fun listen(chapterIndex: Int, utf16Offset: Int, anchor: String = NEXT_SENTENCE_START) {
        withNarration { it.start(chapterIndex.toLong(), utf16Offset.toLong(), anchor) }
    }

    /** Close the card. The place is kept — the reader's position was saved from the sentence starts. */
    fun stopListening() {
        pausedForAsk = false
        narration?.stop()
        refresh()
    }

    fun togglePlayPause() = withNarration { it.togglePlayPause() }
    fun play() = withNarration { it.play() }
    fun pause() = withNarration { it.pause() }
    fun skipToNextSentence() = withNarration { it.skipToNextSentence() }
    fun skipToPreviousSentence() = withNarration { it.skipToPreviousSentence() }
    fun skipToNextChapter() = withNarration { it.skipToNextChapter() }
    fun skipToPreviousChapter() = withNarration { it.skipToPreviousChapter() }

    /** The speed control. Persisted under the iOS key, whether or not a voice is reading. */
    fun chooseRate(value: Double) {
        rate = value
        narration?.setRate(value)
        // Read back rather than trusting what was asked for — the kit clamps
        // it — and persist what it settled on.
        refresh()
        settings.narrationRate = rate
    }

    /** The voice, persisted under the iOS key; `null` leaves the choice to the engine. */
    fun chooseVoice(id: String?) {
        voiceID = id
        settings.narrationVoiceID = id
        narration?.setVoice(id.orEmpty())
        refresh()
    }

    fun setSleepTimer(mode: String, minutes: Int? = null) {
        narration?.setSleepTimer(kitJson.encodeToString(SleepRequest(mode, minutes)))
        refresh()
    }

    /** The voices worth offering for this book, best first. Empty before the first Listen. */
    fun voices(): List<NarrationVoice> = narration?.let {
        runCatching { kitJson.decodeFromString<List<NarrationVoice>>(it.voicesJSON()) }.getOrNull()
    }.orEmpty()

    // MARK: Ask

    /** Whether Ask paused the voice, so only Ask may start it again. */
    private var pausedForAsk = false

    /**
     * Ask opened while the voice was reading: pause it. Listening to the next
     * page while reading an answer about this one is nobody's wish.
     */
    fun pauseForAsk() {
        if (!isUnderway) return
        pause()
        pausedForAsk = true
    }

    /**
     * Ask went away: the voice picks up the sentence it paused on — if it was
     * Ask that paused it, and nothing has moved it since. A reader who pressed
     * pause themselves keeps their pause; a book that ran out stays finished.
     */
    fun resumeAfterAsk() {
        if (!pausedForAsk) return
        pausedForAsk = false
        if (status == PAUSED) play()
    }

    /**
     * Whether a question with no selection is about the sentence being read.
     * A voice the *reader* paused does not count: they may have read on by eye
     * since, and a question then is about the book. (Paused by Ask still counts.)
     */
    val countsAsReading: Boolean get() = isUnderway || pausedForAsk

    /** The sentence being read, as a chapter range, or null when none is. */
    fun currentSentence(): NarrationSentence? {
        val json = narration?.currentSentenceRangeJSON().orEmpty()
        if (json.isEmpty()) return null
        return runCatching { kitJson.decodeFromString<NarrationSentence>(json) }.getOrNull()
    }

    // MARK: The facade's reports

    override fun statusChanged(status: String) {
        this.status = status
        if (status == IDLE) stopTicking() else startTicking()
    }

    override fun positionChanged(chapterIndex: Long, utf16Offset: Long, utf16SentenceStart: Long) {
        this.chapterIndex = chapterIndex.toInt()
        this.utf16Offset = utf16Offset.toInt()
        this.utf16SentenceStart = utf16SentenceStart.toInt()
        if (chapterIndex < 0) return
        onPosition?.invoke(chapterIndex.toInt(), utf16Offset.toInt(), utf16SentenceStart.toInt())
    }

    /**
     * The word being spoken. A4a draws no read-along underline — the page
     * follows the voice through [positionChanged], which carries the same
     * word — so there is nothing to do with it yet; this is the hook the
     * underline will hang on when it lands.
     */
    override fun spokenRange(chapterIndex: Long, utf16Start: Long, utf16End: Long) = Unit

    override fun sentenceChanged(text: String) {
        sentence = text
    }

    override fun sleepTimerChanged(json: String) {
        sleep = runCatching { kitJson.decodeFromString<NarrationSleep>(json) }.getOrNull()
            ?: NarrationSleep()
    }

    override fun holdChanged(reason: String) {
        // The reason is a token; the sentence for it comes from the facade
        // with the rest of the state, so nothing here writes copy.
        if (reason.isEmpty()) holdText = null else refresh()
    }

    // MARK: Plumbing

    /**
     * Run `body` against the session, opening one first if there is none. The
     * facade is built on the main thread; only resolving the kit (which loads
     * the Swift runtime on first use) goes off it.
     */
    private fun withNarration(body: (AndroidNarration) -> Unit) {
        narration?.let {
            body(it)
            refresh()
            startTicking()
            return
        }
        if (opening?.isActive == true) return
        opening = scope.launch {
            val built = open() ?: return@launch
            body(built)
            refresh()
            startTicking()
        }
    }

    private suspend fun open(): AndroidNarration? {
        narration?.let { return it }
        val kit = try {
            withContext(Dispatchers.IO) { openKit() }
        } catch (e: Exception) {
            Log.w(TAG, "narration could not open the library: ${e.message}")
            return null
        }
        // Everything below is on the main thread, which is where the
        // controller lives and where every callback comes back.
        val events = NarrationEvents.init(arena)
        val backend = backends(events)
        this.events = events
        this.backend = backend
        val built = AndroidNarration.init(
            kit.library,
            bookId,
            backend,
            events,
            this,
            kitJson.encodeToString(StoredSettings(rate, voiceID)),
            arena,
        )
        narration = built
        return built
    }

    /** Fields nothing pushes: the chapter's progress, and what the kit clamped. */
    private fun refresh() {
        val narration = narration ?: return
        val state = runCatching {
            kitJson.decodeFromString<NarrationState>(narration.stateJSON())
        }.getOrNull() ?: return
        status = state.status
        sentence = state.sentence
        chapterIndex = state.chapterIndex
        utf16Offset = state.utf16Offset
        utf16SentenceStart = state.utf16SentenceStart
        chapterProgress = state.chapterProgress
        sleep = state.sleepTimer
        holdText = state.holdText
        rate = state.rate
        voiceID = state.voiceID
        if (status == IDLE) stopTicking()
    }

    /**
     * The sleep timer has no clock of its own, and neither has the stall
     * watchdog that notices an utterance whose completion never arrived. This
     * is both of them.
     */
    private fun startTicking() {
        if (ticker?.isActive == true || !isActive) return
        ticker = scope.launch {
            while (isActive && this@NarrationModel.isActive) {
                delay(TICK_MILLIS)
                narration?.tick()
                refresh()
            }
        }
    }

    private fun stopTicking() {
        ticker?.cancel()
        ticker = null
    }

    /** Hand the synthesizer back — the model is finished with. */
    fun release() {
        stopTicking()
        narration?.stop()
        (backend as? PlatformSpeechBackend)?.release()
        onPosition = null
        scope.coroutineContext[Job]?.cancel()
    }

    /** What the facade decodes as the reader's stored `SpeechSettings`. */
    @Serializable
    private data class StoredSettings(val rate: Double, val voiceID: String? = null)

    companion object {
        const val IDLE = "idle"
        const val PREPARING = "preparing"
        const val SPEAKING = "speaking"
        const val PAUSED = "paused"
        const val FINISHED = "finished"

        /** The first sentence that begins at or after the offset — a page top. */
        const val NEXT_SENTENCE_START = "nextSentenceStart"
        /** The sentence containing the offset — a selection. */
        const val SENTENCE_CONTAINING = "sentenceContaining"

        private const val TICK_MILLIS = 1_000L
        private const val TAG = "Readr.Listen"
    }
}

/** One voice on offer, as the facade orders them. */
@Serializable
data class NarrationVoice(
    val id: String,
    val name: String,
    val language: String,
    val quality: String = "standard",
    val isDefault: Boolean = false,
)

/**
 * The process's narration, one book at a time.
 *
 * Keyed by book like [com.readrai.readr.ui.ask.AskConversations], but only
 * one model is ever alive: there is one synthesizer on the phone, and a second
 * book's card would be a second voice reading over the first. Opening another
 * book hands the previous engine back and starts fresh.
 */
class Narrations(
    private val context: Context,
    private val openKit: suspend () -> Kit,
    private val settings: ReaderSettings,
) {
    private var current: NarrationModel? = null

    @Synchronized
    fun forBook(bookId: String): NarrationModel {
        current?.let {
            if (it.bookId == bookId) return it
            it.release()
        }
        return NarrationModel(context, openKit, bookId, settings).also { current = it }
    }

    /** A removed book stops being read aloud. */
    @Synchronized
    fun forget(bookId: String) {
        val model = current ?: return
        if (model.bookId != bookId) return
        model.release()
        current = null
    }
}

/** The book's narration, bound to this composition. */
@Composable
fun rememberNarrationModel(bookId: String): NarrationModel {
    val app = LocalContext.current.applicationContext as ReadrApplication
    return remember(bookId) { app.narrations.forBook(bookId) }
}
