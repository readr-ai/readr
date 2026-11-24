package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.ui.reader.visibleHighlights
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** What the Highlights sheet shows: the chips it is filtering by, and the search over quote and note. */
@RunWith(AndroidJUnit4::class)
class HighlightsFilterTest {
    private fun highlight(id: String, color: String, quote: String, note: String? = null) = Highlight(
        id = id,
        chapterIndex = 0,
        utf16Start = 0,
        utf16End = quote.length,
        quotedText = quote,
        note = note,
        color = color,
        createdAt = "2026-09-07T00:00:00Z",
    )

    private val all = HighlightColor.entries.toSet()

    private val yellow = highlight("y", "yellow", "the season of Light")
    private val green = highlight("g", "green", "the spring of hope", note = "Worth Quoting")
    private val strange = highlight("s", "chartreuse", "a colour from a newer build")

    private val library = listOf(yellow, green, strange)

    @Test
    fun everyColourOnShowsEverything() {
        assertEquals(library, visibleHighlights(library, all, ""))
        assertEquals(library, visibleHighlights(library, all, "   "))
    }

    /**
     * A colour this build has never heard of is drawn yellow, so it must be
     * filed under Yellow too — filtering on the raw string would have hidden it
     * from every chip at once.
     */
    @Test
    fun anUnknownColourShowsUnderYellow() {
        assertEquals(HighlightColor.YELLOW, strange.markerColor)
        assertEquals(listOf(yellow, strange), visibleHighlights(library, setOf(HighlightColor.YELLOW), ""))
        assertTrue(visibleHighlights(library, setOf(HighlightColor.GREEN), "").none { it.id == "s" })
    }

    @Test
    fun aColourSwitchedOffTakesItsHighlightsWithIt() {
        assertEquals(listOf(green), visibleHighlights(library, setOf(HighlightColor.GREEN), ""))
        assertTrue(visibleHighlights(library, emptySet(), "").isEmpty())
    }

    @Test
    fun theSearchReadsTheNoteAsWellAsTheQuote() {
        assertEquals(listOf(green), visibleHighlights(library, all, "worth quoting"))
        assertEquals(listOf(green), visibleHighlights(library, all, "  QUOTING  "))
        assertEquals(listOf(yellow), visibleHighlights(library, all, "light"))
        assertTrue(visibleHighlights(library, all, "nothing here").isEmpty())
    }

    @Test
    fun colourAndSearchNarrowTogether() {
        assertTrue(visibleHighlights(library, setOf(HighlightColor.YELLOW), "worth quoting").isEmpty())
        assertEquals(listOf(green), visibleHighlights(library, setOf(HighlightColor.GREEN), "hope"))
    }
}
