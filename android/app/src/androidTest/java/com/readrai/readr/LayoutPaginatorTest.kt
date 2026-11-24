package com.readrai.readr

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.ChapterImages
import com.readrai.readr.data.InlineImage
import com.readrai.readr.data.LayoutSpan
import com.readrai.readr.ui.reader.ChapterStyling
import com.readrai.readr.ui.reader.LayoutKey
import com.readrai.readr.ui.reader.LayoutPaginator
import com.readrai.readr.ui.reader.Page
import com.readrai.readr.ui.reader.Pagination
import com.readrai.readr.ui.reader.ReaderAppearance
import com.readrai.readr.ui.reader.StyledChapter
import com.readrai.readr.ui.theme.Marginalia
import java.io.File
import kotlinx.coroutines.test.runTest
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
    private val layout = LayoutKey(ReaderAppearance())
    private val palette = Marginalia.paper
    private val style by lazy { ChapterStyling.pageTextStyle(layout, palette) }
    private val width by lazy { with(density) { 340.dp.roundToPx() } }
    private val height by lazy { with(density) { 480.dp.roundToPx() } }

    private val paragraph = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of " +
        "foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the " +
        "season of Darkness, it was the spring of hope, it was the winter of despair."

    private fun chapter(paragraphs: Int): String = (1..paragraphs).joinToString("\n") { "$it. $paragraph" }

    private fun paginate(text: String, spans: List<LayoutSpan> = emptyList()): Pair<StyledChapter, List<Page>> {
        val styled = ChapterStyling.styled(text, spans, layout)
        return styled to LayoutPaginator.paginate(styled, style, width, height, measurer)
    }

    /**
     * A page as it is actually drawn — the same styled slice, at the same
     * width, with the same inline images in it. Measuring it without the
     * placeholders would be measuring a different page.
     */
    private fun drawn(styled: StyledChapter, page: Page) = measurer.measure(
        ChapterStyling.pageText(styled, page.textStart, page.textEnd, palette),
        style, TextOverflow.Clip, softWrap = true,
        placeholders = styled.placeholdersIn(page.textStart, page.textEnd),
        constraints = Constraints(maxWidth = width),
    )

    private fun assertEveryPageFits(styled: StyledChapter, pages: List<Page>, atWidth: Int = width, atHeight: Int = height) {
        for ((index, page) in pages.withIndex()) {
            val result = measurer.measure(
                ChapterStyling.pageText(styled, page.textStart, page.textEnd, palette),
                style, TextOverflow.Clip, softWrap = true,
                placeholders = styled.placeholdersIn(page.textStart, page.textEnd),
                constraints = Constraints(maxWidth = atWidth),
            )
            assertTrue("page $index is ${result.size.height}px tall for a ${atHeight}px page", result.size.height <= atHeight + 1)
            assertFalse("page $index overflowed when drawn", result.didOverflowHeight)
        }
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
        assertEveryPageFits(styled, pages)
    }

    @Test
    fun pagesAcrossMeasurementSeamsStillFit() {
        // Long enough for several 24K-character chunks, with paragraphs that straddle the cuts.
        val text = chapter(260)
        assertTrue(text.length > 3 * LayoutPaginator.CHUNK)
        val (styled, pages) = paginate(text)
        assertEveryPageFits(styled, pages)
        assertEquals(text.length, pages.last().rangeEnd)
        // Every drawn page, rendered in order, reproduces the chapter's words exactly once.
        val words = pages.joinToString(" ") { styled.text.text.substring(it.textStart, it.textEnd) }.split(Regex("\\s+"))
        assertEquals(text.split(Regex("\\s+")), words)
    }

    @Test
    fun aPageOpeningInsideABlockquoteKeepsItsInset() {
        val quote = (1..40).joinToString(" ") { paragraph }
        val text = "Lead-in.\n$quote\nAfter."
        val styled = ChapterStyling.styled(text, listOf(LayoutSpan(9, 9 + quote.length, "blockquote")), layout)
        val pages = LayoutPaginator.paginate(styled, style, width, height, measurer)
        val inside = pages.first { it.textStart > 9 && it.textStart < 9 + quote.length }
        val result = drawn(styled, inside)
        val firstGlyph = result.getHorizontalPosition(0, usePrimaryDirection = true)
        val secondLineGlyph = result.getHorizontalPosition(result.getLineStart(1), usePrimaryDirection = true)
        assertTrue("first line keeps the quote inset ($firstGlyph)", firstGlyph > 0f)
        assertEquals("first and second lines share the inset", secondLineGlyph, firstGlyph, 0.5f)
        assertEveryPageFits(styled, pages)
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
        val styled = ChapterStyling.styled(text, listOf(LayoutSpan(0, 7, "heading", level = 1)), layout)
        assertEquals("the string keeps its length", text.length, styled.text.length)
        val laid = measurer.measure(styled.text, style, TextOverflow.Clip, softWrap = true, constraints = Constraints(maxWidth = width))
        assertEquals("heading line + body line, nothing between", 2, laid.lineCount)
    }

    @Test
    fun aPageOpeningMidParagraphIsNotIndented() {
        val (styled, pages) = paginate(chapter(30))
        val mid = pages.first { it.textStart > 0 && !styled.startsParagraph(it.textStart) }
        val result = drawn(styled, mid)
        assertEquals("first line starts at the margin", 0f, result.getHorizontalPosition(0, usePrimaryDirection = true), 0.5f)
        // Whereas a page that opens on a paragraph keeps the book indent.
        val fresh = pages.first { it.textStart == 0 || styled.startsParagraph(it.textStart) }
        assertTrue("a paragraph start is indented", drawn(styled, fresh).getHorizontalPosition(0, usePrimaryDirection = true) > 0f)
    }

    /**
     * A chapter with a picture in it. The placeholder is a whole number of
     * lines tall, so a paginator that ignored it would happily fill a page to
     * the brim and then overflow it by exactly that much when the page was
     * drawn — which is the failure this guards.
     */
    @Test
    fun aChapterWithAnInlineImageStillTilesAndStillFits() {
        val lineHeightPx = with(density) { (layout.fontSize * layout.lineHeightMultiplier).sp.toPx() }
        val imageHeightPx = lineHeightPx * 5
        val head = chapter(6)
        val text = "$head\n￼\n${chapter(6)}"
        val offset = head.length + 1
        assertEquals('￼', text[offset])
        val image = with(density) {
            InlineImage(
                id = "image-$offset",
                utf16Offset = offset,
                archivePath = "images/figure.png",
                placeholder = Placeholder(width.toFloat().toSp(), imageHeightPx.toSp(), PlaceholderVerticalAlign.Center),
                lineHeight = (imageHeightPx + 4.dp.toPx()).toSp(),
                hasPicture = true,
                alt = "A figure",
            )
        }
        val styled = ChapterStyling.styled(text, emptyList(), layout, listOf(image))
        val pages = LayoutPaginator.paginate(styled, style, width, height, measurer)

        assertTrue("several pages", pages.size > 2)
        assertEquals(0, pages.first().rangeStart)
        assertEquals(text.length, pages.last().rangeEnd)
        pages.zipWithNext().forEach { (a, b) -> assertEquals("ranges must tile", a.rangeEnd, b.rangeStart) }
        assertEveryPageFits(styled, pages)

        // The picture belongs to exactly one page, and its line belongs to that
        // page whole: the placeholder is never cut away from the line it is on.
        val holding = pages.filter { offset >= it.textStart && offset < it.textEnd }
        assertEquals("one page holds the picture", 1, holding.size)
        val page = holding.single()
        val result = drawn(styled, page)
        val line = result.getLineForOffset(offset - page.textStart)
        assertTrue("its line starts on the page", result.getLineStart(line) >= 0)
        assertTrue("and ends on it", result.getLineEnd(line, visibleEnd = false) <= page.textEnd - page.textStart)
        assertTrue("the picture's line is as tall as the picture",
            result.getLineBottom(line) - result.getLineTop(line) >= imageHeightPx - 1f)
        assertEquals("one placeholder on that page", 1, styled.placeholdersIn(page.textStart, page.textEnd).size)
    }

    /**
     * The placeholders are part of the shape, not decoration: a narrower
     * column is a smaller picture, a different set of line breaks and a
     * different number of pages. This is why the images are placed inside the
     * same computation the pagination is cached under — a set built for one
     * column and drawn in another would overflow by exactly the difference.
     */
    @Test
    fun aPictureScalesWithTheColumnAndEveryPageStillFits() = runTest {
        val root = File(context.cacheDir, "paginator-images-${System.nanoTime()}").apply { mkdirs() }
        try {
            val archive = IllustratedBook.write(File(root, "illustrated.epub"))
            ChapterImages.clearCache()
            val head = chapter(6)
            val text = "$head\n￼\n${chapter(6)}"
            val offset = head.length + 1
            val narrow = width / 2

            suspend fun laidOut(columnWidth: Int): Pair<StyledChapter, List<Page>> {
                val images = ChapterImages.place(
                    archive = archive,
                    bookId = "paginator-test",
                    images = listOf(
                        com.readrai.readr.data.ChapterImage(
                            utf16Offset = offset,
                            archivePath = IllustratedBook.IMAGE_PATH,
                            alt = IllustratedBook.ALT,
                        ),
                    ),
                    density = density,
                    textWidthPx = columnWidth,
                    pageHeightPx = height,
                    fallbackLineHeightPx = with(density) { (layout.fontSize * layout.lineHeightMultiplier).sp.toPx() },
                )
                val styled = ChapterStyling.styled(text, emptyList(), layout, images)
                return styled to LayoutPaginator.paginate(styled, style, columnWidth, height, measurer)
            }

            val (wideStyled, widePages) = laidOut(width)
            val (narrowStyled, narrowPages) = laidOut(narrow)

            val widePlaceholder = with(density) { wideStyled.placeholders.single().item.height.toPx() }
            val narrowPlaceholder = with(density) { narrowStyled.placeholders.single().item.height.toPx() }
            assertTrue(
                "a narrower column is a shorter picture ($narrowPlaceholder of $widePlaceholder)",
                narrowPlaceholder < widePlaceholder,
            )
            assertTrue("and the narrower chapter runs to more pages", narrowPages.size > widePages.size)
            assertEveryPageFits(wideStyled, widePages)
            assertEveryPageFits(narrowStyled, narrowPages, atWidth = narrow)
        } finally {
            ChapterImages.clearCache()
            root.deleteRecursively()
        }
    }

    /**
     * The scroll layout's pieces: they tile the chapter, they cut where a
     * paragraph starts, and none of them is measured to make them — which is
     * the point of a scroll, where there is no page height to fill.
     */
    @Test
    fun chunksTileTheChapterAndCutAtParagraphs() {
        val text = chapter(260)
        val styled = ChapterStyling.styled(text, emptyList(), layout)
        val chunks = LayoutPaginator.chunks(styled)
        assertTrue("a long chapter is several chunks, got ${chunks.size}", chunks.size > 2)
        assertEquals(0, chunks.first().textStart)
        assertEquals(text.length, chunks.last().textEnd)
        chunks.zipWithNext().forEach { (a, b) ->
            assertEquals("chunks must tile", a.textEnd, b.textStart)
            assertTrue("and cut where a paragraph begins", styled.startsParagraph(b.textStart))
        }
        assertEquals("every word is in exactly one chunk", LayoutPaginator.wordCount(text, 0, text.length), chunks.sumOf { it.wordCount })
        assertTrue("no chunk outgrows the measurement bound", chunks.all { it.textEnd - it.textStart <= LayoutPaginator.CHUNK })
        assertTrue(LayoutPaginator.chunks(ChapterStyling.styled("", emptyList(), layout)).isEmpty())
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
        assertTrue("took ${"%.1f".format(seconds)} s", seconds < 60) // generous: CI emulators render in software
        assertTrue(pages.size > 200)
        assertEquals(text.length, pages.last().rangeEnd)
    }
}
