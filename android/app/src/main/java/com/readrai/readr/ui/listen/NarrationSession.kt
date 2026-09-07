package com.readrai.readr.ui.listen

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.SimpleBasePlayer.PositionSupplier
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.readrai.readr.MainActivity
import kotlinx.serialization.Serializable

/**
 * The book on the lock screen: one `MediaSession` over the voice, so the
 * reader can keep listening with the screen off and start, stop and skip from
 * the notification, the lock screen or a headset button.
 *
 * There is no `ExoPlayer` here and no audio file to play — the phone's own
 * synthesizer makes the sound, sentence by sentence, and every playback rule
 * is still the kit's ([NarrationModel] over `NarrationController`). What the
 * session publishes is a [NarrationPlayer]: a `SimpleBasePlayer` that owns no
 * playback at all and only *describes* the model, and whose commands are
 * forwarded straight back to it.
 *
 * The session lives exactly as long as a voice is reading. It is opened when
 * narration becomes active and released when it stops, and [NarrationService]
 * — the foreground service that carries its notification — is started and
 * stopped with it. That keeps the `NarrationLease` rule intact: background
 * playback means the screen is off or another app is in front, never that the
 * reader has left the book behind.
 *
 * **Main thread.** Everything here runs on the main looper, like the rest of
 * narration: the player is built for `Looper.getMainLooper()`, and both the
 * audio-focus callback and the media commands arrive there.
 */
@OptIn(UnstableApi::class)
class NarrationSession(
    context: Context,
    private val narration: NarrationModel,
    /** Swapped for a stand-in by the instrumented tests, which own no speakers. */
    focus: (Context) -> NarrationAudioFocus = ::SystemAudioFocus,
) {
    private val app = context.applicationContext
    private val focus = focus(app)

    /** What the session publishes: the model, described as a player. */
    val player = NarrationPlayer(narration)

    val session: MediaSession = MediaSession.Builder(app, player)
        // Unique per listening session: media3 refuses two live sessions with
        // one id, and a book opened straight after another would collide.
        .setId("readr-narration-${narration.bookId}-${nextID++}")
        .setSessionActivity(openTheReader(app))
        .build()

    /** Whether our focus request is registered with the system. */
    private var holdsFocus = false
    /** Whether a refusal is on its way to the kit — see [holdFocus]. */
    private var refusalPending = false
    private var released = false
    private val main = Handler(Looper.getMainLooper())

    init {
        active = this
        // The reader is looking at the book when Listen starts, so this is
        // never a background start; the service goes foreground as soon as it
        // has the session, which is inside `onCreate`.
        runCatching { ContextCompat.startForegroundService(app, serviceIntent(app)) }
            .onFailure { Log.w(TAG, "narration service would not start: ${it.message}") }
    }

    /**
     * Claim the phone's audio for the voice. Idempotent — the model says this
     * on every state change, and asking `AudioManager` twice for something we
     * already hold is noise.
     *
     * A refusal is not a quiet failure: the phone is busy with something that
     * will not share, so the voice must not run. The interruption goes to the
     * kit, which holds the sentence with a reason — and *that* is what puts
     * the explanation on the card and in the notification, rather than a line
     * in the log and a book reading aloud over someone's call.
     *
     * The refusal is *posted* because this is said from inside the kit's own
     * status callback, at the moment narration starts — and the sentence being
     * started is not on the engine yet, so there would be nothing to hold. A
     * refusal is an answer from outside the app in any case.
     */
    fun holdFocus() {
        if (released || holdsFocus || refusalPending) return
        if (focus.request(::focusChanged)) {
            holdsFocus = true
            return
        }
        refusalPending = true
        Log.w(TAG, "audio focus refused; the voice holds")
        main.post {
            refusalPending = false
            if (!released && !holdsFocus) narration.audioInterrupted()
        }
    }

    /**
     * Give it back — the reader is not listening any more.
     *
     * **Except during an interruption.** A transient loss (a call, a
     * navigation prompt) leaves our request registered with the system, and
     * that registration is the only way the regain ever reaches us;
     * abandoning it here would trade the resume for nothing. The kit's own
     * hold reason is what tells the two apart, and it is cleared the moment
     * the reader takes the pause over — at which point the audio really does
     * go back.
     */
    fun dropFocus() {
        if (narration.holdReason == HOLD_AUDIO_INTERRUPTED) return
        abandonFocus()
    }

    private fun abandonFocus() {
        if (!holdsFocus) return
        holdsFocus = false
        focus.abandon()
    }

    /** Re-read the model. Cheap: media3 diffs the state and reports only changes. */
    fun invalidate() {
        if (released) return
        player.refreshState()
    }

    /**
     * The reader is finished listening: the notification goes, the service
     * stops, and the phone gets its audio back. Idempotent — both the model's
     * own teardown and a service that outlived it call this.
     */
    fun release() {
        if (released) return
        released = true
        if (active === this) active = null
        // Unconditionally, not `dropFocus()`: the reader has finished
        // listening, so there is no regain worth keeping a registration for.
        abandonFocus()
        // Released first: media3 takes a released session off the service by
        // itself, so the service is never left holding one.
        session.release()
        player.release()
        runCatching { app.stopService(serviceIntent(app)) }
    }

    /** Stop the voice itself — what a swipe of the app off the recents list means. */
    fun stopNarration() = narration.stopListening()

    /**
     * Audio focus, on the rules speech wants: something transient (a
     * navigation prompt, a call) pauses the voice and gives it back
     * afterwards; something permanent (another app starting its own audio)
     * pauses it for good — the reader will say when to carry on. Ducking is
     * ignored: a quieter voice under someone else's music is not listenable,
     * and the alternative — pausing — is what a permanent loss already does.
     *
     * Neither loss pauses the voice from here. Both hand the interruption to
     * the kit, which holds the sentence with `audioInterrupted` as its reason
     * — so the card and the notification say why the book stopped, and the
     * **kit's own state** is what decides whether a regain resumes. This side
     * used to keep a `pausedForFocus` flag beside the kit's, and the two could
     * disagree: a reader who pressed pause during a call, or opened Ask, had
     * the voice started back up under them when the call ended. The reader's
     * pause clears the hold reason (`NarrationController.pause`), so the check
     * below simply finds nothing to resume.
     */
    private fun focusChanged(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Gone for good: give the registration back too, so the next
                // Play is a fresh request rather than a claim on something we
                // no longer hold. Before the hold, so `dropFocus`'s
                // interruption guard has nothing to protect.
                abandonFocus()
                narration.audioInterrupted()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> narration.audioInterrupted()
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (narration.holdReason != HOLD_AUDIO_INTERRUPTED) return
                narration.play()
            }
            else -> Unit
        }
    }

    companion object {
        private const val TAG = "Readr.Listen"
        private var nextID = 0

        /**
         * The kit's own token for "the system took the sound"
         * (`NarrationHoldReason.audioInterrupted`, as the facade names it).
         * The only thing a regain is allowed to resume.
         */
        const val HOLD_AUDIO_INTERRUPTED = "audioInterrupted"

        /**
         * The process's one live session, so [NarrationService] can find the
         * session it was started for. There is one synthesizer on the phone
         * and therefore one book being read; [Narrations] enforces the same.
         */
        @Volatile
        var active: NarrationSession? = null
            private set

        private fun serviceIntent(context: Context): Intent =
            Intent(context, NarrationService::class.java)

        private fun openTheReader(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}

/**
 * The voice described as a player, for the one part of Android that insists
 * on one: the media session.
 *
 * It plays nothing and decides nothing. `getState()` is a reading of
 * [NarrationModel] — the chapter is the artist line and the book is both the
 * title and the album — and every command is handed straight back to the
 * model, which hands it to the kit.
 *
 * **No book text reaches the notification.** The sentence being read used to
 * be the media item's title, so the lock screen showed a line of the book to
 * anyone who picked the phone up, and the shade kept it in its history. A
 * media notification is not a private surface; the card in the app is, and
 * that is where the sentence stays. A *hold* still takes the title line —
 * "Paused — another app is using the sound" is the app's own words about the
 * app's own state, and the lock screen is exactly where the reader is when the
 * voice stops by itself.
 *
 * The playlist is the book's **narratable chapters**, which is what makes ⏭
 * and ⏮ on the lock screen mean "next chapter": media3 turns `seekToNext` into
 * a seek to the next item. Sentence skips stay on the card, where a reader can
 * see what they are skipping.
 */
@OptIn(UnstableApi::class)
class NarrationPlayer(private val narration: NarrationModel) :
    SimpleBasePlayer(Looper.getMainLooper()) {

    /**
     * The playlist, rebuilt only when something in it changed.
     *
     * `getState()` runs on every publish — once a sentence, and once a second
     * on the tick — and media3 compares timelines by identity of the item
     * list. Rebuilding it each time made the notification a new timeline every
     * second, which is a visible flicker in the shade and a `onTimelineChanged`
     * for every listener. The key is everything the rows are built from.
     */
    private var cachedRows: List<MediaItemData>? = null
    private var cachedKey: Triple<List<NarrationChapter>, String?, String>? = null

    /**
     * Re-read the model. `invalidateState` is media3's own and protected;
     * this is the door [NarrationSession] pushes a change through.
     */
    fun refreshState() = invalidateState()

    override fun getState(): State {
        if (!narration.isActive) {
            // Nothing is being read: an empty playlist, which media3 requires
            // to be idle or ended.
            return State.Builder()
                .setAvailableCommands(commands(rows = 0, at = 0))
                .setPlaybackState(STATE_IDLE)
                .setPlayWhenReady(false, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
                .build()
        }
        val rows = rows()
        val index = indexOfCurrentChapter(rows)
        return State.Builder()
            .setAvailableCommands(commands(rows.size, index))
            .setPlaylist(rows)
            .setCurrentMediaItemIndex(index)
            // Nothing here has a duration or a timeline: a sentence is as long
            // as it is read for. The position is a *constant* zero rather than
            // the plain `0` — media3 extrapolates a bare number with the wall
            // clock while playing, and ⏮ then means "start this chapter again"
            // three seconds in, which is not what the button says. Held at
            // zero, ⏮ is the previous chapter for as long as one is playing.
            .setContentPositionMs(PositionSupplier.getConstant(0))
            .setPlaybackState(if (narration.status == NarrationModel.FINISHED) STATE_ENDED else STATE_READY)
            // Preparing counts as playing, so the lock screen offers a pause
            // for the wait rather than a play control that would do nothing —
            // the card shows Pause then for the same reason.
            .setPlayWhenReady(narration.isUnderway, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .build()
    }

    /** The rows, from the cache when nothing they are built from has changed. */
    private fun rows(): List<MediaItemData> {
        val now = narration.nowPlaying
        val chapters = now.chapters.ifEmpty { listOf(NarrationChapter(0, now.title)) }
        val key = Triple(chapters, narration.holdText, now.title)
        cachedRows?.let { if (key == cachedKey) return it }
        val built = chapters.map { chapter ->
            MediaItemData.Builder(chapter.index)
                .setMediaItem(MediaItem.Builder().setMediaId("chapter/${chapter.index}").build())
                .setMediaMetadata(metadata(now, chapter.title))
                .setIsSeekable(false)
                .build()
        }
        cachedRows = built
        cachedKey = key
        return built
    }

    /**
     * Which row is playing. The rows carry the *book's* chapter indices, not
     * their own positions, so this is a lookup rather than an offset — and a
     * chapter that is in no row (a notes document a reader opened and pressed
     * Listen on: `seek` honours any chapter, only auto-advance filters) falls
     * back to the last row before it rather than to a `coerceIn` on -1, which
     * is an exception.
     */
    private fun indexOfCurrentChapter(rows: List<MediaItemData>): Int {
        val chapters = narration.nowPlaying.chapters
        if (chapters.isEmpty()) return 0
        val current = narration.chapterIndex
        val exact = chapters.indexOfFirst { it.index == current }
        if (exact >= 0) return exact
        return chapters.indexOfLast { it.index <= current }.takeIf { it >= 0 } ?: 0
    }

    /**
     * What the notification and the lock screen read: the **book**, never a
     * line of it. The chapter is the artist line, so the shade still says
     * where the reader is; the sentence being read is the card's, in the app.
     * A hold takes the title line, because the lock screen is exactly where
     * the reader is when the voice stops by itself, and its words are the
     * app's own rather than the book's.
     */
    private fun metadata(now: NarrationNowPlaying, chapterTitle: String): MediaMetadata =
        MediaMetadata.Builder()
            .setTitle(narration.holdText ?: now.title)
            .setArtist(chapterTitle.ifBlank { now.authors })
            .setAlbumTitle(now.title)
            .setAlbumArtist(now.authors.ifBlank { null })
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK_CHAPTER)
            .build()

    override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        // Play and pause rather than a toggle: a media button of either kind
        // arrives here already resolved against what we last published, and
        // toggling on top of that would undo it on a stale reading.
        if (playWhenReady) narration.play() else narration.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleStop(): ListenableFuture<*> {
        narration.stopListening()
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()

    /**
     * ⏭ and ⏮, read from the **command** rather than from the index.
     *
     * Comparing `mediaItemIndex` against the current one was wrong twice over.
     * The row index and the chapter index are different numbers now, so the
     * comparison was against the wrong thing; and ⏮ mid-chapter is a seek to
     * the *same* row (the kit restarts the chapter first, which is what a
     * track control does), which read as "nothing moved" and did nothing at
     * all. media3 says which button was pressed; that is what to answer.
     */
    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM ->
                narration.skipToNextChapter()
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM ->
                narration.skipToPreviousChapter()
            Player.COMMAND_SEEK_TO_MEDIA_ITEM -> {
                // A row picked out of the queue: play that chapter from its
                // top. The row carries the book's own chapter index.
                val chapters = narration.nowPlaying.chapters
                chapters.getOrNull(mediaItemIndex)?.let { narration.listen(it.index, 0) }
            }
            // Anything else is a move along a timeline, and there is none: a
            // sentence is as long as it is read for.
            else -> Unit
        }
        return Futures.immediateVoidFuture()
    }

    /**
     * What the transport offers, for the state it is actually in. A ⏭ on the
     * last chapter is a control that does nothing when pressed, which reads as
     * broken; ⏮ is always offered, because the kit's rule restarts the chapter
     * before it steps back and there is always a chapter to restart.
     */
    private fun commands(rows: Int, at: Int): Player.Commands {
        val builder = Player.Commands.Builder().addAll(
            Player.COMMAND_PLAY_PAUSE,
            Player.COMMAND_PREPARE,
            Player.COMMAND_STOP,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
            Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_GET_METADATA,
            Player.COMMAND_RELEASE,
        )
        if (rows > 0) {
            builder.addAll(
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_MEDIA_ITEM,
            )
        }
        if (at < rows - 1) {
            builder.addAll(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
        }
        return builder.build()
    }
}

/**
 * The book the session publishes, as `AndroidNarration.nowPlayingJSON` reports
 * it: the title, who wrote it, and the chapters the kit will actually read.
 *
 * There is no current-chapter field. Where the voice is comes from the model,
 * which is told a hundred times a session; this is asked once, because none of
 * it changes under one.
 */
@Serializable
data class NarrationNowPlaying(
    val title: String = "",
    val authors: String = "",
    val chapters: List<NarrationChapter> = emptyList(),
)

/**
 * One chapter of the playlist. [index] is the chapter's own index in the book
 * — not the row's position, since chapters the kit will not narrate
 * (`linear="no"` spine entries, chapters with nothing to say) are not rows at
 * all. A seek to a row plays *that* chapter.
 */
@Serializable
data class NarrationChapter(val index: Int, val title: String)

/**
 * The phone's audio focus, behind a seam: the instrumented tests own no
 * speakers, and "something else took the audio" is a state a test has to be
 * able to state rather than provoke.
 */
interface NarrationAudioFocus {
    /** Ask for focus for playback. False when the phone will not give it. */
    fun request(onChange: (Int) -> Unit): Boolean
    fun abandon()
}

/**
 * `AudioManager` focus for spoken audio. Speech, not music: the attributes
 * say so, and ducking is not asked for — a voice under someone else's music
 * is not listenable, so the session pauses on a real loss instead.
 */
class SystemAudioFocus(context: Context) : NarrationAudioFocus {
    private val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private var request: AudioFocusRequest? = null

    override fun request(onChange: (Int) -> Unit): Boolean {
        val manager = manager ?: return false
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attributes)
            // The system may not duck us into inaudibility on its own; a
            // transient loss is reported and the session pauses.
            .setWillPauseWhenDucked(false)
            .setOnAudioFocusChangeListener { onChange(it) }
            .build()
        this.request = request
        return manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    override fun abandon() {
        val request = request ?: return
        this.request = null
        manager?.abandonAudioFocusRequest(request)
    }
}

