package com.readrai.readr

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.AskRepository
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
import com.readrai.readr.ui.ask.AskConversation
import com.readrai.readr.ui.ask.AskViewModel
import com.readrai.readr.ui.listen.NarrationModel
import com.readrai.readr.ui.reader.PageLayout
import com.readrai.readr.ui.reader.ReaderScreen
import com.readrai.readr.ui.reader.ReaderSettings
import com.readrai.readr.ui.reader.ReaderViewModel
import com.readrai.readr.ui.theme.ReadrTheme
import java.io.File
import kotlinx.coroutines.future.await
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Listen in the reader: the card, its controls, and the page following the
 * voice — over a real library and a real kit, with only the synthesizer faked
 * ([FakeSpeechBackend]), so that nothing waits on audio and every sentence
 * boundary is a thing the test states rather than hopes for.
 */
@RunWith(AndroidJUnit4::class)
class ListenCardTest {
    @get:Rule
    val compose = createComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit
    private lateinit var repository: LibraryRepository
    private lateinit var settings: ReaderSettings
    private lateinit var settingsName: String
    private lateinit var book: BookSummary
    private lateinit var narration: NarrationModel
    private lateinit var backend: FakeSpeechBackend
    private lateinit var ask: AskViewModel
    /**
     * The reader's own `ViewModelStore` — in the app it is the back-stack
     * entry's, and clearing it is what popping the reader does. The narration
     * lease lives on it.
     */
    private lateinit var store: ViewModelStore

    /** Long enough that a chapter runs to several pages, so the voice has somewhere to walk. */
    private val filler = "It was the best of times, it was the worst of times, it was the age of wisdom, " +
        "it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity."

    @Before
    fun setUp() = runBlocking {
        root = File(context.cacheDir, "listen-test-${System.nanoTime()}").apply { mkdirs() }
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoProbe(context))
        repository = LibraryRepository(context, kit)
        settingsName = "listen-test-${System.nanoTime()}"
        settings = ReaderSettings(context, settingsName)
        val text = buildString {
            for (chapter in 1..3) {
                append("# Chapter $chapter\n\n")
                append("Alpha $chapter is the first sentence here. ")
                append("Beta $chapter is the second sentence here. ")
                append("Gamma $chapter is the third sentence here.\n\n")
                for (paragraph in 1..12) append("$chapter.$paragraph $filler\n\n")
            }
        }
        val file = File(root, "listen.txt").apply { writeText(text) }
        book = kitJson.decodeFromString(kit.library.importPlainText(file.absolutePath, "Read Aloud").await())
        repository.refresh()
    }

    @After
    fun tearDown() {
        if (::narration.isInitialized) onMain { narration.release() }
        context.deleteSharedPreferences(settingsName)
        root.deleteRecursively()
    }

    /** The reader, with narration wired to a synthesizer the test drives. */
    private fun open(scrolling: Boolean = false): ReaderViewModel {
        if (scrolling) settings.update { it.copy(layout = PageLayout.Scroll) }
        val model = ReaderViewModel({ repository }, book.id)
        narration = NarrationModel(
            context, { kit }, book.id, settings,
            backends = { events -> FakeSpeechBackend(events).also { backend = it } },
        )
        ask = AskViewModel({ AskRepository(kit) }, AskConversation(book.id))
        store = ViewModelStore()
        val owner = object : ViewModelStoreOwner {
            override val viewModelStore: ViewModelStore get() = store
        }
        compose.setContent {
            ReadrTheme {
                CompositionLocalProvider(LocalViewModelStoreOwner provides owner) {
                    ReaderScreen(model, settings, ask = ask, narration = narration, onBack = {})
                }
            }
        }
        awaitTag(if (scrolling) "reader.scrollLabel" else "reader.pageLabel")
        return model
    }

    /** What the reader's place would be written down as, once it settles. */
    private fun savedPlace() = runBlocking { repository.position(book.id) }

    /** Polls off the compose clock — for the tests that drive the view model directly. */
    private fun <T : Any> awaitValue(what: String, timeoutMs: Long = 15_000, value: () -> T?): T {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            value()?.let { return it }
            Thread.sleep(25)
        }
        error("timed out waiting for $what")
    }

    private fun nodes(tag: String) = compose.onAllNodes(hasTestTag(tag)).fetchSemanticsNodes()
    private fun awaitTag(tag: String) = compose.waitUntil(20_000) { nodes(tag).isNotEmpty() }
    private fun awaitNoTag(tag: String) = compose.waitUntil(10_000) { nodes(tag).isEmpty() }

    private fun sentenceOnCard(): String =
        nodes("listen.sentence").firstOrNull()?.config?.get(SemanticsProperties.Text)
            ?.joinToString { it.text } ?: ""

    private fun playPauseLabel(): String =
        nodes("listen.playPause").firstOrNull()?.config?.get(SemanticsProperties.ContentDescription)
            ?.firstOrNull() ?: ""

    private fun speedLabel(): String =
        nodes("listen.speed").firstOrNull()?.config?.get(SemanticsProperties.Text)
            ?.joinToString { it.text } ?: ""

    /** The chapter text the reader is on, for turning words into offsets. */
    private fun chapterText(index: Int) = runBlocking { repository.chapterText(book.id, index) }

    /** Tap Listen and wait for the card. */
    private fun startListening() {
        compose.onNodeWithTag("reader.listen").performClick()
        awaitTag("listen.bar")
        compose.waitUntil(10_000) { backendReady() && sentenceOnCard().isNotEmpty() }
    }

    private fun backendReady(): Boolean = ::backend.isInitialized

    /** The voice speaks the current sentence through, on the thread it lives on. */
    private fun finishSentence() {
        compose.runOnUiThread { backend.finishCurrent() }
        compose.waitForIdle()
    }

    @Test
    fun listenOpensTheCardOnTheFirstSentenceOfThePage() {
        open()
        startListening()
        assertTrue(sentenceOnCard(), sentenceOnCard().startsWith("Alpha 1"))
        assertEquals("Pause", playPauseLabel())
        assertEquals(
            "the reader is told what the control will do",
            "Stop listening",
            nodes("reader.listen").first().config[SemanticsProperties.ContentDescription].first(),
        )
    }

    @Test
    fun playPauseToggles() {
        open()
        startListening()
        assertEquals("Pause", playPauseLabel())
        compose.onNodeWithTag("listen.playPause").performClick()
        compose.waitUntil(5_000) { playPauseLabel() == "Play" }
        compose.onNodeWithTag("listen.playPause").performClick()
        compose.waitUntil(5_000) { playPauseLabel() == "Pause" }
    }

    @Test
    fun nextMovesToTheFollowingSentence() {
        open()
        startListening()
        val first = sentenceOnCard()
        compose.onNodeWithTag("listen.next").performClick()
        compose.waitUntil(5_000) { sentenceOnCard() != first && sentenceOnCard().isNotEmpty() }
        assertTrue(sentenceOnCard(), sentenceOnCard().startsWith("Beta 1"))
    }

    /**
     * The page goes where the voice goes, and the place written down is the
     * sentence it is reading — not the top of the page, which is where the
     * reader would resume from otherwise.
     */
    @Test
    fun thePageFollowsTheVoice() {
        val model = open()
        startListening()
        val chapter = chapterText(0)
        val beta = chapter.indexOf("Beta 1")
        // The chapter opens on "Alpha 1 …"; speaking it through moves to "Beta 1 …".
        finishSentence()
        compose.waitUntil(10_000) { sentenceOnCard().startsWith("Beta 1") }
        assertEquals("the anchor is the sentence being read", beta, model.anchor)
    }

    /** ✕ closes the card, and the place kept is the sentence the voice was on. */
    @Test
    fun stoppingKeepsTheSentenceAsThePlace() {
        open()
        startListening()
        val chapter = chapterText(0)
        val beta = chapter.indexOf("Beta 1")
        finishSentence()
        compose.waitUntil(10_000) { sentenceOnCard().startsWith("Beta 1") }

        compose.onNodeWithTag("listen.close").performClick()
        awaitNoTag("listen.bar")
        compose.waitUntil(15_000) { runBlocking { repository.position(book.id)?.utf16Offset } == beta }
        val saved = runBlocking { repository.position(book.id)!! }
        assertEquals(0, saved.chapterIndex)
        assertEquals(beta, saved.utf16Offset)
    }

    /** The speed control relabels itself, and the choice is kept for the next book. */
    @Test
    fun theSpeedMenuChangesTheLabel() {
        open()
        startListening()
        assertEquals("1×", speedLabel())
        compose.onNodeWithTag("listen.speed").performClick()
        compose.onNodeWithText("1.5×").performClick()
        compose.waitUntil(5_000) { speedLabel() == "1.5×" }
        assertEquals(1.5, settings.narrationRate, 0.001)
    }

    /** The sleep control reads out what is left of a timed sleep. */
    @Test
    fun theSleepMenuArmsACountdown() {
        open()
        startListening()
        compose.onNodeWithTag("listen.sleep").performClick()
        compose.onNodeWithText("5 min").performClick()
        compose.waitUntil(10_000) {
            nodes("listen.sleep").firstOrNull()?.config?.get(SemanticsProperties.Text)
                ?.joinToString { it.text }?.contains(":") == true
        }
    }

    /**
     * Opening Ask pauses the voice — listening to the next page while reading
     * an answer about this one is nobody's wish — and dismissing it gives the
     * voice back on the same sentence.
     */
    @Test
    fun askPausesTheVoiceAndDismissingResumesIt() {
        open()
        startListening()
        val sentence = sentenceOnCard()
        assertEquals("Pause", playPauseLabel())

        compose.onNodeWithTag("reader.ask").performClick()
        compose.waitUntil(10_000) { playPauseLabel() == "Play" }

        compose.runOnUiThread { ask.close(); narration.resumeAfterAsk() }
        compose.waitUntil(10_000) { playPauseLabel() == "Pause" }
        assertEquals("the same sentence, picked back up", sentence, sentenceOnCard())
    }

    /**
     * "Listen from here" on a selection starts on the sentence the reader's
     * finger was in, not the next one — the page rule would skip the very
     * words they pointed at.
     */
    @Test
    fun theCapsuleListensFromTheSelectedSentence() {
        open()
        val (point, word) = compose.wordOnThePage()
        compose.onNodeWithTag("reader.page").performTouchInput { longClick(point) }
        awaitTag("annotation.capsule")

        compose.onNodeWithTag("annotation.listen").performScrollTo().performClick()
        awaitTag("listen.bar")
        compose.waitUntil(10_000) { sentenceOnCard().isNotEmpty() }

        val spoken = compose.runOnUiThread { backend.lastText }.orEmpty()
        assertTrue(
            "the sentence being read holds the word that was pressed ('$word'): '$spoken'",
            spoken.contains(word),
        )
    }


    /**
     * Leaving the reader stops the voice. Narration deliberately outlives the
     * composition — a rotation, or the trip to the provider settings, must not
     * cut it off mid-sentence — so nothing in `onDispose` can do this; the
     * lease on the reader's back-stack entry does. Clearing that entry's
     * `ViewModelStore` is what popping the reader amounts to.
     */
    @Test
    fun leavingTheReaderStopsTheVoice() {
        open()
        startListening()
        val stopsBefore = compose.runOnUiThread { backend.stops }

        compose.runOnUiThread { store.clear() }

        awaitNoTag("listen.bar")
        assertEquals(NarrationModel.IDLE, narration.status)
        assertTrue(
            "the synthesizer was handed the sentence back",
            compose.runOnUiThread { backend.stops } > stopsBefore,
        )
    }

    /**
     * A jump inside the chapter the voice is reading leaves the voice alone:
     * a reader looking something up two pages on has not asked it to start
     * again — and restarting would re-arm the sleep timer they set.
     */
    @Test
    fun aJumpInsideTheChapterBeingReadDoesNotRestartTheVoice() {
        open()
        startListening()
        val sentence = sentenceOnCard()
        val spokenBefore = compose.runOnUiThread { backend.spoken.size }

        compose.onNodeWithTag("reader.toc").performClick()
        awaitTag("contents.row.0")
        compose.onNodeWithTag("contents.row.0").performClick()
        awaitNoTag("contents.list")
        compose.waitForIdle()

        assertEquals(
            "nothing new was spoken",
            spokenBefore,
            compose.runOnUiThread { backend.spoken.size },
        )
        assertEquals("the same sentence, still being read", sentence, sentenceOnCard())
    }

    /** A jump into another chapter takes the voice with it. */
    @Test
    fun aJumpToAnotherChapterTakesTheVoiceAlong() {
        open()
        startListening()

        compose.onNodeWithTag("reader.toc").performClick()
        awaitTag("contents.row.1")
        compose.onNodeWithTag("contents.row.1").performClick()
        awaitNoTag("contents.list")

        compose.waitUntil(10_000) { sentenceOnCard().startsWith("Alpha 2") }
        assertEquals(1, narration.chapterIndex)
    }

    /**
     * In a scroll the place written down is still the sentence being read. The
     * list echoes back the line at the top of its viewport on every frame, and
     * that echo used to read as a page turn — which cleared the voice's resume
     * anchor and saved the top of the screen instead of the sentence.
     */
    @Test
    fun followingTheVoiceInAScrollStillSavesTheSentence() {
        open(scrolling = true)
        startListening()
        val beta = chapterText(0).indexOf("Beta 1")

        finishSentence()
        compose.waitUntil(10_000) { sentenceOnCard().startsWith("Beta 1") }

        compose.waitUntil(20_000) { savedPlace()?.utf16Offset == beta }
        assertEquals(0, savedPlace()!!.chapterIndex)
    }

    /**
     * The voice's sentence is the place only in the chapter the voice is in.
     * A reader who crosses back out of that chapter takes their own page with
     * them; keeping the offset would save an offset from one chapter against
     * the index of another — some way into a chapter they had walked out of,
     * or past its end entirely.
     */
    @Test
    fun crossingBackOutOfTheChapterBeingReadDropsTheVoicesAnchor() {
        val model = ReaderViewModel({ repository }, book.id)
        awaitValue("the book to open") { model.state as? ReaderViewModel.State.Ready }
        val beta = chapterText(1).indexOf("Beta 2")

        onMain { model.jump(1, 0) }
        awaitValue("chapter two") { model.chapter?.takeIf { it.index == 1 } }
        onMain { model.followVoice(beta, beta) }

        onMain { model.overflow(-1) }
        val chapterOne = awaitValue("chapter one") { model.chapter?.takeIf { it.index == 0 } }
        onMain { model.settleAtChapterEnd() }

        val saved = awaitValue("the place to settle") {
            runBlocking { repository.position(book.id) }?.takeIf { it.chapterIndex == 0 }
        }
        assertEquals(
            "the end of the chapter crossed into, not an offset from the one left",
            chapterOne.layout.utf16Length,
            saved.utf16Offset,
        )
    }

    /**
     * "Listen from here" on a sentence that began on the page before holds the
     * page where the reader is — but the place is still the sentence being
     * read, so leaving now picks the book back up on it rather than a page on.
     */
    @Test
    fun aHeldPageStillSavesTheSentenceBeingRead() {
        val model = ReaderViewModel({ repository }, book.id)
        awaitValue("the book to open") { model.state as? ReaderViewModel.State.Ready }
        val gamma = chapterText(0).indexOf("Gamma 1")

        onMain { model.turned(gamma + 400) }
        onMain { model.holdNarrationResumeAnchor(gamma) }
        onMain { model.flush() }

        val saved = awaitValue("the place to be written") {
            runBlocking { repository.position(book.id) }?.takeIf { it.utf16Offset == gamma }
        }
        assertEquals(0, saved.chapterIndex)
        assertEquals("the page did not move", gamma + 400, model.anchor)
    }
}
