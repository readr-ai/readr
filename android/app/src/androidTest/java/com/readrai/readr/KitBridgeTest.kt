package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.Bookmark
import com.readrai.readr.data.ChapterLayout
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Contents
import com.readrai.readr.data.EpubExtractor
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.data.ReadingPosition
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.KitLimits
import com.readrai.readr.kit.Kit
import java.io.File
import kotlinx.coroutines.future.await
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** ReadrKit, cross-compiled, reached through the jextract bridge. */
@RunWith(AndroidJUnit4::class)
class KitBridgeTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var kit: Kit

    @Before
    fun setUp() {
        root = File(context.cacheDir, "kit-test-${System.nanoTime()}").apply { mkdirs() }
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"))
    }

    @After
    fun tearDown() { root.deleteRecursively() }

    @Test
    fun describesItself() {
        assertTrue(kit.library.kitDescription().startsWith("ReadrKit on"))
    }

    @Test
    fun extractionCapsComeFromTheKit() {
        assertEquals(64L * 1024 * 1024, KitLimits.epubPerEntryByteCap())
        assertEquals(512L * 1024 * 1024, KitLimits.epubCumulativeByteCap())
    }

    @Test
    fun importsPlainTextAndKeepsPosition() = runTest {
        val file = File(root, "notes.txt").apply { writeText("Chapter one\n\nIt was a bright cold day in April.\n\nChapter two\n\nThe clocks were striking thirteen.") }
        val json = kit.library.importPlainText(file.absolutePath, "Notes").await()
        val book = kitJson.decodeFromString<BookSummary>(json)
        assertEquals("Notes", book.title)
        assertTrue(book.chapterCount >= 1)
        val books = kitJson.decodeFromString<List<BookSummary>>(kit.library.booksJSON())
        assertEquals(listOf(book.id), books.map { it.id })
        assertTrue(File(root, "Books/${book.sourceFilename}").exists())

        assertEquals("", kit.library.positionJSON(book.id))
        kit.library.savePosition(book.id, 0, 12)
        assertEquals(ReadingPosition(chapterIndex = 0, utf16Offset = 12, characterOffset = 12), kitJson.decodeFromString<ReadingPosition>(kit.library.positionJSON(book.id)))

        kit.library.removeBook(book.id)
        assertEquals("[]", kit.library.booksJSON())
    }

    @Test
    fun importsTheBundledEpub() = runTest {
        val original = File(root, "alice.epub")
        context.assets.open("alice-in-wonderland.epub").use { i -> original.outputStream().use { i.copyTo(it) } }
        val extracted = File(root, "alice")
        EpubExtractor.extract(original.inputStream(), extracted)
        val book = kitJson.decodeFromString<BookSummary>(kit.library.importEPUB(extracted.absolutePath, original.absolutePath, "fallback").await())
        assertEquals("Alice's Adventures in Wonderland", book.title)
        assertEquals(12, book.chapterCount)
        assertFalse(book.isImageOnly)
        // Covers live as files, never inside library.json (it is rewritten on every position save).
        assertFalse(File(root, "library.json").readText().contains("coverImageData\":\""))
        val chapters = kitJson.decodeFromString<List<ChapterSummary>>(kit.library.chaptersJSON(book.id))
        assertEquals(12, chapters.size)
        assertTrue(chapters[0].title.contains("Rabbit-Hole"))
        assertTrue(kit.library.chapterText(book.id, 0).contains("Alice was beginning to get very tired"))
    }

    @Test
    fun positionsCrossTheBridgeInUTF16() = runTest {
        // "Café 👍": the kit counts 6 characters, Kotlin 7 code units.
        val file = File(root, "cafe.txt").apply { writeText("Café 👍 ok, then more words follow here.") }
        val book = kitJson.decodeFromString<BookSummary>(kit.library.importPlainText(file.absolutePath, "Café").await())
        kit.library.savePosition(book.id, 0L, 7L)
        val after = kitJson.decodeFromString<ReadingPosition>(kit.library.positionJSON(book.id))
        assertEquals(6, after.characterOffset)
        assertEquals(7, after.utf16Offset)
        // A code unit inside the emoji rounds down to the character holding it.
        kit.library.savePosition(book.id, 0L, 6L)
        val inside = kitJson.decodeFromString<ReadingPosition>(kit.library.positionJSON(book.id))
        assertEquals(5, inside.characterOffset)
        assertEquals(5, inside.utf16Offset)
        // Past the end clamps to the text.
        kit.library.savePosition(book.id, 0L, 10_000L)
        val text = kit.library.chapterText(book.id, 0)
        assertEquals(text.length, kitJson.decodeFromString<ReadingPosition>(kit.library.positionJSON(book.id)).utf16Offset)
        // Every character boundary round-trips through the same table.
        for (utf16 in listOf(0, 1, 4, 5, 7, 8, text.length)) {
            kit.library.savePosition(book.id, 0L, utf16.toLong())
            assertEquals("offset $utf16", utf16, kitJson.decodeFromString<ReadingPosition>(kit.library.positionJSON(book.id)).utf16Offset)
        }
    }

    @Test
    fun chapterLayoutAndContentsSpeakUTF16() = runTest {
        val original = File(root, "alice.epub")
        context.assets.open("alice-in-wonderland.epub").use { i -> original.outputStream().use { i.copyTo(it) } }
        val extracted = File(root, "alice")
        EpubExtractor.extract(original.inputStream(), extracted)
        val book = kitJson.decodeFromString<BookSummary>(kit.library.importEPUB(extracted.absolutePath, original.absolutePath, "fallback").await())
        var spans = 0
        for (index in 0 until book.chapterCount) {
            val text = kit.library.chapterText(book.id, index.toLong())
            val layout = kitJson.decodeFromString<ChapterLayout>(kit.library.chapterLayoutJSON(book.id, index.toLong()))
            assertEquals("utf16Length is the Kotlin length", text.length, layout.utf16Length)
            assertEquals(index, layout.index)
            for (span in layout.spans) {
                assertTrue("span within the text: $span", span.start in 0 until span.end && span.end <= text.length)
                spans++
            }
            for ((_, offset) in layout.anchors) assertTrue(offset in 0..text.length)
        }
        assertTrue("the sample carries formatting", spans > 0)
        val contents = kitJson.decodeFromString<Contents>(kit.library.contentsJSON(book.id))
        assertFalse("the EPUB has a real table of contents", contents.isFallback)
        assertTrue(contents.rows.isNotEmpty())
        assertTrue(contents.rows.any { it.title.contains("Rabbit-Hole") })
        assertEquals(contents.rows.indices.toList(), contents.rows.map { it.id })
        for (row in contents.rows) assertTrue(row.chapterIndex in 0 until book.chapterCount)
    }

    @Test
    fun contentsFallBackToTheSpineWithoutATableOfContents() = runTest {
        val file = File(root, "plain.txt").apply { writeText("Just one long chapter of prose with no headings at all.") }
        val book = kitJson.decodeFromString<BookSummary>(kit.library.importPlainText(file.absolutePath, "Plain").await())
        val contents = kitJson.decodeFromString<Contents>(kit.library.contentsJSON(book.id))
        assertTrue(contents.isFallback)
        assertEquals(book.chapterCount, contents.rows.size)
        assertEquals(0, contents.rows[0].utf16Offset)
    }

    @Test
    fun seedsTheSampleOnce() = runTest {
        assertTrue(kit.library.needsSampleSeed())
        val original = File(root, "alice.epub")
        context.assets.open("alice-in-wonderland.epub").use { i -> original.outputStream().use { i.copyTo(it) } }
        val extracted = File(root, "alice")
        EpubExtractor.extract(original.inputStream(), extracted)
        val first = kit.library.seedSampleIfNeeded(extracted.absolutePath, original.absolutePath).await()
        assertTrue(first.contains("Alice"))
        assertFalse(kit.library.needsSampleSeed())
        val second = kit.library.seedSampleIfNeeded(extracted.absolutePath, original.absolutePath).await()
        assertEquals("", second)
        assertEquals(1, kitJson.decodeFromString<List<BookSummary>>(kit.library.booksJSON()).size)
    }

    @Test
    fun credentialsRoundTripThroughTheKit() {
        assertFalse(kit.credentials.hasCredential("anthropic"))
        kit.credentials.saveAPIKey("anthropic", "sk-ant-test")
        assertTrue(kit.credentials.hasCredential("anthropic"))
        assertEquals("sk-ant-test", kit.credentials.apiKey("anthropic"))
        kit.credentials.deleteCredential("anthropic")
        assertFalse(kit.credentials.hasCredential("anthropic"))
    }

    @Test
    fun extractorRejectsPathTraversal() {
        val zip = File(root, "evil.zip")
        java.util.zip.ZipOutputStream(zip.outputStream()).use { z ->
            z.putNextEntry(java.util.zip.ZipEntry("../escape.txt")); z.write("x".toByteArray()); z.closeEntry()
        }
        try {
            EpubExtractor.extract(zip.inputStream(), File(root, "evil"))
            assertTrue("expected rejection", false)
        } catch (e: EpubExtractor.Rejected) {
            assertFalse("entry names never reach the reader", e.message!!.contains("escape.txt"))
        }
    }

    /** A two-chapter Markdown book, chapter 0 opening on a non-ASCII grapheme. */
    private suspend fun twoChapterBook(): BookSummary {
        val file = File(root, "annotated.md").apply {
            writeText(
                """
                # One

                Café 👍 and quite a lot more prose in the first chapter here.

                # Two

                Second chapter opens here
                and wraps onto another line with plenty of words.
                """.trimIndent()
            )
        }
        return kitJson.decodeFromString(kit.library.importPlainText(file.absolutePath, "Annotated").await())
    }

    @Test
    fun highlightsRoundTripInUTF16() = runTest {
        val book = twoChapterBook()
        val text = kit.library.chapterText(book.id, 0)
        // "Café 👍": 6 characters to the kit, 7 code units to Kotlin.
        val made = kitJson.decodeFromString<Highlight>(
            kit.library.addHighlight(book.id, 0L, 0L, 7L, "green", "")
        )
        assertEquals(0, made.chapterIndex)
        assertEquals(0, made.utf16Start)
        assertEquals(7, made.utf16End)
        assertEquals(text.substring(made.utf16Start, made.utf16End), made.quotedText)
        assertEquals("Café 👍", made.quotedText)
        assertNull("an empty note is no note", made.note)
        assertEquals("green", made.color)
        assertEquals(HighlightColor.GREEN, made.markerColor)
        assertTrue("ISO-8601 with fractional seconds", made.createdAt.matches(Regex(".*T.*\\.\\d{3}(Z|[+-]\\d{2}:\\d{2})")))

        assertEquals(listOf(made), kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)))

        // A note and a recolour, then the note cleared again.
        kit.library.updateHighlight(made.id, "purple", "worth quoting")
        val noted = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)).single()
        assertEquals("worth quoting", noted.note)
        assertEquals(HighlightColor.PURPLE, noted.markerColor)
        assertEquals("the range is untouched by an edit", made.utf16Start to made.utf16End, noted.utf16Start to noted.utf16End)
        kit.library.updateHighlight(made.id, "blue", "")
        val cleared = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)).single()
        assertNull(cleared.note)
        assertEquals(HighlightColor.BLUE, cleared.markerColor)

        kit.library.removeHighlight(made.id)
        assertEquals("[]", kit.library.highlightsJSON(book.id))
    }

    @Test
    fun highlightsComeBackInReadingOrder() = runTest {
        val book = twoChapterBook()
        val second = kitJson.decodeFromString<Highlight>(kit.library.addHighlight(book.id, 1L, 0L, 6L, "yellow", ""))
        val firstLate = kitJson.decodeFromString<Highlight>(kit.library.addHighlight(book.id, 0L, 8L, 11L, "pink", "note"))
        val firstEarly = kitJson.decodeFromString<Highlight>(kit.library.addHighlight(book.id, 0L, 0L, 4L, "yellow", ""))
        val listed = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id))
        assertEquals(listOf(firstEarly.id, firstLate.id, second.id), listed.map { it.id })
        assertEquals(listOf(0, 0, 1), listed.map { it.chapterIndex })
        assertEquals("note", listed[1].note)
    }

    @Test
    fun anEmptySelectionIsRefusedInPlainLanguage() = runTest {
        val book = twoChapterBook()
        try {
            kit.library.addHighlight(book.id, 0L, 3L, 3L, "yellow", "")
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            val message = e.message ?: ""
            assertFalse("no Swift case names: $message", message.contains("emptySelection"))
            assertFalse("no type-and-case shape: $message", message.contains("("))
            assertTrue(message, message.startsWith("Nothing was selected to highlight."))
        }
        assertEquals("[]", kit.library.highlightsJSON(book.id))
    }

    @Test
    fun anUnknownColourIsRefusedInPlainLanguage() = runTest {
        val book = twoChapterBook()
        try {
            kit.library.addHighlight(book.id, 0L, 0L, 4L, "chartreuse", "")
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("That highlight colour isn't available.", e.message)
        }
        try {
            kit.library.updateHighlight("not-a-highlight", "yellow", "")
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("That highlight is no longer in your library.", e.message)
        }
        assertEquals("[]", kit.library.highlightsJSON(book.id))
    }

    @Test
    fun bookmarksCarryASnippetAndSortByPlace() = runTest {
        val book = twoChapterBook()
        val secondChapterText = kit.library.chapterText(book.id, 1)
        // Bookmarked out of order: the list is sorted by where they are, not when.
        val later = kitJson.decodeFromString<Bookmark>(kit.library.addBookmark(book.id, 1L, 0L))
        val earlier = kitJson.decodeFromString<Bookmark>(kit.library.addBookmark(book.id, 0L, 7L))

        assertEquals(1, later.chapterIndex)
        assertEquals(0, later.utf16Offset)
        assertEquals(secondChapterText.take(60).replace('\n', ' ').trim(), later.snippet)
        assertEquals(60, later.snippet.length)
        assertFalse("newlines become spaces", later.snippet.contains('\n'))
        assertEquals(later.snippet, later.snippet.trim())

        assertEquals(0, earlier.chapterIndex)
        assertEquals(7, earlier.utf16Offset)
        assertTrue(earlier.snippet, earlier.snippet.startsWith("and quite a lot more prose"))

        val listed = kitJson.decodeFromString<List<Bookmark>>(kit.library.bookmarksJSON(book.id))
        assertEquals(listOf(earlier.id, later.id), listed.map { it.id })
        assertEquals(listOf(0, 1), listed.map { it.chapterIndex })
        assertNotNull(listed.first().createdAt)

        kit.library.removeBookmark(earlier.id)
        assertEquals(listOf(later.id), kitJson.decodeFromString<List<Bookmark>>(kit.library.bookmarksJSON(book.id)).map { it.id })
        kit.library.removeBookmark(later.id)
        assertEquals("[]", kit.library.bookmarksJSON(book.id))
    }

    @Test
    fun annotationsOnAnUnknownBookOrChapterAreReaderFacing() = runTest {
        val book = twoChapterBook()
        try {
            kit.library.highlightsJSON("not-a-book")
            assertTrue("expected a failure", false)
        } catch (e: Exception) {
            assertEquals("This book is no longer in your library.", e.message)
        }
        try {
            kit.library.addBookmark(book.id, 9L, 0L)
            assertTrue("expected a failure", false)
        } catch (e: Exception) {
            assertEquals("That chapter doesn't exist in this book.", e.message)
        }
    }

    @Test
    fun kitErrorsArriveReaderFacing() {
        try {
            kit.library.chaptersJSON("not-a-book")
            assertTrue("expected a failure", false)
        } catch (e: Exception) {
            assertEquals("This book is no longer in your library.", e.message)
        }
    }
}
