package com.readrai.readr

import android.media.AudioManager
import androidx.media3.common.Player
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
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
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoProbe(context))
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
     * Listen publishes a session at once, playing, with the sentence being
     * read as the title — what the lock screen shows is what is being said.
     */
    @Test
    fun listeningPublishesAPlayingSessionWithTheSentenceOnIt() {
        val model = listen()
        val player = model.media!!.player
        assertTrue("the session is the process's one", NarrationSession.active === model.media)
        assertTrue(onMain { player.playWhenReady })
        assertEquals(Player.STATE_READY, onMain { player.playbackState })

        val metadata = onMain { player.mediaMetadata }
        assertEquals("the sentence is the title", model.sentence, metadata.title.toString())
        assertTrue("and there is one", model.sentence.startsWith("Alpha 1"))
        assertEquals("the book is the album", "Read Aloud", metadata.albumTitle.toString())
        assertTrue("the chapter is the line under it", metadata.artist.toString().isNotBlank())
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

        onMain { player.seekToPrevious() }
        await("the chapter before") { model.chapterIndex == 0 }
        assertEquals(0, onMain { player.currentMediaItemIndex })
    }

    /**
     * Something else took the audio. A transient loss — a navigation prompt, a
     * call — pauses the voice and gives it back afterwards; a permanent one
     * pauses it for good, because the reader will say when to carry on.
     */
    @Test
    fun aTransientFocusLossPausesAndTheRegainResumes() {
        val model = listen()

        onMain { focus.send(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) }
        await("the voice to pause for the interruption") { model.status == NarrationModel.PAUSED }

        onMain { focus.send(AudioManager.AUDIOFOCUS_GAIN) }
        await("the voice to pick up again") { model.isUnderway }
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
        val store = Narrations(context, { kit }, settings) { events ->
            FakeSpeechBackend(events).also { backend = it }
        }
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
