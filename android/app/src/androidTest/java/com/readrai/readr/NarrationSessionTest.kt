package com.readrai.readr

import android.media.AudioManager
import androidx.media3.common.Player
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.EpubExtractor
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoModel
import com.readrai.readr.ui.listen.NarrationModel
import com.readrai.readr.ui.listen.NarrationService
import com.readrai.readr.ui.listen.NarrationSession
import com.readrai.readr.ui.listen.Narrations
import com.readrai.readr.ui.reader.ReaderSettings
import java.io.File
import kotlinx.coroutines.future.await
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The voice on the lock screen: the media session that keeps the book reading
 * with the screen off, and the notification, headset and audio-focus paths
 * that reach it.
 *
 * Everything but the synthesizer is real — the kit, the facade, the media3
 * session and player, and [NarrationService] itself — so what is checked here
 * is the wiring the reader actually gets. The synthesizer is
 * [FakeSpeechBackend], so nothing waits on audio, and audio focus is
 * [FakeAudioFocus], because "a call came in" is a thing the system does to an
 * app rather than a thing a test can provoke.
 */
@RunWith(AndroidJUnit4::class)
class NarrationSessionTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit
    private lateinit var settings: ReaderSettings
    private lateinit var settingsName: String
    private lateinit var book: BookSummary
    private lateinit var narration: NarrationModel
    private lateinit var backend: FakeSpeechBackend
    private val focus = FakeAudioFocus()
    private var narrations: Narrations? = null

    @Before
    fun setUp() = runBlocking {
        grantNotifications()
        root = File(context.cacheDir, "session-test-${System.nanoTime()}").apply { mkdirs() }
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoModel(context))
        settingsName = "session-test-${System.nanoTime()}"
        settings = ReaderSettings(context, settingsName)
        val text = buildString {
            for (chapter in 1..3) {
                append("# Chapter $chapter\n\n")
                append("Alpha $chapter is the first sentence here. ")
                append("Beta $chapter is the second sentence here. ")
                append("Gamma $chapter is the third sentence here.\n\n")
            }
        }
        val file = File(root, "session.txt").apply { writeText(text) }
        book = kitJson.decodeFromString(kit.library.importPlainText(file.absolutePath, "Read Aloud").await())
    }

    @After
    fun tearDown() {
        narrations?.let { store -> onMain { store.forget(book.id) } }
        if (::narration.isInitialized) onMain { narration.release() }
        // A service left standing would be the next test's problem, not this
        // one's — say so in the log rather than failing the teardown over it.
        runCatching { awaitService(running = false) }
        context.deleteSharedPreferences(settingsName)
        root.deleteRecursively()
    }

    /** A model whose synthesizer is the fake and whose audio focus the test owns. */
    private fun model(): NarrationModel = NarrationModel(
        context,
        { kit },
        book.id,
        settings,
        backends = { events -> FakeSpeechBackend(events).also { backend = it } },
        sessions = { model -> NarrationSession(context, model, focus = { focus }) },
    ).also { narration = it }

    /** Start reading at the top of the book and wait for the session to be published. */
    private fun listen(model: NarrationModel = model()): NarrationModel {
        onMain { model.listen(0, 0) }
        await("the voice to start") { model.isUnderway && model.media != null }
        return model
    }

    private fun await(what: String, timeoutMs: Long = 20_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (onMain(condition)) return
            Thread.sleep(25)
        }
        throw AssertionError("timed out waiting for $what")
    }

    private fun awaitService(running: Boolean) =
        await("the narration service to be ${if (running) "up" else "down"}") {
            NarrationService.running == running
        }

    /**
     * Listen publishes a session at once, playing, with the **book** on it —
     * and none of the book's text.
     *
     * A media notification is not a private surface: the lock screen shows it
     * to whoever picks the phone up and the shade keeps it in its history. The
     * sentence being read stays on the card, inside the app. What the
     * notification gets is the title, the chapter and the author, which is
     * what every audiobook player shows.
     */
    @Test
    fun listeningPublishesAPlayingSessionWithNoBookTextOnIt() {
        val model = listen()
        val player = model.media!!.player
        assertTrue("the session is the process's one", NarrationSession.active === model.media)
        assertTrue(onMain { player.playWhenReady })
        assertEquals(Player.STATE_READY, onMain { player.playbackState })

        val metadata = onMain { player.mediaMetadata }
        assertEquals("the book is the title", "Read Aloud", metadata.title.toString())
        assertEquals("the book is the album", "Read Aloud", metadata.albumTitle.toString())
        assertTrue("the chapter is the line under it", metadata.artist.toString().isNotBlank())

        // And the sentence being read is nowhere in any of it.
        val sentence = onMain { model.sentence }
        assertTrue("there is a sentence to leave out", sentence.startsWith("Alpha 1"))
        val published = listOfNotNull(
            metadata.title, metadata.artist, metadata.albumTitle, metadata.albumArtist,
            metadata.subtitle, metadata.description, metadata.displayTitle,
        ).map { it.toString() }
        for (field in published) {
            assertFalse(
                "the sentence reached the notification as '$field'",
                field.contains("Alpha 1"),
            )
        }

        // The playlist is the chapters, which is what makes ⏭ mean "next chapter".
        assertEquals(3, onMain { player.mediaItemCount })
        assertEquals(0, onMain { player.currentMediaItemIndex })
    }

    /** The service is up while a voice is reading, and gone when it stops. */
    @Test
    fun theServiceLivesExactlyAsLongAsTheVoice() {
        val model = listen()
        awaitService(running = true)

        onMain { model.stopListening() }
        await("the session to be let go") { model.media == null }
        assertNull(NarrationSession.active)
        awaitService(running = false)
    }

    /**
     * The notification's play/pause is the card's: it reaches the kit, which
     * stops the synthesizer on a pause and re-speaks the remainder of the
     * sentence as a fresh request on play (Android has no pause).
     */
    @Test
    fun theSessionsPlayPauseControlsTheVoice() {
        val model = listen()
        val player = model.media!!.player
        val stopsBefore = onMain { backend.stops }
        val spokenBefore = onMain { backend.spoken.size }

        onMain { player.pause() }
        await("the voice to pause") { model.status == NarrationModel.PAUSED }
        assertTrue("the synthesizer was stopped", onMain { backend.stops } > stopsBefore)
        assertFalse(onMain { player.playWhenReady })

        onMain { player.play() }
        await("the voice to pick up") { model.isUnderway }
        assertTrue("and re-spoken", onMain { backend.spoken.size } > spokenBefore)
        assertTrue(onMain { player.playWhenReady })
    }

    /**
     * ⏭ and ⏮ move by **chapter**, not by sentence: the playlist is the book's
     * chapters, so media3's own seek-to-next lands on the next one. Sentence
     * skips stay on the card, where the reader can see what they are skipping.
     */
    @Test
    fun seekingToTheNextItemIsTheNextChapter() {
        val model = listen()
        val player = model.media!!.player

        onMain { player.seekToNext() }
        await("the next chapter") { model.chapterIndex == 1 }
        assertTrue(model.sentence.startsWith("Alpha 2"))
        assertEquals(1, onMain { player.currentMediaItemIndex })

        // Read on, so ⏮ is pressed from the middle of a chapter — where a
        // track control restarts the chapter rather than leaving it. That is
        // the kit's rule, and it is a seek to the item already playing, which
        // is exactly the case an index comparison could not see.
        onMain { backend.finishCurrent() }
        await("a later sentence of the same chapter") { model.sentence.startsWith("Beta 2") }

        onMain { player.seekToPrevious() }
        await("the chapter to start again") { model.sentence.startsWith("Alpha 2") }
        assertEquals("still the same chapter", 1, onMain { model.chapterIndex })
        assertEquals("and the same item", 1, onMain { player.currentMediaItemIndex })

        // From the chapter's own first sentence, ⏮ is the chapter before.
        onMain { player.seekToPrevious() }
        await("the chapter before") { model.chapterIndex == 0 }
        assertEquals(0, onMain { player.currentMediaItemIndex })
    }

    /** ⏮ on the first chapter restarts it rather than doing nothing. */
    @Test
    fun previousAtTheFirstChapterRestartsIt() {
        val model = listen()
        val player = model.media!!.player
        onMain { backend.finishCurrent() }
        await("a later sentence") { model.sentence.startsWith("Beta 1") }

        onMain { player.seekToPrevious() }

        await("the chapter to start again") { model.sentence.startsWith("Alpha 1") }
        assertEquals(0, onMain { model.chapterIndex })
        assertEquals(0, onMain { player.currentMediaItemIndex })
    }

    /**
     * The transport offers what it can actually do. A ⏭ on the last chapter is
     * a control that does nothing when pressed, which reads as broken; ⏮ is
     * always there, because there is always a chapter to restart.
     */
    @Test
    fun theLastChapterOffersNoNextControl() {
        val model = listen()
        val player = model.media!!.player
        assertTrue("a next chapter exists at the start", onMain { player.hasNextMediaItem() })

        onMain { player.seekToNext() }
        await("the second chapter") { model.chapterIndex == 1 }
        onMain { player.seekToNext() }
        await("the last chapter") { model.chapterIndex == 2 }

        assertFalse("nothing follows the last chapter", onMain { player.hasNextMediaItem() })
        assertFalse(
            onMain { player.isCommandAvailable(Player.COMMAND_SEEK_TO_NEXT) }
        )
        assertTrue(
            "and there is always a chapter to go back to",
            onMain { player.isCommandAvailable(Player.COMMAND_SEEK_TO_PREVIOUS) },
        )
    }

    /**
     * The playlist is the chapters the **kit will read**, not every document
     * in the book. A `linear="no"` spine entry — a notes file, an answer key —
     * is skipped by continuous playback, so putting it on the lock screen
     * would offer a track that auto-advance refuses to play.
     */
    @Test
    fun nonLinearChaptersAreNotInThePlaylist() = runBlocking {
        val archive = IllustratedBook.write(File(root, "illustrated.epub"))
        val extracted = File(root, "illustrated-extracted")
        EpubExtractor.extract(archive.inputStream(), extracted)
        val illustrated: BookSummary = kitJson.decodeFromString(
            kit.library.importEPUB(extracted.absolutePath, archive.absolutePath, "Illustrated").await()
        )
        val model = NarrationModel(
            context, { kit }, illustrated.id, settings,
            backends = { events -> FakeSpeechBackend(events).also { backend = it } },
            sessions = { m -> NarrationSession(context, m, focus = { focus }) },
        ).also { narration = it }
        listen(model)

        val chapters = onMain { model.nowPlaying.chapters }
        assertEquals(
            "every chapter but the notes document",
            (0 until IllustratedBook.NOTES_CHAPTER).toList(),
            chapters.map { it.index },
        )
        assertEquals(chapters.size, onMain { model.media!!.player.mediaItemCount })
    }

    /**
     * The notification's timeline does not change as the book is read.
     *
     * The playlist is the book's chapters, and a book does not grow chapters
     * mid-sentence — so publishing the state once a sentence and once a second
     * must produce the *same* timeline every time. It used to be rebuilt from
     * scratch on every publish, with the sentence being read baked into each
     * row's metadata, which made it a new timeline a second: a flicker in the
     * shade and an `onTimelineChanged` for everything listening. What moves as
     * the reader listens is the current item, and only that.
     */
    @Test
    fun theTimelineOnlyChangesWhenTheChapterDoes() {
        val model = listen()
        val player = model.media!!.player
        var timelines = 0
        val listener = object : Player.Listener {
            override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
                timelines += 1
            }
        }
        onMain { player.addListener(listener) }
        try {
            onMain { backend.finishCurrent() }
            await("the next sentence") { model.sentence.startsWith("Beta 1") }
            onMain { backend.finishCurrent() }
            await("the one after") { model.sentence.startsWith("Gamma 1") }
            // A second of ticks on top of the sentence moves, for the tick's
            // own republishing.
            Thread.sleep(1_500)
            assertEquals("sentences are not timeline changes", 0, onMain { timelines })

            // And a chapter move is not one either — the same chapters are on
            // offer; it is the *current item* that moved.
            onMain { player.seekToNext() }
            await("the next chapter") { model.chapterIndex == 1 }
            assertEquals("nor is a chapter", 0, onMain { timelines })
            assertEquals("but the current item followed", 1, onMain { player.currentMediaItemIndex })
        } finally {
            onMain { player.removeListener(listener) }
        }
    }

    /**
     * Something else took the audio. A transient loss — a navigation prompt, a
     * call — pauses the voice and gives it back afterwards; a permanent one
     * pauses it for good, because the reader will say when to carry on.
     *
     * Neither is a pause this side performs: the interruption goes through the
     * kit, which holds the sentence with a reason the card and the
     * notification can explain — and the kit's own state is then what decides
     * whether the regain resumes.
     */
    @Test
    fun aTransientFocusLossPausesAndTheRegainResumes() {
        val model = listen()

        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) }
        await("the voice to pause for the interruption") { model.status == NarrationModel.PAUSED }
        assertEquals("the kit holds, with a reason", "audioInterrupted", onMain { model.holdReason })
        assertTrue("and words for it", onMain { model.holdText }.orEmpty().isNotEmpty())

        onMain { focus.send(AudioManager.AUDIOFOCUS_GAIN) }
        await("the voice to pick up again") { model.isUnderway }
        assertNull("and the explanation goes with it", onMain { model.holdText })
    }

    @Test
    fun aPermanentFocusLossPausesAndStaysPaused() {
        val model = listen()

        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS) }
        await("the voice to pause") { model.status == NarrationModel.PAUSED }

        // A gain arriving afterwards is not the reader asking to listen again.
        onMain { focus.send(AudioManager.AUDIOFOCUS_GAIN) }
        Thread.sleep(250)
        assertEquals(NarrationModel.PAUSED, onMain { model.status })
    }

    /**
     * The reader pressed pause during the call. When the call ends, the phone
     * hands the audio back — and that is not permission to start reading at
     * them. The kit clears its hold reason the moment the reader takes the
     * pause over, so the regain finds nothing of its own to resume.
     */
    @Test
    fun aReadersPauseDuringAnInterruptionSurvivesTheRegain() {
        val model = listen()
        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) }
        await("the hold") { model.holdReason == NarrationSession.HOLD_AUDIO_INTERRUPTED }

        onMain { model.pause() }
        assertNull("the reader owns the pause now", onMain { model.holdReason })

        onMain { focus.send(AudioManager.AUDIOFOCUS_GAIN) }
        Thread.sleep(250)
        assertEquals(NarrationModel.PAUSED, onMain { model.status })
    }

    /**
     * The same rule for Ask, which pauses the voice so a question is not read
     * over. A call arriving while the answer is on screen must not leave the
     * book reading aloud once it ends — dismissing Ask is what resumes it.
     */
    @Test
    fun anAskPauseDuringAnInterruptionSurvivesTheRegain() {
        val model = listen()
        onMain { model.pauseForAsk() }
        await("Ask's pause") { model.status == NarrationModel.PAUSED }

        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) }
        onMain { focus.send(AudioManager.AUDIOFOCUS_GAIN) }
        Thread.sleep(250)
        assertEquals("still Ask's pause", NarrationModel.PAUSED, onMain { model.status })

        onMain { model.resumeAfterAsk() }
        await("Ask to give it back") { model.isUnderway }
    }

    /**
     * A phone that will not share its audio: the voice does not run, and the
     * card says why. Logging a line and reading anyway would be a book talking
     * over someone's call.
     */
    @Test
    fun refusedFocusHoldsTheVoiceWithAnExplanation() {
        focus.granted = false
        val model = model()
        onMain { model.listen(0, 0) }

        await("the hold") { model.holdReason == NarrationSession.HOLD_AUDIO_INTERRUPTED }
        assertFalse("nothing is being read", onMain { model.isUnderway })
        assertTrue("and the card says why", onMain { model.holdText }.orEmpty().isNotEmpty())
    }

    /**
     * After a permanent loss the focus was given back, so the next Play is a
     * fresh request rather than a claim on something we no longer hold — and
     * the session does not ask twice for focus it already has.
     */
    @Test
    fun playAfterAPermanentLossAsksForTheAudioAgain() {
        val model = listen()
        assertEquals("asked once, when the voice started", 1, focus.requests)

        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS) }
        await("the voice to pause") { model.status == NarrationModel.PAUSED }
        assertTrue("and the audio was handed back", focus.abandoned)

        onMain { model.play() }
        await("the voice to read again") { model.isUnderway }
        assertEquals("a second request, not a stale claim", 2, focus.requests)
    }

    /** Ducking is ignored: a voice under someone else's music is not listenable. */
    @Test
    fun duckingLeavesTheVoiceAlone() {
        val model = listen()

        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK) }
        Thread.sleep(250)
        assertTrue(onMain { model.isUnderway })
    }

    /**
     * A book that goes away takes its voice with it — and now the session and
     * the service too. `Narrations` owns that lifetime, so the test goes
     * through it rather than round it.
     */
    @Test
    fun forgettingTheBookReleasesTheSessionAndStopsTheService() {
        val store = Narrations(
            context, { kit }, settings,
            backends = { events -> FakeSpeechBackend(events).also { backend = it } },
            sessions = { model -> NarrationSession(context, model, focus = { focus }) },
        )
        narrations = store
        val model = onMain { store.forBook(book.id) }
        narration = model
        listen(model)
        awaitService(running = true)
        assertNotNull(NarrationSession.active)

        onMain { store.forget(book.id) }

        await("the session to be released") { model.media == null }
        assertNull(NarrationSession.active)
        awaitService(running = false)
        assertEquals(NarrationModel.IDLE, onMain { model.status })
    }
}
