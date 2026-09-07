package com.readrai.readr

import android.net.Uri
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.text.style.TextDecoration
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import com.readrai.readr.ui.reader.ChapterStyling
import com.readrai.readr.ui.reader.LayoutKey
import com.readrai.readr.ui.reader.ReaderScreen
import com.readrai.readr.ui.reader.ReaderSettings
import com.readrai.readr.ui.reader.ReaderViewModel
import com.readrai.readr.ui.theme.Marginalia
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

    private fun open(): ReaderViewModel = open(book.id)

    private fun open(id: String): ReaderViewModel {
        val model = ReaderViewModel({ repository }, id)
        compose.setContent { ReadrTheme { ReaderScreen(model, settings, onBack = {}) } }
        waitForPages()
        return model
    }

    /** The illustrated fixture, imported the way a picker would import it. */
    private fun illustrated(): BookSummary = runBlocking {
        repository.import(Uri.fromFile(IllustratedBook.write(File(root, "illustrated.epub"))))
    }

    private fun waitForPages() {
        compose.waitUntil(timeoutMillis = 20_000) { compose.onAllNodes(androidx.compose.ui.test.hasTestTag("reader.pageLabel")).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun SemanticsNodeInteraction.text(): String =
        fetchSemanticsNode().config[SemanticsProperties.Text].joinToString { it.text }

    /** The page label, or "" while a chapter is loading and the label is not in the tree. */
    private fun label(): String = compose.onAllNodes(androidx.compose.ui.test.hasTestTag("reader.pageLabel")).fetchSemanticsNodes()
        .firstOrNull()?.config?.get(SemanticsProperties.Text)?.joinToString { it.text } ?: ""
    private fun pageCount(): Int = Regex("Page \\d+ of (\\d+)").find(label())?.groupValues?.get(1)?.toInt() ?: -1
    private fun pageNumber(): Int = Regex("Page (\\d+) of").find(label())?.groupValues?.get(1)?.toInt() ?: -1
    private fun kicker(): String = compose.onNodeWithTag("reader.kicker").fetchSemanticsNode().config[SemanticsProperties.ContentDescription].first()

    private fun tapPage(fraction: Float) {
        compose.onNodeWithTag("reader.page").performTouchInput { click(Offset(width * fraction, height / 2f)) }
    }

    /** A tap high on the page, where a highlight over the chapter's opening lies. */
    private fun tapMarked(fraction: Float) {
        compose.onNodeWithTag("reader.page").performTouchInput { click(Offset(width * fraction, height * 0.1f)) }
    }

    private fun nodes(tag: String) = compose.onAllNodes(androidx.compose.ui.test.hasTestTag(tag)).fetchSemanticsNodes()
    private fun awaitTag(tag: String) = compose.waitUntil(10_000) { nodes(tag).isNotEmpty() }
    private fun awaitNoTag(tag: String) = compose.waitUntil(10_000) { nodes(tag).isEmpty() }
    private fun highlights() = runBlocking { repository.highlights(book.id) }
    private fun bookmarks() = runBlocking { repository.bookmarks(book.id) }

    /** What the system clipboard holds; read on the main thread, as the service requires. */
    private fun clipboardText(): String {
        var text = ""
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val clipboard = context.getSystemService(android.content.ClipboardManager::class.java)
            text = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString().orEmpty()
        }
        return text
    }

    /** The kicker, or "" while a chapter is loading — safe to poll from `waitUntil`. */
    private fun kickerOrEmpty(): String =
        nodes("reader.kicker").firstOrNull()?.config?.getOrElseNullable(SemanticsProperties.ContentDescription) { null }?.firstOrNull() ?: ""

    /** What the ribbon in the bar says it will do, or "" when it is not there. */
    private fun bookmarkLabel(): String =
        nodes("reader.bookmarks").firstOrNull()?.config?.getOrElseNullable(SemanticsProperties.ContentDescription) { null }?.firstOrNull() ?: ""

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
            compose.waitUntil(10_000) { if (n < pages - 1) pageNumber() == n + 2 else kicker() == "Chapter 2" && pageNumber() == 1 }
        }
        assertEquals("Chapter 2", kicker())
        // And back over the same boundary lands on the previous chapter's last page, and that is what is saved.
        tapPage(0.1f)
        compose.waitUntil(10_000) { kicker() == "Chapter 1" && pageNumber() == pages }
        compose.waitUntil(5_000) { runBlocking { repository.position(book.id) }?.let { it.chapterIndex == 0 && it.utf16Offset > 0 } == true }
        val saved = runBlocking { repository.position(book.id)!! }
        val chapterLength = runBlocking { repository.chapterText(book.id, 0) }.length
        assertTrue("the saved place is inside the chapter, not past its end", saved.utf16Offset < chapterLength)
    }

    @Test
    fun contentsJumpsToAChapter() {
        open()
        compose.onNodeWithTag("reader.toc").performClick()
        compose.waitUntil(5_000) { compose.onAllNodes(androidx.compose.ui.test.hasTestTag("contents.row.2")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("contents.row.2").performClick()
        compose.waitUntil(10_000) { kicker() == "Chapter 3" && pageNumber() == 1 }
        compose.waitUntil(5_000) { runBlocking { repository.position(book.id)?.chapterIndex } == 2 }
    }

    @Test
    fun openingAndLeavingWritesNothing() {
        val before = runBlocking { repository.position(book.id) }
        val model = open()
        model.flush()
        Thread.sleep(500)
        assertEquals(before, runBlocking { repository.position(book.id) })
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
    fun aLongPressHighlightsAWordAndTappingItAgainRemovesIt() {
        open()
        compose.onNodeWithTag("reader.page").performTouchInput { longClick(center) }
        awaitTag("annotation.capsule")

        compose.onNodeWithTag("annotation.color.green").performClick()
        compose.waitUntil(10_000) { highlights().isNotEmpty() }
        val created = highlights().single()
        val chapterText = runBlocking { repository.chapterText(book.id, created.chapterIndex) }
        assertEquals(chapterText.substring(created.utf16Start, created.utf16End), created.quotedText)
        assertTrue("a whole word, not a blank: '${created.quotedText}'", created.quotedText.isNotBlank())
        assertTrue("a whole word, not a run: '${created.quotedText}'", created.quotedText.none { it.isWhitespace() })
        assertEquals("green", created.color)
        // The selection goes with the capsule, and the colour is remembered for next time.
        awaitNoTag("annotation.capsule")
        assertEquals(HighlightColor.GREEN, settings.lastHighlightColor.value)

        // Tapping the highlighted word opens the capsule on it; ✕ takes the highlight away.
        compose.onNodeWithTag("reader.page").performTouchInput { click(center) }
        awaitTag("annotation.remove")
        compose.onNodeWithTag("annotation.remove").performClick()
        compose.waitUntil(10_000) { highlights().isEmpty() }
        awaitNoTag("annotation.capsule")
    }

    /**
     * The outer quarters are the page-turn zones, and a mark under the finger
     * does not take them over — only the middle half of the surface opens a
     * capsule on a tap. Long-press selection stays available everywhere.
     */
    @Test
    fun aTapInTheTurnZoneTurnsThePageEvenOverAHighlight() {
        // A highlight over the chapter's opening, wide enough to be under the
        // finger on the first pages whatever the geometry.
        val marked = runBlocking { repository.addHighlight(book.id, 0, 0, 3_000, HighlightColor.YELLOW) }
        open()
        assertEquals(1, pageNumber())

        // Near the top so the finger is over the marked lines, and in the outer
        // tenth so it is in a turn zone — forward, then back again.
        tapMarked(0.9f)
        compose.waitUntil(10_000) { pageNumber() == 2 }
        assertTrue("no capsule opened on the way", nodes("annotation.capsule").isEmpty())

        tapMarked(0.1f)
        compose.waitUntil(10_000) { pageNumber() == 1 }
        assertTrue("nor on the way back", nodes("annotation.capsule").isEmpty())
        assertEquals(listOf(marked.id), highlights().map { it.id })
    }

    /**
     * What the capsule copies is the kit's own chapter text, sliced at the
     * chapter offsets — not the page's styled string, which draws every
     * paragraph break as a space.
     */
    @Test
    fun theCapsuleCopiesTheChapterTextItself() {
        open()
        compose.onNodeWithTag("reader.page").performTouchInput { longClick(center) }
        awaitTag("annotation.capsule")
        compose.onNodeWithTag("annotation.copy").performClick()
        awaitNoTag("annotation.capsule")
        val copied = clipboardText()
        assertTrue("something was copied", copied.isNotBlank())

        // The same word again, this time as a highlight, so the kit reports the
        // offsets the capsule was working in.
        compose.onNodeWithTag("reader.page").performTouchInput { longClick(center) }
        awaitTag("annotation.capsule")
        compose.onNodeWithTag("annotation.color.green").performClick()
        compose.waitUntil(10_000) { highlights().isNotEmpty() }
        val created = highlights().single()
        val chapterText = runBlocking { repository.chapterText(book.id, created.chapterIndex) }
        assertEquals(chapterText.substring(created.utf16Start, created.utf16End), copied)
        assertEquals(created.quotedText, copied)
    }

    @Test
    fun aNoteIsWrittenOnTheHighlightTheNoteFlowMakes() {
        open()
        compose.onNodeWithTag("reader.page").performTouchInput { longClick(center) }
        awaitTag("annotation.capsule")
        compose.onNodeWithTag("annotation.note").performClick()

        // "Note" highlights the passage first — a note has to live on a highlight.
        awaitTag("note.editor")
        compose.waitUntil(10_000) { highlights().size == 1 }
        compose.onNodeWithTag("note.field").performTextInput("Marginal thought")
        compose.onNodeWithTag("note.save").performClick()

        compose.waitUntil(10_000) { highlights().singleOrNull()?.note == "Marginal thought" }
        awaitNoTag("note.editor")
        val noted = highlights().single()
        assertEquals(HighlightColor.YELLOW, noted.markerColor)

        // And a highlight that carries a note is drawn underlined.
        val text = runBlocking { repository.chapterText(book.id, noted.chapterIndex) }
        val layout = runBlocking { repository.chapterLayout(book.id, noted.chapterIndex) }
        val styled = ChapterStyling.styled(text, layout.spans, LayoutKey(settings.appearance.value))
        val page = ChapterStyling.pageText(styled, 0, text.length, Marginalia.paper, listOf(noted))
        assertTrue(
            "the noted passage is underlined on the page",
            page.spanStyles.any { it.item.textDecoration == TextDecoration.Underline && it.start == noted.utf16Start },
        )
    }

    @Test
    fun cancellingANewNoteTakesItsHighlightWithIt() {
        open()
        compose.onNodeWithTag("reader.page").performTouchInput { longClick(center) }
        awaitTag("annotation.capsule")
        compose.onNodeWithTag("annotation.note").performClick()
        awaitTag("note.editor")
        compose.waitUntil(10_000) { highlights().size == 1 }

        compose.onNodeWithTag("note.cancel").performClick()
        compose.waitUntil(10_000) { highlights().isEmpty() }
        awaitNoTag("note.editor")
    }

    @Test
    fun theRibbonBookmarksThePageAndTakesItBack() {
        open()
        assertEquals("Bookmark this page", bookmarkLabel())
        compose.onNodeWithTag("reader.bookmarks").performClick()

        compose.waitUntil(10_000) { bookmarks().isNotEmpty() }
        val saved = bookmarks().single()
        assertEquals(0, saved.chapterIndex)
        assertTrue("the bookmark quotes the page it was made on", saved.snippet.isNotBlank())
        compose.waitUntil(5_000) { bookmarkLabel() == "Remove bookmark" }

        compose.onNodeWithTag("reader.bookmarks").performClick()
        compose.waitUntil(10_000) { bookmarks().isEmpty() }
        compose.waitUntil(5_000) { bookmarkLabel() == "Bookmark this page" }
    }

    @Test
    fun contentsListsABookmarkJumpsToItAndRemovesIt() {
        val bookmark = runBlocking { repository.addBookmark(book.id, 2, 0) }
        open()
        compose.onNodeWithTag("reader.toc").performClick()
        awaitTag("contents.bookmark.${bookmark.id}")

        compose.onNodeWithTag("contents.bookmark.${bookmark.id}").performClick()
        compose.waitUntil(10_000) { kickerOrEmpty() == "Chapter 3" }
        awaitNoTag("contents.list")

        compose.onNodeWithTag("reader.toc").performClick()
        awaitTag("contents.removeBookmark.${bookmark.id}")
        compose.onNodeWithTag("contents.removeBookmark.${bookmark.id}").performClick()
        compose.waitUntil(10_000) { bookmarks().isEmpty() }
        awaitNoTag("contents.bookmark.${bookmark.id}")
    }

    @Test
    fun theHighlightsSheetListsAHighlightAndJumpsToIt() {
        val marked = runBlocking { repository.addHighlight(book.id, 2, 40, 60, HighlightColor.BLUE) }
        open()
        assertEquals("Chapter 1", kicker())

        compose.onNodeWithTag("reader.notes").performClick()
        awaitTag("notes.card.${marked.id}")
        compose.onNodeWithTag("notes.card.${marked.id}").performClick()
        compose.waitUntil(10_000) { kickerOrEmpty() == "Chapter 3" }
        compose.waitUntil(5_000) { runBlocking { repository.position(book.id)?.chapterIndex } == 2 }
    }

    /**
     * Find in book: a phrase that occurs in one chapter only, and the row for
     * it takes the reader to exactly the place the kit reported.
     */
    @Test
    fun searchJumpsToTheMatchItFound() {
        val model = open()
        assertEquals("Chapter 1", kicker())

        compose.onNodeWithTag("reader.search").performClick()
        awaitTag("reader.search.field")
        // "3.17" numbers a paragraph of the third chapter and appears nowhere else.
        compose.onNodeWithTag("reader.search.field").performTextInput("3.17")
        awaitTag("reader.search.result.0")

        val hit = model.searchResults.first()
        assertEquals("the only chapter that says it", 1, model.searchResults.size)
        assertEquals(2, hit.chapterIndex)
        val chapterText = runBlocking { repository.chapterText(book.id, 2) }
        assertEquals("3.17", chapterText.substring(hit.utf16Offset, hit.utf16Offset + 4))

        compose.onNodeWithTag("reader.search.result.0").performClick()
        compose.waitUntil(10_000) { kickerOrEmpty() == "Chapter 3" }
        awaitNoTag("reader.search.field")
        assertEquals("the reader is at the match", hit.utf16Offset, model.anchor)
        // And the search is still there when the sheet comes back.
        compose.onNodeWithTag("reader.search").performClick()
        awaitTag("reader.search.result.0")
        assertEquals("3.17", model.searchQuery)
    }

    /**
     * A chapter with a picture in it pages like any other: the label keeps
     * counting from the first page to the last, the page holding the figure is
     * one of them, and nothing throws on the way.
     */
    @Test
    fun aChapterWithAnIllustrationPagesThrough() {
        val illustrated = illustrated()
        val images = runBlocking { repository.chapterImages(illustrated.id, 0) }
        assertTrue("the fixture has a figure in its first chapter", images.isNotEmpty())
        val model = open(illustrated.id)

        assertEquals(1, pageNumber())
        assertTrue("the running head names the chapter", kicker().isNotBlank())
        val pages = pageCount()
        assertTrue("a chapter with a plate still spans pages", pages > 1)
        // Swiped, not tapped: this chapter carries links, and a link under the
        // finger is followed rather than turned past, in any zone (which is the
        // point of `anExternalLinkAsksBeforeItLeavesTheBook`).
        for (n in 1 until pages) {
            compose.onNodeWithTag("reader.page").performTouchInput { swipeLeft() }
            compose.waitUntil(10_000) { pageNumber() == n + 1 }
        }
        assertEquals(pages, pageNumber())
        compose.onNodeWithTag("reader.page").assertIsDisplayed()

        // And the picture sat on exactly one of those pages.
        val offset = images.first().utf16Offset
        compose.runOnIdle { model.jump(0, offset) }
        compose.waitUntil(10_000) { model.visible?.page?.let { offset in it } == true }
        compose.onNodeWithTag("reader.page").assertIsDisplayed()
        assertTrue("no error surfaced", nodes("reader.error").isEmpty())
    }

    /**
     * A link out of the book asks first, and names the host it would open —
     * and asks wherever the finger lands, including the page-turn zones: a
     * link is a control the author put on the page.
     */
    @Test
    fun anExternalLinkAsksBeforeItLeavesTheBook() {
        val illustrated = illustrated()
        val model = open(illustrated.id)
        compose.runOnIdle { model.jump(IllustratedBook.EXTERNAL_LINK_CHAPTER, 0) }
        waitForPages()
        val page = pageNumber()

        // The chapter is nothing but the link, so the turn zone holds it too.
        tapPage(0.9f)
        awaitTag("link.dialog")
        assertEquals("example.org", compose.onNodeWithTag("link.host").text())
        assertEquals("the page did not turn under the question", page, pageNumber())

        compose.onNodeWithTag("link.cancel").performClick()
        awaitNoTag("link.dialog")
    }

    /** A noteref whose fragment names a note of this chapter opens it in place. */
    @Test
    fun aNoterefOpensTheNoteInPlace() {
        val illustrated = illustrated()
        val notes = runBlocking { repository.chapterFootnotes(illustrated.id, IllustratedBook.NOTE_CHAPTER) }
        assertEquals(listOf(IllustratedBook.NOTE_ID), notes.map { it.id })
        val model = open(illustrated.id)
        compose.runOnIdle { model.jump(IllustratedBook.NOTE_CHAPTER, 0) }
        waitForPages()
        val chapter = model.chapterIndex

        tapPage(0.5f)
        awaitTag("footnote.sheet")
        assertTrue(
            "the note says what it says",
            compose.onNodeWithTag("footnote.text").text().contains(IllustratedBook.NOTE_TEXT),
        )
        assertEquals("a note is read in place, not somewhere else", chapter, model.chapterIndex)
    }

    /** A link into the book takes the reader to the place its fragment names. */
    @Test
    fun anInternalLinkJumpsToItsAnchor() {
        val illustrated = illustrated()
        val titles = runBlocking { repository.chapters(illustrated.id) }.map { it.title }
        val anchored = IllustratedBook.ANCHOR_CHAPTER
        val target = runBlocking { repository.chapterLayout(illustrated.id, anchored) }.anchors[IllustratedBook.ANCHOR]!!
        assertTrue("the anchor is past the chapter's opening", target > 0)

        val model = open(illustrated.id)
        compose.runOnIdle { model.jump(IllustratedBook.INTERNAL_LINK_CHAPTER, 0) }
        waitForPages()
        compose.waitUntil(10_000) { kickerOrEmpty() == titles[IllustratedBook.INTERNAL_LINK_CHAPTER] }

        tapPage(0.5f)
        compose.waitUntil(10_000) { kickerOrEmpty() == titles[anchored] }
        compose.waitUntil(5_000) { model.anchor == target }
        compose.waitUntil(5_000) { runBlocking { repository.position(illustrated.id)?.chapterIndex } == anchored }
    }

    /** A link to a document this book does not have says so, and stays put. */
    @Test
    fun anInternalLinkThatLeadsNowhereSaysSoInPlainLanguage() {
        val illustrated = illustrated()
        val titles = runBlocking { repository.chapters(illustrated.id) }.map { it.title }
        val model = open(illustrated.id)
        compose.runOnIdle { model.followInternalLink("OEBPS/nowhere.xhtml", null) }
        awaitTag("reader.message")
        assertEquals("That link doesn't lead anywhere in this book.", model.message)
        assertEquals("and the reader has not moved", titles[0], kicker())
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
