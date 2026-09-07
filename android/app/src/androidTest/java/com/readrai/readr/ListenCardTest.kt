package com.readrai.readr

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.text.TextLayoutResult
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
    private fun open(): ReaderViewModel {
        val model = ReaderViewModel({ repository }, book.id)
        narration = NarrationModel(
            context, { kit }, book.id, settings,
            backends = { events -> FakeSpeechBackend(events).also { backend = it } },
        )
        ask = AskViewModel({ AskRepository(kit) }, AskConversation(book.id))
        compose.setContent {
            ReadrTheme {
                ReaderScreen(model, settings, ask = ask, narration = narration, onBack = {})
            }
        }
        awaitTag("reader.pageLabel")
        return model
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
        val (point, word) = wordPoint()
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
     * A point over the middle of a word on the drawn page, and the word it
     * lands in — taken from the page's own text layout, because a fraction of
     * the page box is a guess about pagination (see `ReaderScreenTest`).
     */
    private fun wordPoint(): Pair<Offset, String> {
        val node = compose.onNodeWithTag("reader.page").fetchSemanticsNode()
        val layouts = mutableListOf<TextLayoutResult>()
        node.config[SemanticsActions.GetTextLayoutResult].action?.invoke(layouts)
        val layout = layouts.firstOrNull() ?: error("the page has no text layout to aim at")
        val text = layout.layoutInput.text.text
        fun insideAWord(index: Int) = text[index].isLetter() &&
            index > 0 && text[index - 1].isLetter() &&
            index + 1 < text.length && text[index + 1].isLetter()
        val width = node.size.width
        val aimed = (text.indices.drop(text.length / 2) + text.indices).firstOrNull { index ->
            insideAWord(index) && layout.getBoundingBox(index).center.x in width * 0.35f..width * 0.65f
        } ?: error("no word in the middle of the page to aim at")
        var start = aimed
        while (start > 0 && text[start - 1].isLetter()) start -= 1
        var end = aimed
        while (end + 1 < text.length && text[end + 1].isLetter()) end += 1
        val box = layout.getBoundingBox(aimed)
        return Offset(box.left + box.width * 0.4f, box.center.y) to text.substring(start, end + 1)
    }
}
