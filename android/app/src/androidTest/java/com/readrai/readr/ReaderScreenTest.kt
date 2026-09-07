package com.readrai.readr

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
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

/** The paginated reader over a real library: open, turn, jump, restyle, and remember the place. */
@RunWith(AndroidJUnit4::class)
class ReaderScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit
    private lateinit var repository: LibraryRepository
    private lateinit var settings: ReaderSettings
    private lateinit var book: BookSummary
    private lateinit var settingsName: String

    private val paragraph = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of " +
        "foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the " +
        "season of Darkness, it was the spring of hope, it was the winter of despair, we had everything before us."

    @Before
    fun setUp() = runBlocking {
        root = File(context.cacheDir, "reader-test-${System.nanoTime()}").apply { mkdirs() }
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"))
        repository = LibraryRepository(context, kit)
        settingsName = "reader-test-${System.nanoTime()}"
        settings = ReaderSettings(context, settingsName)
        val text = buildString {
            for (chapter in 1..3) {
                append("# Chapter $chapter\n\n")
                for (p in 1..24) append("$chapter.$p $paragraph\n\n")
            }
        }
        val file = File(root, "tale.txt").apply { writeText(text) }
        book = kitJson.decodeFromString(kit.library.importPlainText(file.absolutePath, "A Tale").await())
        repository.refresh()
    }

    @After
    fun tearDown() {
        context.deleteSharedPreferences(settingsName)
        root.deleteRecursively()
    }

    private fun open(): ReaderViewModel {
        val model = ReaderViewModel({ repository }, book.id)
        compose.setContent { ReadrTheme { ReaderScreen(model, settings, onBack = {}) } }
        waitForPages()
        return model
    }

    private fun waitForPages() {
        compose.waitUntil(timeoutMillis = 20_000) { compose.onAllNodes(androidx.compose.ui.test.hasTestTag("reader.pageLabel")).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun SemanticsNodeInteraction.text(): String =
        fetchSemanticsNode().config[SemanticsProperties.Text].joinToString { it.text }

    private fun label(): String = compose.onNodeWithTag("reader.pageLabel").text()
    private fun pageCount(): Int = Regex("Page \\d+ of (\\d+)").find(label())!!.groupValues[1].toInt()
    private fun pageNumber(): Int = Regex("Page (\\d+) of").find(label())!!.groupValues[1].toInt()
    private fun kicker(): String = compose.onNodeWithTag("reader.kicker").fetchSemanticsNode().config[SemanticsProperties.ContentDescription].first()

    private fun tapPage(fraction: Float) {
        compose.onNodeWithTag("reader.page").performTouchInput { click(Offset(width * fraction, height / 2f)) }
    }

    @Test
    fun opensOnTheFirstPageAndTurnsWithTaps() {
        val model = open()
        assertEquals("Chapter 1", kicker())
        assertEquals(1, pageNumber())
        assertTrue("a chapter of 24 paragraphs spans pages", pageCount() > 2)
        assertTrue(label().contains("min left"))

        tapPage(0.9f)
        compose.waitUntil(5_000) { pageNumber() == 2 }
        assertTrue(model.anchor > 0)
        tapPage(0.1f)
        compose.waitUntil(5_000) { pageNumber() == 1 }
        assertEquals(0, model.anchor)
    }

    @Test
    fun aTurnIsRememberedAfterTheDebounce() {
        open()
        tapPage(0.9f)
        compose.waitUntil(5_000) { pageNumber() == 2 }
        compose.waitUntil(5_000) { runBlocking { repository.position(book.id)?.utf16Offset ?: 0 } > 0 }
        val saved = runBlocking { repository.position(book.id)!! }
        assertEquals(0, saved.chapterIndex)
        assertTrue(saved.utf16Offset > 0)
    }

    @Test
    fun turningPastTheEndCrossesIntoTheNextChapter() {
        open()
        val pages = pageCount()
        repeat(pages) { n ->
            tapPage(0.9f)
            compose.waitUntil(5_000) { if (n < pages - 1) pageNumber() == n + 2 else kicker() == "Chapter 2" }
        }
        assertEquals("Chapter 2", kicker())
        assertEquals(1, pageNumber())
        // And back over the same boundary lands on the previous chapter's last page.
        tapPage(0.1f)
        compose.waitUntil(5_000) { kicker() == "Chapter 1" }
        compose.waitUntil(5_000) { pageNumber() == pages }
        assertEquals(runBlocking { repository.position(book.id)!!.chapterIndex }, 0)
    }

    @Test
    fun contentsJumpsToAChapter() {
        open()
        compose.onNodeWithTag("reader.toc").performClick()
        compose.waitUntil(5_000) { compose.onAllNodes(androidx.compose.ui.test.hasTestTag("contents.row.2")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("contents.row.2").performClick()
        compose.waitUntil(10_000) { kicker() == "Chapter 3" }
        assertEquals(1, pageNumber())
        compose.waitUntil(5_000) { runBlocking { repository.position(book.id)?.chapterIndex } == 2 }
    }

    @Test
    fun restoresTheSavedPlace() {
        val middle = runBlocking { repository.chapterText(book.id, 1) }.length / 2
        runBlocking { repository.savePosition(book.id, 1, middle) }
        val model = open()
        assertEquals("Chapter 2", kicker())
        assertEquals(middle, model.anchor)
        assertTrue("the middle of the chapter opens past page 1", pageNumber() > 1)
        assertTrue("and before the last page", pageNumber() < pageCount())
    }

    @Test
    fun largerTextMakesMorePages() {
        open()
        val before = pageCount()
        compose.onNodeWithTag("reader.appearance").performClick()
        compose.waitUntil(5_000) { compose.onAllNodes(androidx.compose.ui.test.hasTestTag("appearance.textLarger")).fetchSemanticsNodes().isNotEmpty() }
        repeat(4) { compose.onNodeWithTag("appearance.textLarger").performClick() }
        assertEquals(22, settings.appearance.value.fontSize)
        // The page re-paginates live behind the sheet.
        compose.waitUntil(10_000) { pageCount() > before }
        assertEquals(1, pageNumber())
        compose.onNodeWithTag("reader.page").assertIsDisplayed()
    }
}
