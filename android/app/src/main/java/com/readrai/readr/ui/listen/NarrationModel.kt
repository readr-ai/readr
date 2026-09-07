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
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import android.os.Handler
import android.os.Looper
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
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
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
        get() = NarrationOptions.current.let { options ->
            when (mode) {
                AFTER -> options.sleepMinuteLabel((minutes ?: 1).coerceAtLeast(1))
                END_OF_CHAPTER -> options.endOfChapterLabel
                else -> options.offLabel
            }
        }

    companion object {
        const val OFF = "off"
        const val AFTER = "after"
        const val END_OF_CHAPTER = "endOfChapter"
    }
}

/**
 * The fixed lists the speed and sleep controls are drawn from — the kit's own
 * (`SpeechSettings.rateSteps`/`rateLabel`, `SleepTimer.minuteOptions`/
 * `displayName`), read through the facade rather than copied here. A step
 * added on one side used to have to be added on the other, and the copy is
 * exactly the kind of thing that goes quietly stale.
 *
 * `rateLabels` and `sleepMinuteLabels` run parallel to the values above them.
 */
@Serializable
data class NarrationOptions(
    val rateSteps: List<Double> = emptyList(),
    val rateLabels: List<String> = emptyList(),
    val sleepMinutes: List<Int> = emptyList(),
    val sleepMinuteLabels: List<String> = emptyList(),
    val sleepLabels: Map<String, String> = emptyMap(),
) {
    /** "1×", "1.25×" — the kit's label for one of its steps. */
    fun rateLabel(rate: Double): String {
        val index = rateSteps.indexOfFirst { kotlin.math.abs(it - rate) < 0.001 }
        // A stored speed that is not one of the kit's steps — a preferences
        // file written by a build with a different list — still has to read.
        return rateLabels.getOrNull(index) ?: "${Math.round(rate * 100) / 100.0}×"
    }

    fun sleepMinuteLabel(minutes: Int): String =
        sleepMinuteLabels.getOrNull(sleepMinutes.indexOf(minutes)) ?: "$minutes min"

    val offLabel: String get() = sleepLabels[NarrationSleep.OFF] ?: "Off"
    val endOfChapterLabel: String
        get() = sleepLabels[NarrationSleep.END_OF_CHAPTER] ?: "End of chapter"

    companion object {
        /** What the controls draw now; empty until the kit has been asked. */
        var current by mutableStateOf(NarrationOptions())
            private set

        /**
         * Ask the kit, once a process. No listening session is needed — the
         * lists are the same for every book — but the Swift runtime is, so
         * this is called once a [Kit] is open and before the card can draw.
         */
        fun loadOnce() {
            if (current.rateSteps.isNotEmpty()) return
            current = runCatching {
                kitJson.decodeFromString<NarrationOptions>(AndroidNarration.optionsJSON())
            }.getOrNull() ?: return
        }
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
    /**
     * The media session published while a voice is reading — the lock screen,
     * the notification and a headset button. A seam for the same reason
     * [backends] is one: a test states what the phone did with the audio
     * rather than provoking it.
     */
    private val sessions: (NarrationModel) -> NarrationSession? = { model ->
        NarrationSession(context, model)
    },
) : NarrationObserver {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val arena = SwiftArena.ofAuto()
    private var events: NarrationEvents? = null
    private var backend: SpeechBackend? = null
    private var narration: AndroidNarration? = null
    private var opening: Job? = null
    private var openJob: Deferred<AndroidNarration?>? = null
    private var preparingVoices: Job? = null
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
    /**
     * The voices the Appearance sheet's Voice row draws — the book's own
     * language first, then the rest, in the kit's `VoiceSelector` order.
     * Empty until a session exists (see [prepareVoices]); nothing here
     * re-ranks or re-words anything.
     */
    var voices by mutableStateOf(NarrationVoices())
        private set
    /** The book, its author and its chapters, as the media session publishes them. */
    var nowPlaying by mutableStateOf(NarrationNowPlaying())
        private set

    /**
     * The lock screen's half of listening, alive exactly while a voice is.
     * Public so the instrumented tests can read the state it publishes; the
     * app itself never touches it — [refresh] opens and releases it.
     */
    var media: NarrationSession? = null
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
        refreshVoices()
    }

    fun setSleepTimer(mode: String, minutes: Int? = null) {
        narration?.setSleepTimer(kitJson.encodeToString(SleepRequest(mode, minutes)))
        refresh()
    }

    /**
     * Fill [voices] without starting the voice. The Appearance sheet's Voice
     * row is where the narrator is chosen and a reader may open it before the
     * first Listen — the Apple app's `prepareVoices(for:)`, which resolves the
     * list for a book without narrating it.
     *
     * The phone cannot say which voices it has until its synthesizer has
     * started up, which is *after* the session is built (the same lateness the
     * facade's own lazy voice resolution exists for), so this opens the
     * session and then asks again for a few seconds. Idempotent, and it
     * stops as soon as there is a list.
     */
    fun prepareVoices() {
        if (preparingVoices?.isActive == true) return
        if (!voices.isEmpty) {
            refreshVoices()
            return
        }
        preparingVoices = scope.launch {
            open() ?: return@launch
            repeat(VOICE_TRIES) {
                refreshVoices()
                if (!voices.isEmpty) return@launch
                delay(VOICE_RETRY_MILLIS)
            }
            refreshVoices()
        }
    }

    /** Re-read the picker's payload. Nothing here orders or words anything. */
    private fun refreshVoices() {
        val json = narration?.voicesJSON().orEmpty()
        if (json.isEmpty()) return
        voices = runCatching { kitJson.decodeFromString<NarrationVoices>(json) }.getOrNull() ?: voices
    }

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
        syncMediaSession()
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
        // The sentence is the media item's title, so the lock screen follows
        // the voice the way the card does.
        media?.invalidate()
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

    /**
     * One session, however many callers ask for it at once: Listen and the
     * Appearance sheet's voice list can both want one, and two would be two
     * synthesizers reading one book.
     */
    private suspend fun open(): AndroidNarration? {
        narration?.let { return it }
        openJob?.let { return it.await() }
        val job = scope.async { build() }
        openJob = job
        return job.await()
    }

    private suspend fun build(): AndroidNarration? {
        narration?.let { return it }
        val kit = try {
            withContext(Dispatchers.IO) { openKit() }
        } catch (e: Exception) {
            Log.w(TAG, "narration could not open the library: ${e.message}")
            return null
        }
        // Everything below is on the main thread, which is where the
        // controller lives and where every callback comes back.
        NarrationOptions.loadOnce()
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
        refreshNowPlaying()
        return built
    }

    /**
     * The book the media session publishes — the kit's own title, author and
     * chapter headings, so nothing on this side writes one. Asked once a
     * session: none of it changes under one.
     */
    private fun refreshNowPlaying() {
        val json = narration?.nowPlayingJSON().orEmpty()
        if (json.isEmpty()) return
        nowPlaying = runCatching { kitJson.decodeFromString<NarrationNowPlaying>(json) }.getOrNull()
            ?: nowPlaying
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
        syncMediaSession()
    }

    /**
     * The lock screen exists exactly while a voice does. Opening it is what
     * starts [NarrationService], and letting it go is what stops it — so
     * background playback can only ever mean the screen is off or another app
     * is in front, never that the reader walked away from the book.
     */
    private fun syncMediaSession() {
        if (isActive) {
            val session = media ?: sessions(this)?.also { media = it } ?: return
            session.invalidate()
        } else {
            media?.release()
            media = null
        }
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
        media?.release()
        media = null
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
        /** How long [prepareVoices] waits for a synthesizer to finish starting up. */
        private const val VOICE_TRIES = 24
        private const val VOICE_RETRY_MILLIS = 250L
        private const val TAG = "Readr.Listen"
    }
}

/** One voice on offer, in the facade's order — the kit's `VoiceSelector`. */
@Serializable
data class NarrationVoice(
    val id: String,
    val name: String,
    val language: String,
    val quality: String = "standard",
    val isDefault: Boolean = false,
    /**
     * What the kit would choose for this book with nothing stored. Marked in
     * the picker, and not necessarily the row that is checked — a reader who
     * picked another voice keeps it.
     */
    val isRecommended: Boolean = false,
)

/**
 * Everything the Voice row draws, as `AndroidNarration.voicesJSON` reports
 * it: the book's own language first, everything else behind "Other voices",
 * which voice is reading, and — when the phone has no voice data at all —
 * the facade's sentence saying so. Kotlin neither orders nor words any of it.
 */
@Serializable
data class NarrationVoices(
    val voices: List<NarrationVoice> = emptyList(),
    val otherVoices: List<NarrationVoice> = emptyList(),
    val recommendedID: String? = null,
    val selectedID: String? = null,
    val selectedName: String? = null,
    val emptyText: String = "",
) {
    val isEmpty: Boolean get() = voices.isEmpty() && otherVoices.isEmpty()

    /**
     * The row the picker checks: the reader's own choice, or — before they
     * have made one, and before the phone's engine has finished starting up
     * and let the kit settle it — the voice that would read. A list with a
     * name on the row above it and no tick anywhere in it says nothing.
     */
    val checkedID: String? get() = selectedID ?: recommendedID
}

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
    /**
     * The synthesizer, for the instrumented tests. [NarrationModel] already
     * takes a stand-in; a test that goes through `forBook` and `forget` — the
     * lifetime *this* class owns — has to be able to hand one down. Null in
     * the app, which means the phone's own.
     */
    private val backends: ((NarrationEvents) -> SpeechBackend)? = null,
) {
    private var current: NarrationModel? = null

    @Synchronized
    fun forBook(bookId: String): NarrationModel {
        current?.let {
            if (it.bookId == bookId) return it
            it.release()
        }
        val model = if (backends == null) {
            NarrationModel(context, openKit, bookId, settings)
        } else {
            NarrationModel(context, openKit, bookId, settings, backends)
        }
        return model.also { current = it }
    }

    /** A removed book stops being read aloud. */
    @Synchronized
    fun forget(bookId: String) {
        val model = current ?: return
        if (model.bookId != bookId) return
        model.release()
        current = null
    }

    /**
     * The reader left this book: the voice stops and the synthesizer goes
     * back. Takes the model rather than an id so a screen given a stand-in
     * ([NarrationModel]'s `backends` hook, in the instrumented tests) releases
     * the one it was actually reading with.
     */
    @Synchronized
    fun release(model: NarrationModel) {
        if (current === model) current = null
        model.release()
    }
}

/**
 * The reader's claim on a voice, scoped to their entry on the back stack.
 *
 * Narration deliberately outlives the composition — a rotation, or the trip
 * to the provider settings Ask's empty state offers, must not cut the voice
 * off mid-sentence — so it cannot be released in an `onDispose`. It must not
 * outlive the *reader*, though: a book left behind that goes on reading aloud
 * from the library screen is the bug this closes. A `ViewModel` on the
 * reader's `NavBackStackEntry` is exactly that lifetime.
 */
class NarrationLease(private val onDeparture: () -> Unit) : ViewModel() {
    override fun onCleared() {
        // Everything narration touches is main-thread-confined, the Swift
        // controller included. `onCleared` already runs there in practice;
        // this makes it so whatever cleared the store.
        val main = Looper.getMainLooper()
        if (Looper.myLooper() == main) onDeparture() else Handler(main).post(onDeparture)
    }
}

/** The book's narration, bound to this composition. */
@Composable
fun rememberNarrationModel(bookId: String): NarrationModel {
    val app = LocalContext.current.applicationContext as ReadrApplication
    return remember(bookId) { app.narrations.forBook(bookId) }
}

/**
 * Hold [narration] for as long as the reader is on the back stack, and stop
 * it when they leave. See [NarrationLease] for why this is a `ViewModel` and
 * not a `DisposableEffect`.
 */
@Composable
fun RememberNarrationLease(narration: NarrationModel) {
    val app = LocalContext.current.applicationContext as? ReadrApplication
    viewModel(key = "narration/${narration.bookId}") {
        NarrationLease { app?.narrations?.release(narration) ?: narration.release() }
    }
}
