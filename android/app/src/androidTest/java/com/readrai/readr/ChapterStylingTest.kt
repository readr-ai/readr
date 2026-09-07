package com.readrai.readr

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.ui.reader.ChapterStyling
import com.readrai.readr.ui.reader.LayoutKey
import com.readrai.readr.ui.reader.ReaderAppearance
import com.readrai.readr.ui.theme.Marginalia
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Highlights on a page: a background field over the right glyphs, and never a character more or less. */
@RunWith(AndroidJUnit4::class)
class ChapterStylingTest {
    private val palette = Marginalia.paper
    private val text = "First paragraph with several plain words in it.\nSecond paragraph, also plain, for the page after.\n"
    private val firstEnd = text.indexOf('\n')
    private val secondStart = firstEnd + 1
    private val secondEnd = text.length - 1
    private val styled = ChapterStyling.styled(text, emptyList(), LayoutKey(ReaderAppearance()))

    private fun highlight(start: Int, end: Int, color: HighlightColor = HighlightColor.GREEN, note: String? = null) = Highlight(
        id = "h-$start-$end",
        chapterIndex = 0,
        utf16Start = start,
        utf16End = end,
        quotedText = text.substring(start, end),
        note = note,
        color = color.key,
        createdAt = "2026-09-07T00:00:00Z",
    )

    /** The highlight fields, which are the only backgrounds a plain page carries. */
    private fun fields(page: AnnotatedString): List<AnnotatedString.Range<SpanStyle>> =
        page.spanStyles.filter { it.item.background != Color.Unspecified }

    @Test
    fun aHighlightOnThePageIsABackgroundFieldOverItsWords() {
        val page = ChapterStyling.pageText(styled, 0, firstEnd, palette, listOf(highlight(6, 15)))
        val field = fields(page).single()
        assertEquals(6, field.start)
        assertEquals(15, field.end)
        assertEquals(palette.marker(HighlightColor.GREEN), field.item.background)
        assertNull(field.item.textDecoration)
        assertEquals(text.substring(0, firstEnd), page.text)
    }

    @Test
    fun aHighlightThatStraddlesThePageStartIsClipped() {
        val page = ChapterStyling.pageText(styled, secondStart, secondEnd, palette, listOf(highlight(firstEnd - 10, secondStart + 6)))
        val field = fields(page).single()
        assertEquals(0, field.start)
        assertEquals(6, field.end)
        assertEquals(secondEnd - secondStart, page.length)
    }

    @Test
    fun aHighlightOnAnotherPageAddsNothing() {
        val page = ChapterStyling.pageText(styled, 0, firstEnd, palette, listOf(highlight(secondStart, secondStart + 6)))
        assertTrue(fields(page).isEmpty())
        assertEquals(text.substring(0, firstEnd), page.text)
    }

    @Test
    fun aNotedHighlightIsUnderlinedAsWell() {
        val page = ChapterStyling.pageText(styled, 0, firstEnd, palette, listOf(highlight(6, 15, note = "why this matters")))
        val field = fields(page).single()
        assertEquals(TextDecoration.Underline, field.item.textDecoration)
        assertEquals(palette.marker(HighlightColor.GREEN), field.item.background)
    }

    @Test
    fun aPageWithoutHighlightsIsThePlainPage() {
        val page = ChapterStyling.pageText(styled, 0, firstEnd, palette)
        assertTrue(fields(page).isEmpty())
        assertEquals(firstEnd, page.length)
    }

    /**
     * Why a quote is sliced from the chapter and never from the page: the two
     * strings agree character for character except at the newlines, which the
     * page draws as spaces. Copying from the page would quietly flatten a
     * paragraph break into a space.
     */
    @Test
    fun theStyledPageDiffersFromTheChapterOnlyAtItsNewlines() {
        val drawn = styled.text.text
        assertEquals("every offset still means what it means to the kit", text.length, drawn.length)
        for (i in text.indices) {
            if (text[i] == '\n') assertEquals("newline at $i", ' ', drawn[i])
            else assertEquals("character at $i", text[i], drawn[i])
        }
        assertTrue("the fixture has a paragraph break to lose", text.contains('\n'))
    }

    @Test
    fun everyThemeHasAFieldForEveryColour() {
        for (theme in listOf(Marginalia.paper, Marginalia.sepia, Marginalia.night)) {
            for (color in HighlightColor.entries) {
                assertTrue("$color has a field", theme.marker(color) != Color.Unspecified)
            }
        }
        assertEquals(Color(0xFFEAD8A2), Marginalia.paper.marker(HighlightColor.YELLOW))
        assertEquals(Color(0xFFCFC2DC), Marginalia.sepia.marker(HighlightColor.PURPLE))
        // Night washes the hue over the dark page: the same colour, at a third.
        assertEquals(Color(0xFFE2BC68).copy(alpha = 0.32f), Marginalia.night.marker(HighlightColor.YELLOW))
    }
}
