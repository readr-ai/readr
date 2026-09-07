package com.readrai.readr

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.LayoutSpan
import com.readrai.readr.ui.reader.ChapterStyling
import com.readrai.readr.ui.reader.LayoutPaginator
import com.readrai.readr.ui.reader.Page
import com.readrai.readr.ui.reader.Pagination
import com.readrai.readr.ui.reader.ReaderAppearance
import com.readrai.readr.ui.theme.Marginalia
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The paginator's contracts, measured with the real text engine on the device. */
@RunWith(AndroidJUnit4::class)
class LayoutPaginatorTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val density by lazy { Density(context) }
    private val measurer by lazy { TextMeasurer(createFontFamilyResolver(context), density, LayoutDirection.Ltr, cacheSize = 0) }
    private val appearance = ReaderAppearance()
    private val style by lazy { ChapterStyling.pageTextStyle(appearance, Marginalia.paper) }
    private val width by lazy { with(density) { 340.dp.roundToPx() } }
    private val height by lazy { with(density) { 480.dp.roundToPx() } }

    private val paragraph = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of " +
        "foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the " +
        "season of Darkness, it was the spring of hope, it was the winter of despair."

    private fun chapter(paragraphs: Int): String = (1..paragraphs).joinToString("\n") { "$it. $paragraph" }

    private fun paginate(text: String, spans: List<LayoutSpan> = emptyList()): Pair<AnnotatedString, List<Page>> {
        val styled = ChapterStyling.styled(text, spans, appearance, Marginalia.paper)
        return styled to LayoutPaginator.paginate(styled, style, width, height, measurer)
    }

    @Test
    fun pagesTileTheChapter() {
        val text = chapter(30)
        val (_, pages) = paginate(text)
        assertTrue("expected several pages, got ${pages.size}", pages.size > 3)
        assertEquals(0, pages.first().rangeStart)
        assertEquals(text.length, pages.last().rangeEnd)
        pages.zipWithNext().forEach { (a, b) -> assertEquals("ranges must tile", a.rangeEnd, b.rangeStart) }
        for (page in pages) {
            assertTrue(page.textStart >= page.rangeStart && page.textEnd <= page.rangeEnd)
            assertTrue(page.textStart < page.textEnd)
            assertFalse("a page never opens on whitespace", text[page.textStart].isWhitespace())
            assertFalse("a page never closes on whitespace", text[page.textEnd - 1].isWhitespace())
            assertTrue(page.wordCount > 0)
        }
    }

    @Test
    fun everyPageFitsWhenDrawnFromItsOwnStart() {
        val (styled, pages) = paginate(chapter(30))
        for ((index, page) in pages.withIndex()) {
            val drawn = measurer.measure(
                ChapterStyling.pageText(styled, page.textStart, page.textEnd),
                style, TextOverflow.Clip, softWrap = true, constraints = Constraints(maxWidth = width),
            )
            assertTrue("page $index is ${drawn.size.height}px tall for a ${height}px page", drawn.size.height <= height + 1)
            assertFalse("page $index overflowed when drawn", drawn.didOverflowHeight)
        }
    }

    @Test
    fun foldsBoundaryWhitespaceAndTheChapterTail() {
        val text = chapter(30) + "\n\n\n   "
        val (_, pages) = paginate(text)
        assertEquals("trailing whitespace belongs to the last page's range", text.length, pages.last().rangeEnd)
        assertTrue(pages.last().textEnd < text.length)
        pages.zipWithNext().forEach { (a, b) ->
            for (i in a.rangeEnd until b.textStart) assertTrue("only whitespace is folded at a boundary", text[i].isWhitespace())
        }
    }

    @Test
    fun anAnchorFindsItsPage() {
        val (_, pages) = paginate(chapter(30))
        val pagination = Pagination(pages)
        assertEquals(2, pagination.pageIndex(pages[2].rangeStart))
        assertEquals(2, pagination.pageIndex(pages[2].rangeStart + 5))
        assertEquals(2, pagination.pageIndex(pages[2].rangeEnd - 1))
        assertEquals(3, pagination.pageIndex(pages[2].rangeEnd))
        assertEquals(pages.size - 1, pagination.pageIndex(Int.MAX_VALUE))
        assertEquals(0, pagination.pageIndex(-1))
        assertEquals(pages.map { it.wordCount }.sum(), pagination.wordsRemaining[0])
        assertEquals(pages.last().wordCount, pagination.wordsRemaining.last())
    }

    @Test
    fun aHeadingDoesNotOpenABlankLine() {
        val text = "Heading\nBody."
        val styled = ChapterStyling.styled(text, listOf(LayoutSpan(0, 7, "heading", level = 1)), appearance, Marginalia.paper)
        assertEquals("the string keeps its length", text.length, styled.length)
        val laid = measurer.measure(styled, style, TextOverflow.Clip, softWrap = true, constraints = Constraints(maxWidth = width))
        assertEquals("heading line + body line, nothing between", 2, laid.lineCount)
    }

    @Test
    fun aPageOpeningMidParagraphIsNotIndented() {
        val (styled, pages) = paginate(chapter(30))
        val mid = pages.first { p -> p.textStart > 0 && styled.text[p.textStart - 1] != ' ' || (p.textStart > 0 && styled.paragraphStyles.none { it.start == p.textStart }) }
        val drawn = measurer.measure(ChapterStyling.pageText(styled, mid.textStart, mid.textEnd), style, TextOverflow.Clip, softWrap = true, constraints = Constraints(maxWidth = width))
        assertEquals("first line starts at the margin", 0f, drawn.getLineLeft(0), 0.5f)
    }

    @Test
    fun emptyAndBlankChaptersDoNotCrash() {
        assertTrue(paginate("").second.isEmpty())
        val (_, blank) = paginate("  \n\n  \n")
        assertEquals(1, blank.size)
        assertEquals(blank[0].textStart, blank[0].textEnd)
    }

    @Test
    fun aLongBookPaginatesInBoundedTime() {
        val text = chapter(2_000) // ~600 K characters, a Gutenberg novel as one chapter
        val started = System.nanoTime()
        val (_, pages) = paginate(text)
        val seconds = (System.nanoTime() - started) / 1e9
        assertTrue("took ${"%.1f".format(seconds)} s", seconds < 20)
        assertTrue(pages.size > 200)
        assertEquals(text.length, pages.last().rangeEnd)
    }
}
