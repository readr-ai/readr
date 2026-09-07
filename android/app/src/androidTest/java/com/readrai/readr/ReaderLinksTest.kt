package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.ui.reader.LinkDestination
import com.readrai.readr.ui.reader.linkHost
import com.readrai.readr.ui.reader.resolveInternalLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/** Where a link into the book lands: the document, then the place in it. */
@RunWith(AndroidJUnit4::class)
class ReaderLinksTest {
    private val chapters = listOf(
        ChapterSummary(0, "Cover", 40, sourcePath = "OEBPS/cover.xhtml"),
        ChapterSummary(1, "One", 900, sourcePath = "OEBPS/text/ch1.xhtml"),
        ChapterSummary(2, "Two", 900, sourcePath = "OEBPS/text/ch2.xhtml"),
    )
    private val anchors = mapOf("part-two" to 412, "figure" to 800)

    @Test
    fun anExactPathFindsItsChapter() {
        assertEquals(
            LinkDestination(2, 412),
            resolveInternalLink(chapters, "OEBPS/text/ch2.xhtml", "part-two", anchors),
        )
    }

    @Test
    fun aPathThatDiffersOnlyInCaseStillFindsIt() {
        assertEquals(
            LinkDestination(1, 0),
            resolveInternalLink(chapters, "OEBPS/TEXT/CH1.xhtml", null, emptyMap()),
        )
    }

    @Test
    fun aPathThatIsOnlyTheFileNameFindsItBySuffix() {
        assertEquals(
            LinkDestination(2, 800),
            resolveInternalLink(chapters, "text/ch2.xhtml", "figure", anchors),
        )
        // And the other way round, for a link written from a deeper directory.
        assertEquals(
            LinkDestination(0, 0),
            resolveInternalLink(chapters, "a/b/OEBPS/cover.xhtml", null, emptyMap()),
        )
    }

    @Test
    fun aSuffixMustFallOnASeparatorSoOneChapterNeverClaimsAnother() {
        val notes = listOf(
            ChapterSummary(0, "Endnotes", 100, sourcePath = "OEBPS/endnotes.xhtml"),
        )
        assertNull(resolveInternalLink(notes, "notes.xhtml", null, emptyMap()))
    }

    @Test
    fun anUnknownPathLeadsNowhere() {
        assertNull(resolveInternalLink(chapters, "OEBPS/text/ch9.xhtml", "part-two", anchors))
        assertNull(resolveInternalLink(chapters, "", null, emptyMap()))
        // A book with no archive behind it has no paths to match at all.
        assertNull(resolveInternalLink(listOf(ChapterSummary(0, "Plain", 10)), "ch1.xhtml", null, emptyMap()))
    }

    @Test
    fun aFragmentThatNamesNoAnchorLandsAtTheChapterStart() {
        assertEquals(
            LinkDestination(2, 0),
            resolveInternalLink(chapters, "OEBPS/text/ch2.xhtml", "no-such-id", anchors),
        )
    }

    @Test
    fun theQuestionAboutAnOutsideLinkShowsItsHost() {
        assertEquals("example.org", linkHost("https://example.org/wonderland/notes?x=1#top"))
        assertEquals("standardebooks.org", linkHost("http://reader@standardebooks.org:8080/ebooks"))
        // Nothing to take a host from: the link itself is the plainest answer.
        assertEquals("mailto:alice@example.org", linkHost("mailto:alice@example.org"))
    }
}
