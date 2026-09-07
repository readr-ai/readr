package com.readrai.readr.ui.listen

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
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
    /** Likewise the service, so a test can watch it start and stop. */
    private val service: NarrationServiceControl = SystemNarrationService,
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

    /** Whether the voice was paused by something else taking the audio, not by the reader. */
    private var pausedForFocus = false
    private var released = false

    init {
        active = this
        if (!this.focus.request(::focusChanged)) {
            // Nothing else will tell us; the phone is busy with something that
            // will not share. The kit's own pause is the honest answer.
            Log.w(TAG, "audio focus refused; not starting the voice in the background")
        }
        service.start(app)
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
        focus.abandon()
        // Released first: media3 takes a released session off the service by
        // itself, so the service is never left holding one.
        session.release()
        player.release()
        service.stop(app)
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
     */
    private fun focusChanged(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                pausedForFocus = false
                if (narration.isUnderway) narration.pause()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                if (!narration.isUnderway) return
                pausedForFocus = true
                narration.pause()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (!pausedForFocus) return
                pausedForFocus = false
                narration.play()
            }
            else -> Unit
        }
    }

    companion object {
        private const val TAG = "Readr.Listen"
        private var nextID = 0

        /**
         * The process's one live session, so [NarrationService] can find the
         * session it was started for. There is one synthesizer on the phone
         * and therefore one book being read; [Narrations] enforces the same.
         */
        @Volatile
        var active: NarrationSession? = null
            private set

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
 * [NarrationModel] — the sentence being read is the media item's title (the
 * hold's explanation takes that line while narration is held, as the Apple
 * app's now-playing info does), the chapter is the artist line and the book
 * the album — and every command is handed straight back to the model, which
 * hands it to the kit.
 *
 * The playlist is the book's **chapters**, which is what makes ⏭ and ⏮ on the
 * lock screen mean "next chapter": media3 turns `seekToNext` into a seek to
 * the next item, and the only thing this does with a seek is notice which way
 * the chapter moved. Sentence skips stay on the card, where a reader can see
 * what they are skipping.
 */
@OptIn(UnstableApi::class)
class NarrationPlayer(private val narration: NarrationModel) :
    SimpleBasePlayer(Looper.getMainLooper()) {

    /**
     * Re-read the model. `invalidateState` is media3's own and protected;
     * this is the door [NarrationSession] pushes a change through.
     */
    fun refreshState() = invalidateState()

    override fun getState(): State {
        val builder = State.Builder().setAvailableCommands(COMMANDS)
        if (!narration.isActive) {
            // Nothing is being read: an empty playlist, which media3 requires
            // to be idle or ended.
            return builder.setPlaybackState(STATE_IDLE).setPlayWhenReady(false, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST).build()
        }
        val now = narration.nowPlaying
        val chapters = now.chapterTitles.ifEmpty { listOf(now.title) }
        val index = narration.chapterIndex.coerceIn(chapters.indices)
        val playlist = chapters.mapIndexed { at, title ->
            MediaItemData.Builder(at)
                .setMediaItem(MediaItem.Builder().setMediaId("chapter/$at").build())
                .setMediaMetadata(metadata(now, title, current = at == index))
                .setIsSeekable(false)
                .build()
        }
        return builder
            .setPlaylist(playlist)
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

    /**
     * What the notification and the lock screen read. The sentence is the
     * title, so what is on the screen is what is being said; a hold takes that
     * line instead, because the lock screen is exactly where the reader is
     * when the voice stops by itself.
     */
    private fun metadata(now: NarrationNowPlaying, chapterTitle: String, current: Boolean): MediaMetadata {
        val title = if (current) narration.holdText ?: narration.sentence.ifBlank { now.title } else chapterTitle
        return MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(chapterTitle.ifBlank { now.authors })
            .setAlbumTitle(now.title)
            .setAlbumArtist(now.authors.ifBlank { null })
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK_CHAPTER)
            .build()
    }

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
     * ⏭ and ⏮. The playlist is the chapters, so the only thing to read out of
     * a seek is which way the chapter went; a seek that stays inside the
     * chapter is nothing to do — there is no timeline to move along.
     */
    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        val current = narration.chapterIndex
        when {
            mediaItemIndex > current -> narration.skipToNextChapter()
            mediaItemIndex < current -> narration.skipToPreviousChapter()
            else -> Unit
        }
        return Futures.immediateVoidFuture()
    }

    private companion object {
        val COMMANDS: Player.Commands = Player.Commands.Builder()
            .addAll(
                Player.COMMAND_PLAY_PAUSE,
                Player.COMMAND_PREPARE,
                Player.COMMAND_STOP,
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                Player.COMMAND_GET_TIMELINE,
                Player.COMMAND_GET_METADATA,
                Player.COMMAND_RELEASE,
            )
            .build()
    }
}

/** The book the session publishes, as `AndroidNarration.nowPlayingJSON` reports it. */
@Serializable
data class NarrationNowPlaying(
    val title: String = "",
    val authors: String = "",
    val chapterTitles: List<String> = emptyList(),
    val chapterIndex: Int = 0,
)

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

/** Starting and stopping [NarrationService], behind a seam for the same reason. */
interface NarrationServiceControl {
    fun start(context: Context)
    fun stop(context: Context)
}

object SystemNarrationService : NarrationServiceControl {
    override fun start(context: Context) {
        val intent = Intent(context, NarrationService::class.java)
        // The reader is looking at the book when Listen starts, so this is
        // never a background start; the service goes foreground as soon as it
        // has the session, which is inside onCreate.
        runCatching { ContextCompat.startForegroundService(context, intent) }
            .onFailure { Log.w("Readr.Listen", "narration service would not start: ${it.message}") }
    }

    override fun stop(context: Context) {
        runCatching { context.stopService(Intent(context, NarrationService::class.java)) }
    }
}
