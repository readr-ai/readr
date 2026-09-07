package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.ui.reader.ExternalLinkPrompt
import com.readrai.readr.ui.reader.chapterIndexForPath
import com.readrai.readr.ui.reader.externalLinkPrompt
import com.readrai.readr.ui.reader.noterefChapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/** Where a link lands: the document it names, the note it may answer to, and whether it may leave at all. */
@RunWith(AndroidJUnit4::class)
class ReaderLinksTest {
    private val chapters = listOf(
        ChapterSummary(0, "Cover", 40, sourcePath = "OEBPS/cover.xhtml"),
        ChapterSummary(1, "One", 900, sourcePath = "OEBPS/text/ch1.xhtml"),
        ChapterSummary(2, "Two", 900, sourcePath = "OEBPS/text/ch2.xhtml"),
    )

    @Test
    fun anExactPathFindsItsChapter() {
        assertEquals(2, chapterIndexForPath(chapters, "OEBPS/text/ch2.xhtml"))
    }

    @Test
    fun aPathThatDiffersOnlyInCaseStillFindsIt() {
        assertEquals(1, chapterIndexForPath(chapters, "OEBPS/TEXT/CH1.xhtml"))
    }

    @Test
    fun aPathThatIsOnlyTheFileNameFindsItBySuffix() {
        assertEquals(2, chapterIndexForPath(chapters, "text/ch2.xhtml"))
        // And the other way round, for a link written from a deeper directory.
        assertEquals(0, chapterIndexForPath(chapters, "a/b/OEBPS/cover.xhtml"))
    }

    @Test
    fun aSuffixMustFallOnASeparatorSoOneChapterNeverClaimsAnother() {
        val notes = listOf(ChapterSummary(0, "Endnotes", 100, sourcePath = "OEBPS/endnotes.xhtml"))
        assertNull(chapterIndexForPath(notes, "notes.xhtml"))
    }

    @Test
    fun anUnknownPathLeadsNowhere() {
        assertNull(chapterIndexForPath(chapters, "OEBPS/text/ch9.xhtml"))
        assertNull(chapterIndexForPath(chapters, ""))
        // A book with no archive behind it has no paths to match at all.
        assertNull(chapterIndexForPath(listOf(ChapterSummary(0, "Plain", 10)), "ch1.xhtml"))
    }

    /**
     * Note ids recur document by document, so which document a noteref is
     * answered from is the whole question — the Apple reader's rule, checked
     * here on the resolver the reader uses.
     */
    @Test
    fun aNoterefIsAnsweredFromTheDocumentItsPathNames() {
        assertEquals("another document's notes are that document's", 2, noterefChapter(chapters, "OEBPS/text/ch2.xhtml", 1))
        assertEquals("a ref back into this chapter is this chapter's", 1, noterefChapter(chapters, "OEBPS/text/ch1.xhtml", 1))
        assertEquals("a same-document ref has no path at all", 1, noterefChapter(chapters, null, 1))
        assertEquals("and a path this book does not have is read as this chapter's", 1, noterefChapter(chapters, "gone.xhtml", 1))
    }

    @Test
    fun theWebIsOpenedAndNamedByItsHost() {
        assertEquals(
            ExternalLinkPrompt("Open link?", "example.org"),
            externalLinkPrompt("https://example.org/wonderland/notes?x=1#top"),
        )
        assertEquals(
            ExternalLinkPrompt("Open link?", "standardebooks.org"),
            externalLinkPrompt("http://reader@standardebooks.org:8080/ebooks"),
        )
        // A web link the parser can find no host in is not a link to anywhere.
        assertNull(externalLinkPrompt("https:///no-host/page"))
        assertNull(externalLinkPrompt("http://"))
    }

    @Test
    fun mailAndTheTelephoneAreOfferedInTheirOwnWords() {
        assertEquals(
            ExternalLinkPrompt("Send an email to…", "alice@example.org"),
            externalLinkPrompt("mailto:alice@example.org?subject=Wonderland"),
        )
        assertEquals(ExternalLinkPrompt("Call…", "+441234567890"), externalLinkPrompt("tel:+441234567890"))
        assertNull("nothing to write to", externalLinkPrompt("mailto:"))
    }

    /**
     * The allow list is the whole of the policy: a book's markup is not a
     * reason to open a device's own schemes, and an implicit `ACTION_VIEW` is
     * not a thing to point at one.
     */
    @Test
    fun everythingElseStaysInsideTheApp() {
        val refused = listOf(
            "file:///data/data/com.readrai.readr/databases/library.json",
            "content://com.android.providers.downloads/all_downloads/1",
            "intent://scan/#Intent;scheme=zxing;end",
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
            "market://details?id=com.readrai.readr",
            "readr://open/book",
            "//example.org/schemeless",
            "/OEBPS/text/ch1.xhtml",
        )
        for (url in refused) assertNull("$url must not leave the app", externalLinkPrompt(url))
    }

    /**
     * A backslash, a space or a control character is how one parser is made to
     * read a different host than the next; nothing honest in a book needs one.
     */
    @Test
    fun aMangledUrlIsRefusedBeforeItIsParsedAtAll() {
        assertNull(externalLinkPrompt("https://example.org\\@evil.example/page"))
        assertNull(externalLinkPrompt("https:\\\\example.org/page"))
        assertNull(externalLinkPrompt("https://example.org/a b"))
        assertNull(externalLinkPrompt("https://exa mple.org/"))
        assertNull(externalLinkPrompt("https://example.org/\nx"))
        assertNull(externalLinkPrompt(""))
        assertNull(externalLinkPrompt("https://example.org/" + "a".repeat(4_000)))
    }
}
