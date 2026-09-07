package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.Bookmark
import com.readrai.readr.data.ChapterImage
import com.readrai.readr.data.ChapterLayout
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Contents
import com.readrai.readr.data.EpubExtractor
import com.readrai.readr.data.Footnote
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.data.ProviderSettings
import com.readrai.readr.data.ValidationStatus
import com.readrai.readr.data.ReadingPosition
import com.readrai.readr.data.SearchResult
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.KitLimits
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoProbe
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
        kit = Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), NanoProbe(context))
        // The library root is fresh per test; the Keystore preferences behind
        // the alias are not, so a key an earlier test stored would still be
        // there. Start every test with nothing connected.
        clearCredentials()
    }

    /** A second handle on the same library, as a relaunch would open it. */
    private fun reopen(probe: com.readrai.readr.kit.OnDeviceProbe = NanoProbe(context)): Kit =
        Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test"), probe)

    private fun providerSettings(from: Kit = kit): ProviderSettings =
        kitJson.decodeFromString(from.providers.providersJSON())

    @After
    fun tearDown() {
        clearCredentials()
        root.deleteRecursively()
    }

    private fun clearCredentials() {
        for (kind in listOf("openAI", "anthropic", "openRouter")) runCatching { kit.providers.deleteCredential(kind) }
    }

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

    /** Imports an EPUB from bytes on disk, the way the picker path does. */
    private suspend fun importEpub(file: File, name: String): BookSummary {
        val extracted = File(root, "$name-extracted")
        EpubExtractor.extract(file.inputStream(), extracted)
        return kitJson.decodeFromString(kit.library.importEPUB(extracted.absolutePath, file.absolutePath, name).await())
    }

    private suspend fun aliceBook(): BookSummary {
        val original = File(root, "alice.epub")
        context.assets.open("alice-in-wonderland.epub").use { i -> original.outputStream().use { i.copyTo(it) } }
        return importEpub(original, "alice")
    }

    /**
     * A picture is a U+FFFC in the chapter text and an entry path into the
     * book's own archive — never bytes across the bridge. The offset has to
     * index that placeholder in the string *Kotlin* holds, which is the whole
     * point of converting it.
     */
    @Test
    fun inlineImagesPointAtTheirPlaceholdersInUTF16() = runTest {
        val book = importEpub(IllustratedBook.write(File(root, "illustrated.epub")), "illustrated")
        assertEquals(IllustratedBook.TITLE, book.title)
        var found = 0
        for (index in 0 until book.chapterCount) {
            val text = kit.library.chapterText(book.id, index.toLong())
            val images = kitJson.decodeFromString<List<ChapterImage>>(kit.library.chapterImagesJSON(book.id, index.toLong()))
            for (image in images) {
                found++
                assertTrue("offset ${image.utf16Offset} is inside the chapter", image.utf16Offset in text.indices)
                assertEquals("the offset indexes the placeholder", '￼', text[image.utf16Offset])
                assertEquals(IllustratedBook.IMAGE_PATH, image.archivePath)
            }
            assertEquals("in reading order", images.map { it.utf16Offset }.sorted(), images.map { it.utf16Offset })
        }
        assertTrue("the fixture carries pictures", found >= 2)

        // Chapter one states a size in the markup; chapter two states none.
        val first = kitJson.decodeFromString<List<ChapterImage>>(kit.library.chapterImagesJSON(book.id, 0L)).single()
        assertEquals(IllustratedBook.ALT, first.alt)
        assertEquals(IllustratedBook.FIGURE_WIDTH.toDouble(), first.displayWidth!!, 0.01)
        assertEquals(IllustratedBook.FIGURE_HEIGHT.toDouble(), first.displayHeight!!, 0.01)
        val second = kitJson.decodeFromString<List<ChapterImage>>(kit.library.chapterImagesJSON(book.id, 1L)).single()
        assertNull("no stated width is no width, not a guess", second.displayWidth)
        assertNull(second.displayHeight)
    }

    /**
     * A chapter knows which document it came from, so a tapped link can be
     * resolved on the Kotlin side from the chapter list already in hand. A
     * book with no archive behind it says so with a null rather than a "".
     */
    @Test
    fun chaptersCarryTheirSourcePathWhenTheyHaveOne() = runTest {
        val alice = aliceBook()
        val chapters = kitJson.decodeFromString<List<ChapterSummary>>(kit.library.chaptersJSON(alice.id))
        assertEquals("OEBPS/ch1.xhtml", chapters[0].sourcePath)
        assertEquals("OEBPS/ch12.xhtml", chapters.last().sourcePath)

        val file = File(root, "plain.txt").apply { writeText("One chapter of prose and no archive at all.") }
        val plain = kitJson.decodeFromString<BookSummary>(kit.library.importPlainText(file.absolutePath, "Plain").await())
        val plainChapters = kitJson.decodeFromString<List<ChapterSummary>>(kit.library.chaptersJSON(plain.id))
        assertTrue(plainChapters.isNotEmpty())
        for (chapter in plainChapters) assertNull("plain text has no source document", chapter.sourcePath)
    }

    /**
     * The sample has neither pictures nor lifted notes, and both answers are
     * an empty list rather than a failure — the reader asks for them on every
     * chapter it opens.
     */
    @Test
    fun aBookWithNoPicturesOrNotesAnswersWithEmptyLists() = runTest {
        val alice = aliceBook()
        for (index in 0 until alice.chapterCount) {
            assertTrue(kitJson.decodeFromString<List<ChapterImage>>(kit.library.chapterImagesJSON(alice.id, index.toLong())).isEmpty())
            assertTrue(kitJson.decodeFromString<List<Footnote>>(kit.library.chapterFootnotesJSON(alice.id, index.toLong())).isEmpty())
        }
        try {
            kit.library.chapterImagesJSON(alice.id, 99L)
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("That chapter doesn't exist in this book.", e.message)
        }
        try {
            kit.library.chapterFootnotesJSON("not-a-book", 0L)
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("This book is no longer in your library.", e.message)
        }
    }

    /** Both kinds of link cross the bridge whole: a URL out, a path and fragment in. */
    @Test
    fun linkSpansCarryWhereTheyPoint() = runTest {
        val book = importEpub(IllustratedBook.write(File(root, "linked.epub")), "linked")
        val layout = kitJson.decodeFromString<ChapterLayout>(kit.library.chapterLayoutJSON(book.id, 0L))
        val links = layout.spans.filter { it.kind == "link" }
        assertEquals("one link in, one out", 2, links.size)
        val internal = links.single { it.url == null }
        assertEquals(IllustratedBook.SECOND_PATH, internal.linkPath)
        assertEquals(IllustratedBook.ANCHOR, internal.linkFragment)
        val external = links.single { it.url != null }
        assertEquals(IllustratedBook.EXTERNAL_URL, external.url)
        assertNull(external.linkPath)

        // A note lifted out of the flow comes back under the fragment its
        // noteref names, and only for the chapter that holds it.
        val notes = kitJson.decodeFromString<List<Footnote>>(
            kit.library.chapterFootnotesJSON(book.id, IllustratedBook.NOTE_CHAPTER.toLong())
        )
        assertEquals(listOf(IllustratedBook.NOTE_ID), notes.map { it.id })
        assertTrue(notes.single().text, notes.single().text.contains(IllustratedBook.NOTE_TEXT))
        assertEquals("[]", kit.library.chapterFootnotesJSON(book.id, 0L))

        // And the anchor it points at is a real place in the target chapter.
        val target = kitJson.decodeFromString<ChapterLayout>(kit.library.chapterLayoutJSON(book.id, 1L))
        val offset = target.anchors[IllustratedBook.ANCHOR]!!
        val text = kit.library.chapterText(book.id, 1L)
        assertTrue(
            "the anchor opens the sentence it names: '${text.substring(offset, minOf(text.length, offset + 20))}'",
            text.startsWith(IllustratedBook.ANCHORED_SENTENCE, offset),
        )
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
        kit.library.setHighlightNote(book.id, made.id, "worth quoting")
        kit.library.setHighlightColor(book.id, made.id, "purple")
        val noted = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)).single()
        assertEquals("worth quoting", noted.note)
        assertEquals(HighlightColor.PURPLE, noted.markerColor)
        assertEquals("the range is untouched by an edit", made.utf16Start to made.utf16End, noted.utf16Start to noted.utf16End)
        kit.library.setHighlightNote(book.id, made.id, "")
        val cleared = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)).single()
        assertNull(cleared.note)
        assertEquals("clearing the note leaves the colour", HighlightColor.PURPLE, cleared.markerColor)

        kit.library.removeHighlight(book.id, made.id)
        assertEquals("[]", kit.library.highlightsJSON(book.id))
    }

    /**
     * Colour and note are separate edits, and each one leaves the other
     * exactly as it was — the reason the facade has two methods rather than
     * one `update` a caller has to feed both halves of.
     */
    @Test
    fun colourAndNoteAreEditedApart() = runTest {
        val book = twoChapterBook()
        val made = kitJson.decodeFromString<Highlight>(kit.library.addHighlight(book.id, 0L, 0L, 4L, "purple", ""))
        assertEquals(HighlightColor.PURPLE, made.markerColor)

        kit.library.setHighlightNote(book.id, made.id, "in the margin")
        val noted = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)).single()
        assertEquals("in the margin", noted.note)
        assertEquals("a note leaves the colour alone", HighlightColor.PURPLE, noted.markerColor)

        kit.library.setHighlightColor(book.id, made.id, "green")
        val recoloured = kitJson.decodeFromString<List<Highlight>>(kit.library.highlightsJSON(book.id)).single()
        assertEquals(HighlightColor.GREEN, recoloured.markerColor)
        assertEquals("a recolour leaves the note alone", "in the margin", recoloured.note)
        assertEquals(made.quotedText, recoloured.quotedText)
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
            kit.library.setHighlightColor(book.id, "not-a-highlight", "yellow")
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("That highlight is no longer in your library.", e.message)
        }
        try {
            kit.library.setHighlightNote(book.id, "not-a-highlight", "hello")
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

        kit.library.removeBookmark(book.id, earlier.id)
        assertEquals(listOf(later.id), kitJson.decodeFromString<List<Bookmark>>(kit.library.bookmarksJSON(book.id)).map { it.id })
        kit.library.removeBookmark(book.id, later.id)
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

    /**
     * A four-chapter book whose second and fourth chapters are the only ones
     * that speak of rabbits — in three different cases, so what comes back
     * proves the search is case-insensitive and in reading order.
     */
    private suspend fun rabbitBook(): BookSummary {
        val file = File(root, "warren.md").apply {
            writeText(
                """
                # One

                Nothing of the sort happens in the opening chapter at all.

                # Two

                The white Rabbit ran past her, and a rabbit in a waistcoat is
                a strange thing to meet before lunch.

                # Three

                Still nothing here, only a long walk and some weather.

                # Four

                RABBIT, she said aloud, and the word went nowhere.
                """.trimIndent()
            )
        }
        return kitJson.decodeFromString(kit.library.importPlainText(file.absolutePath, "Warren").await())
    }

    @Test
    fun searchFindsEveryMatchInReadingOrder() = runTest {
        val book = rabbitBook()
        val hits = kitJson.decodeFromString<List<SearchResult>>(kit.library.searchJSON(book.id, "rabbit", 100L))
        assertEquals("two in chapter 2, one in chapter 4", 3, hits.size)
        assertEquals("ids number the results", listOf(0, 1, 2), hits.map { it.id })
        assertEquals("reading order, chapter by chapter", listOf(1, 1, 3), hits.map { it.chapterIndex })

        for (hit in hits) {
            val text = kit.library.chapterText(book.id, hit.chapterIndex.toLong())
            assertTrue(
                "offset ${hit.utf16Offset} points at the match: '${text.substring(hit.utf16Offset, hit.utf16Offset + 6)}'",
                text.substring(hit.utf16Offset, hit.utf16Offset + 6).equals("rabbit", ignoreCase = true),
            )
            assertTrue("every hit quotes its line", hit.snippet.isNotBlank())
            assertTrue("the snippet carries the match", hit.snippet.contains("rabbit", ignoreCase = true))
        }
        // Within a chapter, in the order they are read.
        assertTrue("earlier match first", hits[0].utf16Offset < hits[1].utf16Offset)

        // Nothing typed is nothing found — not everything.
        assertEquals("[]", kit.library.searchJSON(book.id, "", 100L))
        assertEquals("[]", kit.library.searchJSON(book.id, "   \n ", 100L))
        assertEquals("[]", kit.library.searchJSON(book.id, "hippogriff", 100L))
        // And the limit is honoured.
        assertEquals(1, kitJson.decodeFromString<List<SearchResult>>(kit.library.searchJSON(book.id, "rabbit", 1L)).size)
    }

    /**
     * The offsets a search reports are the ones Kotlin can index with, which
     * is not the count the kit keeps: this chapter opens on an accent and an
     * emoji, so the two coordinate systems have already drifted apart by the
     * time the match arrives.
     */
    @Test
    fun searchOffsetsCrossTheBridgeInUTF16() = runTest {
        val book = twoChapterBook()
        val text = kit.library.chapterText(book.id, 0)
        val hit = kitJson.decodeFromString<List<SearchResult>>(kit.library.searchJSON(book.id, "prose", 100L)).single()
        assertEquals(0, hit.chapterIndex)
        assertEquals("prose", text.substring(hit.utf16Offset, hit.utf16Offset + 5))
        // "Café 👍" is 6 characters to the kit and 7 code units to Kotlin, so
        // an unconverted offset would land one short of the word.
        assertTrue("past the emoji", hit.utf16Offset > text.indexOf("👍"))

        val opening = kitJson.decodeFromString<List<SearchResult>>(kit.library.searchJSON(book.id, "café", 100L)).single()
        assertEquals(0, opening.utf16Offset)
        assertEquals("Café", text.substring(0, 4))
    }

    @Test
    fun searchOnAnUnknownBookIsReaderFacing() = runTest {
        try {
            kit.library.searchJSON("not-a-book", "rabbit", 100L)
            assertTrue("expected a failure", false)
        } catch (e: Exception) {
            assertEquals("This book is no longer in your library.", e.message)
        }
    }


    // MARK: AI providers (A3a)

    /**
     * The settings screen is built entirely from this one answer, so what it
     * lists is what the reader can reach: the four ways in this build has,
     * grouped by company, with the phone's own model leading — and neither
     * Apple's system model nor an Ollama server anywhere in it.
     */
    @Test
    fun providerSettingsListEveryWayInThisBuildHas() {
        val settings = providerSettings()
        assertEquals(
            listOf("android", "openai", "openrouter", "anthropic"),
            settings.vendors.map { it.id },
        )
        assertEquals("the phone's own model leads", "On this phone", settings.vendors.first().title)
        assertEquals(
            listOf("geminiNano", "openAI", "openRouter", "anthropic"),
            settings.vendors.flatMap { card -> card.kinds.map { it.kind } },
        )
        // ChatGPT's subscription path and Ollama are not offered here.
        assertFalse(settings.vendors.flatMap { it.kinds }.any { it.kind == "chatGPT" || it.kind == "local" })
        assertEquals("On-device", settings.vendors.first().badge)
        assertTrue("a key-only build never advertises a sign-in", settings.vendors.drop(1).all { it.badge == "API key" })

        assertEquals("Ask uses no model yet — connect one below.", settings.askUsesLine)
        assertNull(settings.selection)

        val openAI = settings.vendors.single { it.id == "openai" }.kinds.single()
        assertTrue(openAI.usesAPIKey)
        assertFalse(openAI.isOnDevice)
        assertFalse(openAI.hasCredential)
        assertEquals(ValidationStatus.UNKNOWN, openAI.status.state)
        assertTrue("every card offers models to pick from", openAI.models.isNotEmpty())
        assertTrue(openAI.models.any { it.id == openAI.activeModelID })
        assertTrue("a model is named, never shown as its wire id", openAI.models.all { it.name.isNotBlank() && it.name != it.id })
        assertEquals("Paste an API key to connect.", settings.vendors.single { it.id == "openai" }.hint)
    }

    @Test
    fun aSavedKeyShowsOnItsCard() {
        kit.providers.saveAPIKey("openAI", "sk-test")
        val openAI = providerSettings().vendors.single { it.id == "openai" }.kinds.single()
        assertTrue(openAI.hasCredential)
        assertNull("connected cards stop telling you how to connect", providerSettings().vendors.single { it.id == "openai" }.hint)

        kit.providers.deleteCredential("openAI")
        assertFalse(providerSettings().vendors.single { it.id == "openai" }.kinds.single().hasCredential)
    }

    /** The chosen model is the app's own file, not UserDefaults — so it is still there next launch. */
    @Test
    fun theActiveSelectionSurvivesARelaunch() {
        kit.providers.saveAPIKey("openAI", "sk-test")
        kit.providers.setActive("openAI", "gpt-5.6-terra")
        assertTrue(File(root, "provider-selection.json").isFile)

        val relaunched = providerSettings(from = reopen())
        assertEquals("openAI", relaunched.selection?.kind)
        assertEquals("gpt-5.6-terra", relaunched.selection?.modelID)
        assertTrue(relaunched.askUsesLine, relaunched.askUsesLine.contains("GPT-5.6 Terra"))
        val openAI = relaunched.vendors.single { it.id == "openai" }.kinds.single()
        assertTrue(openAI.isActive)
        assertEquals("gpt-5.6-terra", openAI.activeModelID)
    }

    @Test
    fun aBlankKeyIsRefusedInPlainLanguage() {
        try {
            kit.providers.saveAPIKey("openAI", "   ")
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("Paste an API key to connect.", e.message)
        }
        assertFalse(providerSettings().vendors.single { it.id == "openai" }.kinds.single().hasCredential)

        // A kind this phone does not have is refused the same way.
        try {
            kit.providers.saveAPIKey("appleIntelligence", "sk-test")
            assertTrue("expected a refusal", false)
        } catch (e: Exception) {
            assertEquals("That provider isn't supported on this device.", e.message)
        }
    }

    /**
     * A key that no provider will accept settles somewhere other than active,
     * and says why in a sentence — never a Swift case name, never a raw
     * status code.
     */
    @Test
    fun aKeyThatIsNotAcceptedSettlesOnASentence() = runTest {
        kit.providers.saveAPIKey("openAI", "sk-test")
        val status = kitJson.decodeFromString<ValidationStatus>(kit.providers.validate("openAI").await())
        assertFalse("a made-up key is never active: $status", status.isActive)
        assertTrue(status.state, status.state == ValidationStatus.INVALID || status.state == ValidationStatus.UNAVAILABLE)
        val reason = status.reason ?: ""
        assertTrue("a settled check says why", reason.isNotBlank())
        for (leak in listOf("Optional(", "invalid(", "unavailable(", "HTTPError", "ValidationState", "ReadrKit.")) {
            assertFalse("no Swift internals in \"$reason\"", reason.contains(leak))
        }
        assertEquals("the card reads it back", status, providerSettings().vendors.single { it.id == "openai" }.kinds.single().status)
    }

    /**
     * The phone's own model is the answer while the reader has chosen
     * nothing — but only on a phone that can actually run it. The probe is
     * asked on every read, so one library says different things on two
     * different phones.
     */
    @Test
    fun aPhoneThatCanRunNanoStartsWithIt() {
        val ready = reopen(FixedProbe.READY)
        assertTrue(ready.providers.hasAnyProvider())
        val settings = providerSettings(from = ready)
        assertEquals("geminiNano", settings.selection?.kind)
        assertEquals("gemini-nano", settings.selection?.modelID)
        assertTrue(settings.askUsesLine, settings.askUsesLine.startsWith("Ask uses Gemini Nano"))
        assertTrue(settings.vendors.first().kinds.single().isActive)

        val cannot = reopen(FixedProbe.UNSUPPORTED)
        assertFalse("nothing is chosen, and nothing is assumed", cannot.providers.hasAnyProvider())
        val without = providerSettings(from = cannot)
        assertNull(without.selection)
        assertEquals("Ask uses no model yet — connect one below.", without.askUsesLine)
    }

    /**
     * The phone's own card explains itself rather than disappearing: this
     * emulator has no AICore, and what it says so with is the kit's sentence.
     */
    @Test
    fun theOnDeviceCardSaysWhyThisPhoneCannotRunIt() = runTest {
        val status = kitJson.decodeFromString<ValidationStatus>(kit.providers.validate("geminiNano").await())
        assertEquals(ValidationStatus.INVALID, status.state)
        assertEquals("Gemini Nano isn't available on this phone.", status.reason)
        assertFalse("an unrunnable model is never the active one", kit.providers.hasAnyProvider())
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
