package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.AskCitation
import com.readrai.readr.data.AskPosition
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
import com.readrai.readr.kit.AndroidNarration
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.KitLimits
import com.readrai.readr.kit.Kit
import com.readrai.readr.kit.NanoModel
import com.readrai.readr.kit.NarrationEvents
import com.readrai.readr.ui.ask.AnswerBlock
import com.readrai.readr.ui.ask.AnswerMarkdown
import com.readrai.readr.ui.listen.NarrationNowPlaying
import com.readrai.readr.ui.listen.NarrationSentence
import com.readrai.readr.ui.listen.NarrationState
import com.readrai.readr.ui.listen.NarrationVoices
import org.swift.swiftkit.core.SwiftArena
import java.io.File
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
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
        // The library root is fresh per test, and so is the secrets file: the
        // test alias has a file of its own (never the reader's "secrets"), and
        // emptying it here is what makes "nothing connected" true whatever an
        // earlier test stored.
        clearTestSecrets()
        kit = openKit()
    }

    /** A second handle on the same library, as a relaunch would open it. */
    private fun reopen(model: com.readrai.readr.kit.OnDeviceModel = NanoModel(context)): Kit = openKit(model)

    private fun openKit(model: com.readrai.readr.kit.OnDeviceModel = NanoModel(context)): Kit =
        Kit.open(root, KeystoreSecretStore(context, alias = TEST_ALIAS), model)

    private fun clearTestSecrets() {
        context.deleteSharedPreferences(KeystoreSecretStore.fileName(TEST_ALIAS))
    }

    private fun providerSettings(from: Kit = kit): ProviderSettings =
        kitJson.decodeFromString(from.providers.providersJSON())

    @After
    fun tearDown() {
        clearTestSecrets()
        root.deleteRecursively()
    }

    private companion object {
        /** This suite's Keystore key — and, since PR A3, its own secrets file. */
        const val TEST_ALIAS = "readr.secrets.test"

        /** Every question in this file is about the whole book. */
        const val WHOLE_BOOK_SCOPE = "{\"wholeBook\":true}"

        /**
         * A phone whose *default* voice is French and which also has an
         * English one — the shape that tells "the engine's default" apart from
         * "the language the book (or the reader) is in".
         */
        const val FRENCH_DEFAULT_AND_ENGLISH = """[
          {"id":"fr-fr-x-vlf#female_1-local","name":"French","language":"fr-FR","quality":"standard","isDefault":true},
          {"id":"en-us-x-tpf#female_1-local","name":"English","language":"en-US","quality":"standard","isDefault":false}
        ]"""

        /**
         * Real time, not the virtual clock: these tests wait on a real
         * embedding pass and a real socket, and the default 60 seconds is not
         * enough for a cold emulator.
         */
        val TEST_TIMEOUT = 3.minutes

        /**
         * How long a phone that cannot answer promptly takes to say whether
         * it can run its own model. Three seconds: shorter than `NanoModel`'s
         * five-second leash, and long enough that a second thread blocked
         * behind it is unmistakable rather than a slow emulator.
         */
        const val SLOW_READINESS_MS = 3_000L

        /**
         * `ProviderCatalog.geminiNanoModels`' budget: how much of the book
         * `AdaptiveContextStrategy` may gather for the phone's own model. It
         * is not, and must not be used as, the model's context window.
         */
        const val ASSEMBLY_BUDGET_TOKENS = 2_000L

        /** Filler with enough of a subject that retrieval has something to find. */
        const val WONDERLAND =
            "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: " +
                "once or twice she had peeped into the book her sister was reading, but it had no pictures or " +
                "conversations in it, and what is the use of a book, thought Alice, without pictures or conversations? " +
                "So she was considering in her own mind whether the pleasure of making a daisy-chain would be worth the " +
                "trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by " +
                "her, and down the rabbit-hole she went after it, never once considering how in the world she was to get " +
                "out again."
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
    fun importsPlainTextAndKeepsPosition() = runTest(timeout = TEST_TIMEOUT) {
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
    fun importsTheBundledEpub() = runTest(timeout = TEST_TIMEOUT) {
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
    fun positionsCrossTheBridgeInUTF16() = runTest(timeout = TEST_TIMEOUT) {
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
    fun chapterLayoutAndContentsSpeakUTF16() = runTest(timeout = TEST_TIMEOUT) {
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
    fun inlineImagesPointAtTheirPlaceholdersInUTF16() = runTest(timeout = TEST_TIMEOUT) {
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
    fun chaptersCarryTheirSourcePathWhenTheyHaveOne() = runTest(timeout = TEST_TIMEOUT) {
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
    fun aBookWithNoPicturesOrNotesAnswersWithEmptyLists() = runTest(timeout = TEST_TIMEOUT) {
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
    fun linkSpansCarryWhereTheyPoint() = runTest(timeout = TEST_TIMEOUT) {
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
    fun contentsFallBackToTheSpineWithoutATableOfContents() = runTest(timeout = TEST_TIMEOUT) {
        val file = File(root, "plain.txt").apply { writeText("Just one long chapter of prose with no headings at all.") }
        val book = kitJson.decodeFromString<BookSummary>(kit.library.importPlainText(file.absolutePath, "Plain").await())
        val contents = kitJson.decodeFromString<Contents>(kit.library.contentsJSON(book.id))
        assertTrue(contents.isFallback)
        assertEquals(book.chapterCount, contents.rows.size)
        assertEquals(0, contents.rows[0].utf16Offset)
    }

    @Test
    fun seedsTheSampleOnce() = runTest(timeout = TEST_TIMEOUT) {
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

    /**
     * A key goes in and comes out again through the provider facade — the one
     * door to a credential there is. What comes back is never the key itself:
     * the card says a key is *there*, and nothing on this side of the bridge
     * can ask what it says.
     */
    @Test
    fun keysRoundTripThroughTheProviderFacade() {
        assertFalse(hasCredential("anthropic"))
        kit.providers.saveAPIKey("anthropic", "sk-ant-test")
        assertTrue(hasCredential("anthropic"))
        kit.providers.disconnect("anthropic")
        assertFalse(hasCredential("anthropic"))
    }

    private fun hasCredential(kind: String, from: Kit = kit): Boolean =
        providerSettings(from).vendors.flatMap { it.kinds }.single { it.kind == kind }.hasCredential

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
    fun highlightsRoundTripInUTF16() = runTest(timeout = TEST_TIMEOUT) {
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
    fun colourAndNoteAreEditedApart() = runTest(timeout = TEST_TIMEOUT) {
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
    fun highlightsComeBackInReadingOrder() = runTest(timeout = TEST_TIMEOUT) {
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
    fun anEmptySelectionIsRefusedInPlainLanguage() = runTest(timeout = TEST_TIMEOUT) {
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
    fun anUnknownColourIsRefusedInPlainLanguage() = runTest(timeout = TEST_TIMEOUT) {
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
    fun bookmarksCarryASnippetAndSortByPlace() = runTest(timeout = TEST_TIMEOUT) {
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
    fun annotationsOnAnUnknownBookOrChapterAreReaderFacing() = runTest(timeout = TEST_TIMEOUT) {
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
    fun searchFindsEveryMatchInReadingOrder() = runTest(timeout = TEST_TIMEOUT) {
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
    fun searchOffsetsCrossTheBridgeInUTF16() = runTest(timeout = TEST_TIMEOUT) {
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
    fun searchOnAnUnknownBookIsReaderFacing() = runTest(timeout = TEST_TIMEOUT) {
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
    fun aKeyThatIsNotAcceptedSettlesOnASentence() = runTest(timeout = TEST_TIMEOUT) {
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
     * nothing — but only on a phone that can actually run it. The phone is
     * asked on the way into the payload, so one library says different things
     * on two different phones.
     */
    @Test
    fun aPhoneThatCanRunNanoStartsWithIt() {
        val ready = reopen(FakeOnDeviceModel())
        assertTrue(ready.providers.hasAnyProvider())
        val settings = providerSettings(from = ready)
        assertEquals("geminiNano", settings.selection?.kind)
        assertEquals("gemini-nano", settings.selection?.modelID)
        assertTrue(settings.askUsesLine, settings.askUsesLine.startsWith("Ask uses Gemini Nano"))
        assertTrue(settings.vendors.first().kinds.single().isActive)

        val cannot = reopen(FakeOnDeviceModel(state = FakeOnDeviceModel.UNSUPPORTED))
        assertFalse("nothing is chosen, and nothing is assumed", cannot.providers.hasAnyProvider())
        val without = providerSettings(from = cannot)
        assertNull(without.selection)
        assertEquals("Ask uses no model yet — connect one below.", without.askUsesLine)
    }

    /**
     * A phone that changes its mind is followed — after a refresh, and only
     * after one.
     *
     * The readiness the default selection is decided from is a CACHED answer:
     * the manager calls that closure holding its own lock, and asking the
     * phone from in there would put a five-second ML Kit bind inside a mutex
     * every reader of the selection waits on. So a model that goes away is
     * still reported as ready while the cache stands, and "Check again" —
     * which empties the cache and asks again — is what moves it.
     */
    @Test
    fun theCardFollowsThePhoneAfterARefresh() = runTest(timeout = TEST_TIMEOUT) {
        val phone = FakeOnDeviceModel()
        val nano = reopen(phone)
        assertEquals("geminiNano", providerSettings(from = nano).selection?.kind)

        // Back to back with the payload above, and a cached answer stands for
        // five seconds: what is being read here is the cache, not the phone.
        phone.state = FakeOnDeviceModel.UNSUPPORTED
        assertEquals(
            "the answer in hand stands until something asks for a new one",
            "geminiNano",
            providerSettings(from = nano).selection?.kind,
        )

        // "Check again": the cached answer is thrown away and the phone is
        // asked on the spot, off the manager's lock.
        val status = kitJson.decodeFromString<ValidationStatus>(nano.providers.validate("geminiNano").await())
        assertEquals(ValidationStatus.INVALID, status.state)
        val after = providerSettings(from = nano)
        assertNull("one refresh is all it takes", after.selection)
        assertEquals("Ask uses no model yet — connect one below.", after.askUsesLine)
        assertFalse(nano.providers.hasAnyProvider())
    }

    /**
     * Reading the selection asks the phone nothing at all.
     *
     * `ProviderManager` resolves the default selection under its own lock, so
     * every probe made from that closure is an ML Kit bind held inside a
     * mutex — and on a phone whose AICore is broken, five seconds of one. The
     * facade asks on the way IN and reads the answer from there, which is
     * what this counts: repeated payloads and repeated "is there anything to
     * ask with" inside one cache window ask the phone exactly nothing more.
     */
    @Test
    fun readingTheSelectionNeverAsksThePhone() {
        val phone = FakeOnDeviceModel()
        val nano = reopen(phone)

        providerSettings(from = nano)
        val asked = phone.readinessCalls.get()
        assertTrue("the first payload did ask the phone", asked >= 1)

        // Well inside the five seconds a cached answer stands for: every one
        // of these reads the selection, and none of them may reach the model.
        repeat(3) {
            providerSettings(from = nano)
            assertTrue(nano.providers.hasAnyProvider())
        }
        assertEquals(
            "nothing under the manager's lock asked the phone again",
            asked,
            phone.readinessCalls.get(),
        )
    }

    /**
     * A slow phone never holds the manager's lock.
     *
     * This is the bug the cache is for. `ProviderManager.selection` resolves
     * the default WITH ITS LOCK HELD, so a readiness probe made from that
     * closure runs an ML Kit bind — up to five seconds of one on a phone
     * whose AICore is broken — inside the mutex every other provider
     * operation needs. Choosing a provider, saving a key, reading a
     * validation state: all of them queue behind a check none of them asked
     * for, on whatever thread they happened to run on.
     *
     * So: one thread asks whether there is anything to ask with, against a
     * phone that takes [SLOW_READINESS_MS] to answer, and the other thread
     * chooses a provider while that is in flight. The choice must not wait
     * for the phone.
     */
    @Test
    fun aSlowPhoneNeverHoldsTheManagersLock() {
        val phone = FakeOnDeviceModel(readinessDelayMillis = SLOW_READINESS_MS)
        val nano = reopen(phone)
        val asking = Thread { nano.providers.hasAnyProvider() }
        asking.start()
        // Long enough that the probe is under way, and a small fraction of it.
        Thread.sleep(SLOW_READINESS_MS / 6)
        assertTrue("the phone is being asked right now", phone.readinessCalls.get() >= 1)

        val started = System.nanoTime()
        nano.providers.setActive("anthropic", "claude-opus-5")
        val waited = (System.nanoTime() - started) / 1_000_000

        asking.join(SLOW_READINESS_MS * 2)
        assertFalse("the asking thread finished", asking.isAlive)
        assertTrue(
            "choosing a provider waited ${waited}ms on a check of a model it does not use",
            waited < SLOW_READINESS_MS / 3,
        )
    }

    /**
     * The phone's own card explains itself rather than disappearing: this
     * emulator has no AICore, and what it says so with is the kit's sentence.
     */
    @Test
    fun theOnDeviceCardSaysWhyThisPhoneCannotRunIt() = runTest(timeout = TEST_TIMEOUT) {
        val status = kitJson.decodeFromString<ValidationStatus>(kit.providers.validate("geminiNano").await())
        assertEquals(ValidationStatus.INVALID, status.state)
        assertEquals("Gemini Nano isn't available on this phone.", status.reason)
        assertFalse("an unrunnable model is never the active one", kit.providers.hasAnyProvider())
    }

    /**
     * Saving a key is not the same as choosing a provider, and the choosing
     * is the kit's: `connect` proves the credential and applies
     * `requestActivation` + `validateAndActivate`. A key nothing else was
     * using takes the slot — and the choice is written down, so the next
     * launch still has it.
     */
    @Test
    fun connectActivatesAKeyThatChecksOut() = runTest(timeout = TEST_TIMEOUT) {
        FakeChatServer().use { server ->
            kit.providers.overrideEndpoint("openAI", server.origin)
            kit.providers.saveAPIKey("openAI", "sk-test-not-a-real-key")
            val status = kitJson.decodeFromString<ValidationStatus>(kit.providers.connect("openAI").await())
            assertEquals(ValidationStatus.ACTIVE, status.state)

            val settings = providerSettings()
            assertEquals("openAI", settings.selection?.kind)
            assertEquals("the reader's own choice, not a default", "openAI", settings.explicitSelection?.kind)
            assertTrue(settings.vendors.single { it.id == "openai" }.kinds.single().isActive)
            assertTrue("an activation the manager made itself is still written down", File(root, "provider-selection.json").isFile)
            assertEquals("openAI", providerSettings(from = reopen()).selection?.kind)
        }
    }

    /**
     * A check that could not complete is not a rejection: the provider was
     * down, not the key wrong, and the kit activates anyway so Ask works
     * again the moment the outage clears.
     */
    @Test
    fun connectActivatesEvenWhenTheCheckCouldNotComplete() = runTest(timeout = TEST_TIMEOUT) {
        FakeChatServer(
            status = 503,
            errorBody = "{\"error\":{\"message\":\"The server is temporarily unavailable.\"}}",
        ).use { server ->
            kit.providers.overrideEndpoint("openAI", server.origin)
            kit.providers.saveAPIKey("openAI", "sk-test-not-a-real-key")
            val status = kitJson.decodeFromString<ValidationStatus>(kit.providers.connect("openAI").await())
            assertEquals(status.state, ValidationStatus.UNAVAILABLE, status.state)
            assertEquals("a provider outage never condemns a key", "openAI", providerSettings().selection?.kind)
            assertTrue(File(root, "provider-selection.json").isFile)
        }
    }

    /** But a key the provider actually rejected never takes the slot from one that works. */
    @Test
    fun aRejectedKeyLeavesTheWorkingProviderInPlace() = runTest(timeout = TEST_TIMEOUT) {
        FakeChatServer().use { working ->
            kit.providers.overrideEndpoint("openAI", working.origin)
            kit.providers.saveAPIKey("openAI", "sk-test-not-a-real-key")
            kit.providers.connect("openAI").await()
            assertEquals("openAI", providerSettings().selection?.kind)
        }
        FakeChatServer(
            status = 401,
            errorBody = "{\"error\":{\"message\":\"Incorrect API key provided.\"}}",
        ).use { rejecting ->
            kit.providers.overrideEndpoint("anthropic", rejecting.origin)
            kit.providers.saveAPIKey("anthropic", "sk-ant-not-a-real-key")
            val status = kitJson.decodeFromString<ValidationStatus>(kit.providers.connect("anthropic").await())
            assertEquals(ValidationStatus.INVALID, status.state)
            assertEquals("openAI", providerSettings().selection?.kind)
        }
    }

    /**
     * Taking away the key of the model Ask was pointed at leaves nothing
     * chosen — here and on disk. A selection naming a card with no credential
     * behind it would say "Ask uses GPT-5.6 — not connected" for ever.
     */
    @Test
    fun disconnectDropsTheSelectionItNamed() = runTest(timeout = TEST_TIMEOUT) {
        FakeChatServer().use { server ->
            kit.providers.overrideEndpoint("openAI", server.origin)
            kit.providers.saveAPIKey("openAI", "sk-test-not-a-real-key")
            kit.providers.connect("openAI").await()
            assertEquals("openAI", providerSettings().selection?.kind)

            kit.providers.disconnect("openAI")
            val after = providerSettings()
            assertNull("the choice goes with the key", after.selection)
            assertNull(after.explicitSelection)
            assertEquals("Ask uses no model yet — connect one below.", after.askUsesLine)
            assertFalse("and it is not waiting on disk for the next launch", File(root, "provider-selection.json").exists())
            assertFalse("nothing to ask with", kit.providers.hasAnyProvider())
        }
    }

    /**
     * The debug endpoint hook points at this device or at nothing. It exists
     * so a test can stream a real answer from a socket it owns; a hook that
     * could send a credentialed request to any host on the internet would not
     * be worth having.
     */
    @Test
    fun anEndpointOverrideOnlyEverPointsAtThisDevice() {
        for (loopback in listOf("http://127.0.0.1:8080", "http://localhost:8080", "http://10.0.2.2:8080")) {
            kit.providers.overrideEndpoint("openAI", loopback)
        }
        kit.providers.overrideEndpoint("openAI", "")

        for (elsewhere in listOf("https://example.com", "http://192.168.1.10:8080", "https://127.0.0.1.evil.test")) {
            try {
                kit.providers.overrideEndpoint("openAI", elsewhere)
                assertTrue("expected $elsewhere to be refused", false)
            } catch (e: Exception) {
                assertEquals("Readr can only be pointed at a server on this device.", e.message)
            }
        }
    }

    /**
     * An answer's shape comes from the kit's own Markdown parser, so a
     * numbered list keeps its numbers rather than being flattened into
     * paragraphs by a smaller parser written on this side.
     */
    @Test
    fun answerBlocksComeFromTheKitsOwnParser() {
        val blocks = AnswerMarkdown.blocks(
            kit.library.answerBlocksJSON("Two things happen:\n\n1. She follows him.\n2. She falls.\n"),
            fallback = "",
        )
        assertEquals(AnswerBlock.Paragraph("Two things happen:"), blocks.first())
        val list = blocks.last() as AnswerBlock.Items
        assertTrue("an ordered list stays ordered", list.ordered)
        assertEquals(listOf("1.", "2."), list.items.map { it.marker })
        assertEquals(listOf("She follows him.", "She falls."), list.items.map { it.text })
    }

    // MARK: Ask (A3b)

    /**
     * A book too long to fit a provider's whole-book budget, so a question
     * about it routes to retrieval and the answer comes back with citable
     * passages. The router's ceiling is 60% of 200,000 tokens at roughly four
     * characters each; this is comfortably past it. Generated rather than
     * bundled — no sample in the repo is that long.
     */
    private suspend fun longBook(paragraphsPerChapter: Int = 140): BookSummary {
        val text = buildString {
            for (chapter in 1..8) {
                append("# Chapter $chapter\n\n")
                for (paragraph in 1..paragraphsPerChapter) append("$chapter.$paragraph $WONDERLAND\n\n")
            }
        }
        val file = File(root, "long.txt").apply { writeText(text) }
        val book = kitJson.decodeFromString<BookSummary>(
            kit.library.importPlainText(file.absolutePath, "Down the Rabbit-Hole").await()
        )
        assertTrue("the test book must not fit the whole-book tier", book.estimatedTokenCount > 120_000)
        return book
    }

    /**
     * A book comfortably inside a provider's whole-book budget, so a question
     * about it rides the whole text along and never asks for a passage.
     */
    private suspend fun shortBook(title: String): BookSummary {
        val file = File(root, "$title.txt").apply {
            writeText("# One\n\n$WONDERLAND\n\n# Two\n\n$WONDERLAND\n")
        }
        val book = kitJson.decodeFromString<BookSummary>(
            kit.library.importPlainText(file.absolutePath, title).await()
        )
        assertTrue("the short fixture must fit the whole-book tier", book.estimatedTokenCount < 120_000)
        return book
    }

    /** A provider pointed at `server`, connected and made active. */
    private fun connect(server: FakeChatServer) {
        kit.providers.overrideEndpoint("openAI", server.origin)
        kit.providers.saveAPIKey("openAI", "sk-test-not-a-real-key")
        kit.providers.setActive("openAI", "gpt-5.6-sol")
    }

    /**
     * The whole path, on a device: context assembled, passages cited, tokens
     * delivered AS THEY ARRIVE, one completion at the end.
     */
    @Test
    fun askStreamsAnAnswerAndCitesTheBook() = runTest(timeout = TEST_TIMEOUT) {
        val book = longBook()
        FakeChatServer().use { server ->
            connect(server)
            val sink = RecordingAskSink()
            val handle = kit.library.ask(
                book.id, "What does Alice follow down the hole?",
                WHOLE_BOOK_SCOPE, "", "", kit.providers, sink,
            )
            assertTrue("an ask that started has a handle to cancel", handle != 0L)
            assertTrue("no answer arrived: $sink", sink.await(RecordingAskSink.COMPLETED))

            assertEquals("one delta per chunk the server sent: $sink", 3, sink.of(RecordingAskSink.TOKEN).size)
            // Streamed, not buffered: the first token was in the reader's
            // hands before the server had finished writing the answer.
            assertTrue(
                "the first token waited for the whole answer",
                sink.of(RecordingAskSink.TOKEN).first().at < server.sentAt[2],
            )
            assertEquals(1, sink.of(RecordingAskSink.COMPLETED).size)
            assertEquals(FakeChatServer.DEFAULT_ANSWER, sink.of(RecordingAskSink.COMPLETED).single().text)
            assertTrue("a completed answer never also fails: $sink", sink.of(RecordingAskSink.FAILED).isEmpty())

            // A book this long cannot ride along whole, so the answer is
            // grounded in retrieved passages — and every one of them says
            // where in the book it came from, in Kotlin's own offsets.
            // The tier crosses the bridge with what it promises, so the sheet
            // never offers a SOURCES row the routing cannot fill.
            val routed = sink.lastTierJSON()
            assertTrue("a routed tier is reported: $routed", routed.contains("\"tier\":\"retrieval\""))
            assertTrue("with the kit's own answer about it: $routed", routed.contains("\"providesCitations\":true"))
            val citations = kitJson.decodeFromString<List<AskCitation>>(
                sink.of(RecordingAskSink.CITATIONS).last().text
            )
            assertTrue("the retrieval tier cites its passages", citations.isNotEmpty())
            for (citation in citations) {
                assertTrue("a citation is labelled: $citation", citation.locator.isNotBlank())
                assertTrue("a citation quotes the book: $citation", citation.quotedText.isNotBlank())
                assertTrue("a retrieved passage knows where it is: $citation", citation.isLocated)
                val chapter = kit.library.chapterText(book.id, citation.chapterIndex!!.toLong())
                val offset = citation.utf16Offset!!
                assertTrue("$citation is outside its chapter (${chapter.length})", offset in 0..<chapter.length)
            }
        }
    }

    /**
     * A rejected key reads as what the provider said, not as a status code —
     * once, and never alongside a completion.
     */
    @Test
    fun askSaysWhatTheProviderSaidWhenTheKeyIsRejected() = runTest(timeout = TEST_TIMEOUT) {
        val book = longBook()
        FakeChatServer(
            status = 401,
            errorBody = "{\"error\":{\"message\":\"Incorrect API key provided.\"}}",
        ).use { server ->
            connect(server)
            val sink = RecordingAskSink()
            kit.library.ask(book.id, "Who is the White Rabbit?", WHOLE_BOOK_SCOPE, "", "", kit.providers, sink)
            assertTrue("no failure arrived: $sink", sink.await(RecordingAskSink.FAILED))

            val failure = sink.of(RecordingAskSink.FAILED).single()
            assertTrue(
                "the reader is told what the provider said: ${failure.text}",
                failure.text.contains("The provider said: Incorrect API key provided."),
            )
            assertTrue("a failure carries a next step", failure.recovery.isNotBlank())
            assertTrue("a failed answer never also completes: $sink", sink.of(RecordingAskSink.COMPLETED).isEmpty())
            for (leak in listOf("HTTPError", "ReadrKit.", "status(", "Optional(")) {
                assertFalse("no Swift internals in \"${failure.text}\"", failure.text.contains(leak))
            }
        }
    }

    /**
     * A cancelled ask goes quiet: the Kotlin side asked for the stop and owns
     * what the panel shows, so neither ending is reported.
     */
    @Test
    fun cancellingAnAskEndsItSilently() = runTest(timeout = TEST_TIMEOUT) {
        val book = longBook()
        FakeChatServer(gapMillis = 1_500).use { server ->
            connect(server)
            val sink = RecordingAskSink()
            val handle = kit.library.ask(book.id, "What is down the hole?", WHOLE_BOOK_SCOPE, "", "", kit.providers, sink)
            assertTrue("nothing streamed to cancel: $sink", sink.await(RecordingAskSink.TOKEN))
            kit.library.cancelAsk(handle)

            // Well past everything the server still had to send — on the real
            // clock, since `runTest`'s virtual one would skip straight past
            // the chunks that must never arrive.
            withContext(Dispatchers.Default) { delay(5.seconds) }
            assertTrue("a cancelled ask must not complete: $sink", sink.of(RecordingAskSink.COMPLETED).isEmpty())
            assertTrue("a cancelled ask is not a failure: $sink", sink.of(RecordingAskSink.FAILED).isEmpty())
        }
    }

    /**
     * A book indexed ahead of time, pushed out of the index cache, and then
     * asked about: it is indexed AGAIN rather than answered from an index
     * nothing filled.
     *
     * The cache holds two books. An index and the build filling it are one
     * entry, so being pushed out takes both; kept apart, the question below
     * would have awaited the evicted book's build — work that fills an index
     * no longer reachable — and then assembled its answer from the empty one
     * that replaced it. An ungrounded answer, with nothing to show that
     * anything went wrong, which is why the citations are what this asserts.
     */
    @Test
    fun aBookPushedOutOfTheIndexCacheIsIndexedAgainRatherThanAwaitingItsStaleBuild() =
        runTest(timeout = 5.minutes) {
            FakeChatServer().use { server ->
                connect(server)
                // Long enough that its index takes a moment to build: the
                // whole point is what happens to a book pushed out WHILE that
                // build is running.
                val long = longBook(paragraphsPerChapter = 400)
                val others = listOf(shortBook("Second"), shortBook("Third"))
                // The build the reader pays for while they are on page one.
                kit.library.prepareAsk(long.id, kit.providers)

                // Two more books asked about is two more entries in a cache
                // that holds two. Short ones, and stopped the moment the
                // router has reported — the cache entry is all this needs,
                // and waiting for two whole answers would let the build the
                // test is racing finish first.
                for (other in others) {
                    val sink = RecordingAskSink()
                    val handle = kit.library.ask(
                        other.id, "What is this about?",
                        WHOLE_BOOK_SCOPE, "", "", kit.providers, sink,
                    )
                    assertTrue("${other.title} never routed: $sink", sink.await(RecordingAskSink.TIER))
                    kit.library.cancelAsk(handle)
                }

                val sink = RecordingAskSink()
                kit.library.ask(
                    long.id, "What does Alice follow down the hole?",
                    WHOLE_BOOK_SCOPE, "", "", kit.providers, sink,
                )
                assertTrue("no answer arrived: $sink", sink.await(RecordingAskSink.COMPLETED, timeout = 5.minutes))
                val citations = kitJson.decodeFromString<List<AskCitation>>(
                    sink.of(RecordingAskSink.CITATIONS).lastOrNull()?.text ?: "[]"
                )
                assertTrue(
                    "the answer was assembled from an index nothing had filled: $sink",
                    citations.isNotEmpty(),
                )
            }
        }

    /**
     * Whether the book is indexed at all follows the routing rule: a text
     * that fits the provider's whole-book budget rides along entire and is
     * never chunked, and one that does not is indexed first and says so.
     *
     * KIT FOLLOW-UP: `AndroidLibrary.routesWholeBook` is a *copy* of
     * `AdaptiveContextStrategy`'s rule, and nothing in the kit fails when the
     * two drift apart — the symptom is an index built for a question that
     * never reads it, or a question answered from an index nobody built. This
     * pins the copy from the outside until the kit exposes the decision.
     *
     * The two fixtures straddle the ceiling (60% of the budget) rather than
     * the providers straddling the book: every provider this build offers —
     * OpenAI, OpenRouter, Anthropic — carries the same 200,000-token router
     * budget, so the book is the only side of that comparison a test on this
     * platform can move.
     */
    @Test
    fun theRoutingRuleDecidesWhetherTheBookIsIndexed() = runTest(timeout = TEST_TIMEOUT) {
        FakeChatServer().use { server ->
            connect(server)
            val short = shortBook("Whole")
            val whole = RecordingAskSink()
            kit.library.ask(
                short.id, "What is this about?", WHOLE_BOOK_SCOPE, "", "", kit.providers, whole,
            )
            assertTrue("no answer arrived: $whole", whole.await(RecordingAskSink.COMPLETED))
            assertTrue(
                "a book that rides along whole routed to retrieval: ${whole.lastTierJSON()}",
                whole.lastTierJSON().contains("\"tier\":\"wholeBook\""),
            )
            assertTrue(
                "a book the router never retrieves from must not be indexed: $whole",
                whole.of(RecordingAskSink.INDEXING).isEmpty(),
            )

            val long = longBook()
            val retrieved = RecordingAskSink()
            kit.library.ask(
                long.id, "What does Alice follow down the hole?",
                WHOLE_BOOK_SCOPE, "", "", kit.providers, retrieved,
            )
            assertTrue("the reader was never told about the wait: $retrieved", retrieved.await(RecordingAskSink.INDEXING))
            assertTrue("no answer arrived: $retrieved", retrieved.await(RecordingAskSink.COMPLETED))
            assertTrue(
                "a book past the budget routed whole: ${retrieved.lastTierJSON()}",
                retrieved.lastTierJSON().contains("\"tier\":\"retrieval\""),
            )
        }
    }

    /** Nothing connected: one sentence, and no stream started. */
    @Test
    fun askWithoutAProviderSaysSoWithoutStarting() = runTest(timeout = TEST_TIMEOUT) {
        val file = File(root, "short.txt").apply { writeText("# One\n\nA short book about nothing much at all.\n") }
        val book = kitJson.decodeFromString<BookSummary>(
            kit.library.importPlainText(file.absolutePath, "Short").await()
        )
        val sink = RecordingAskSink()
        val handle = kit.library.ask(book.id, "What is this about?", WHOLE_BOOK_SCOPE, "", "", kit.providers, sink)
        assertEquals("nothing was started", 0L, handle)
        assertEquals(
            "Connect an AI provider in settings to ask questions.",
            sink.of(RecordingAskSink.FAILED).single().text,
        )
        assertTrue(sink.of(RecordingAskSink.TOKEN).isEmpty())
    }

    /**
     * The caption over a scoped conversation is the kit's own
     * `ReadingPositionSummary`, so the sheet says exactly what the model is
     * told and exactly what the Apple panel shows.
     */
    @Test
    fun theScopeCaptionIsTheKitsOwnLine() = runTest(timeout = TEST_TIMEOUT) {
        val text = buildString {
            for (chapter in 1..4) {
                append("# Chapter $chapter\n\n")
                for (paragraph in 1..6) append("$chapter.$paragraph $WONDERLAND\n\n")
            }
        }
        val file = File(root, "placed.txt").apply { writeText(text) }
        val book = kitJson.decodeFromString<BookSummary>(
            kit.library.importPlainText(file.absolutePath, "Placed").await()
        )
        val start = kitJson.decodeFromString<AskPosition>(kit.library.positionSummaryJSON(book.id, 0, 0))
        assertEquals("Chapter 1 of ${book.chapterCount}", start.chapterLine)
        assertEquals(0, start.percent)
        assertTrue(start.caption, start.caption.startsWith("Chapter 1 of ${book.chapterCount} · 0%"))

        val third = kitJson.decodeFromString<AskPosition>(kit.library.positionSummaryJSON(book.id, 2, 0))
        assertEquals(3, third.chapterNumber)
        assertTrue("progress grows with the place", third.percent > start.percent)
    }

    // MARK: The phone's own model (A3c)

    /**
     * The whole on-device path on a phone that can run the model: the kit's
     * prompt plan, its one-word classifier hop, and cumulative snapshots
     * turned into the deltas the sheet draws.
     *
     * What `SnapshotAnswerStream` promises is what is asserted here — a
     * finished sentence arrives once, whole, and in the order it was written.
     */
    @Test
    fun theOnDeviceModelStreamsSettledSentencesAndCompletesOnce() = runTest(timeout = TEST_TIMEOUT) {
        val book = twoChapterBook()
        val model = FakeOnDeviceModel()
        val nano = reopen(model)
        assertTrue("a ready phone answers with its own model", nano.providers.isActiveOnDevice())

        val sink = RecordingAskSink()
        val handle = nano.library.ask(
            book.id, "What does Alice follow?", WHOLE_BOOK_SCOPE, "", "", nano.providers, sink,
        )
        assertTrue("an ask that started has a handle to cancel", handle != 0L)
        assertTrue("no answer arrived: $sink", sink.await(RecordingAskSink.COMPLETED))

        val streamed = sink.of(RecordingAskSink.TOKEN).joinToString("") { it.text }
        assertEquals("the deltas add up to the answer", streamed, sink.of(RecordingAskSink.COMPLETED).single().text)
        for (sentence in listOf(FakeOnDeviceModel.FIRST_SENTENCE, FakeOnDeviceModel.SECOND_SENTENCE)) {
            assertEquals("\"$sentence\" arrives once in \"$streamed\"", 1, occurrences(streamed, sentence))
        }
        assertTrue(
            "and in the order it was written: $streamed",
            streamed.indexOf(FakeOnDeviceModel.FIRST_SENTENCE) <
                streamed.indexOf(FakeOnDeviceModel.SECOND_SENTENCE),
        )
        assertEquals(1, sink.of(RecordingAskSink.COMPLETED).size)
        assertTrue("a completed answer never also fails: $sink", sink.of(RecordingAskSink.FAILED).isEmpty())

        // The grounding the sheet promises: a passage-retrieval tier, from a
        // model that runs on the phone and knows nothing wider.
        val routed = sink.lastTierJSON()
        assertTrue("a routed tier is reported: $routed", routed.contains("\"tier\":\"retrieval\""))
        val citations = kitJson.decodeFromString<List<AskCitation>>(
            sink.of(RecordingAskSink.CITATIONS).last().text
        )
        assertTrue("the retrieval tier cites its passages", citations.isNotEmpty())

        // The kit's own recipe ran: the classifier's short call went through
        // the same model, and the answer was capped at a few sentences.
        assertTrue(
            "the classifier asked first: ${model.instructions}",
            model.instructions.any { it.startsWith(FakeOnDeviceModel.CLASSIFIER_MARKER) },
        )
        assertTrue("an answer is a paragraph or two: ${model.caps}", model.caps.all { it in 1L..350L })
    }

    /** Cancelling reaches the generation itself, and says nothing more. */
    @Test
    fun cancellingAnOnDeviceAskStopsTheGeneration() = runTest(timeout = TEST_TIMEOUT) {
        val book = twoChapterBook()
        val model = FakeOnDeviceModel(answer = FakeOnDeviceModel.LONG_ANSWER, gapMillis = 250)
        val nano = reopen(model)
        val sink = RecordingAskSink()
        val handle = nano.library.ask(
            book.id, "What happens to Alice?", WHOLE_BOOK_SCOPE, "", "", nano.providers, sink,
        )
        assertTrue("nothing streamed to cancel: $sink", sink.await(RecordingAskSink.TOKEN))
        nano.library.cancelAsk(handle)

        // Real time: `runTest`'s virtual clock would skip straight past the
        // words that must never arrive.
        withContext(Dispatchers.Default) { delay(4.seconds) }
        // The two facts kept apart: the cancel REACHED the model, and it
        // reached it while the model was still writing. A generation that had
        // simply run out of words would satisfy neither.
        assertTrue(
            "cancel never reached the generation",
            model.cancelledWhileGenerating.get(),
        )
        assertEquals("a stopped generation never ends on its own", 0, model.generationsEnded.get())
        assertTrue("a cancelled ask must not complete: $sink", sink.of(RecordingAskSink.COMPLETED).isEmpty())
        assertTrue("a cancelled ask is not a failure: $sink", sink.of(RecordingAskSink.FAILED).isEmpty())
    }

    /**
     * A small model that falls into a loop is cut before its first repeat
     * reaches the reader — the kit's `RepetitionGuard`, reached through the
     * facade rather than reimplemented on this side.
     */
    @Test
    fun aLoopingOnDeviceAnswerIsCutBeforeItRepeats() = runTest(timeout = TEST_TIMEOUT) {
        val book = twoChapterBook()
        val nano = reopen(FakeOnDeviceModel(answer = FakeOnDeviceModel.LOOPING_ANSWER))
        val sink = RecordingAskSink()
        nano.library.ask(book.id, "What does Alice follow?", WHOLE_BOOK_SCOPE, "", "", nano.providers, sink)
        assertTrue("no answer arrived: $sink", sink.await(RecordingAskSink.COMPLETED))

        val answer = sink.of(RecordingAskSink.COMPLETED).single().text
        assertEquals("the reader sees the sentence once: \"$answer\"", 1, occurrences(answer, FakeOnDeviceModel.FIRST_SENTENCE))
        assertTrue("a cut answer is still an answer, not a failure: $sink", sink.of(RecordingAskSink.FAILED).isEmpty())
    }

    /**
     * A question the phone's window cannot hold says so in one sentence —
     * `SmallModelPrompt.DoesNotFit`, in the reader's words.
     */
    @Test
    fun aQuestionTooLongForThePhoneSaysSo() = runTest(timeout = TEST_TIMEOUT) {
        val book = twoChapterBook()
        val nano = reopen(FakeOnDeviceModel())
        val sink = RecordingAskSink()
        nano.library.ask(
            book.id,
            "Why ".repeat(6_000) + "does Alice follow the White Rabbit?",
            WHOLE_BOOK_SCOPE, "", "", nano.providers, sink,
        )
        assertTrue("no failure arrived: $sink", sink.await(RecordingAskSink.FAILED))

        val failure = sink.of(RecordingAskSink.FAILED).single()
        assertEquals(
            "This question needed more of the book than Gemini Nano can hold at once.",
            failure.text,
        )
        assertTrue("a failure carries a next step", failure.recovery.isNotBlank())
        assertTrue("and never also completes: $sink", sink.of(RecordingAskSink.COMPLETED).isEmpty())
        for (leak in listOf("DoesNotFit", "ReadrKit.", "NanoError", "Optional(")) {
            assertFalse("no Swift internals in \"${failure.text}\"", failure.text.contains(leak))
        }
    }

    /**
     * The window the plan is made against is the MODEL's, not the
     * catalogue's assembly budget.
     *
     * `contextBudget` (2,000) says how much of the book
     * `AdaptiveContextStrategy` may gather; it is deliberately smaller than
     * the window, so that what it gathers still leaves room for the
     * conversation, the instructions and the answer. Spent as if it were the
     * window, those things had to come out of it — and a five-turn
     * conversation over a long book was answered from passages
     * `SmallModelPrompt.fit` had trimmed away, or not answered at all.
     *
     * Asked twice, so the difference is the window and nothing else: a phone
     * reporting 4,096 (what Apple's on-device model answers, and the
     * facade's own fallback) against one reporting the assembly budget.
     */
    @Test
    fun theWindowIsThePhonesOwnAndNotTheAssemblyBudget() = runTest(timeout = TEST_TIMEOUT) {
        val book = longBook()
        val turns = fiveAnsweredTurns()

        val phone = FakeOnDeviceModel()
        assertEquals("the fake states a phone's real window", 4_096L, phone.windowTokens())
        val answered = askOnDevice(book, turns, phone)
        assertTrue("a five-turn conversation must fit a real window: $answered", answered.of(RecordingAskSink.FAILED).isEmpty())
        assertTrue("no answer arrived: $answered", answered.of(RecordingAskSink.COMPLETED).isNotEmpty())
        val whole = phone.answerPrompts.single()

        // The same ask on a phone that reports the assembly budget as its
        // window: this is the bug, kept where it can be seen.
        val squeezed = FakeOnDeviceModel(window = ASSEMBLY_BUDGET_TOKENS)
        askOnDevice(book, turns, squeezed)
        val cut = squeezed.answerPrompts.firstOrNull()
        assertTrue(
            "the assembly budget as a window left the passages alone " +
                "(${whole.length} characters, cut to ${cut?.length})",
            cut == null || cut.length < whole.length,
        )
    }

    /** One on-device ask, run to its ending on a kit of its own. */
    private suspend fun askOnDevice(
        book: BookSummary,
        historyJSON: String,
        model: FakeOnDeviceModel,
    ): RecordingAskSink {
        val nano = reopen(model)
        val sink = RecordingAskSink()
        nano.library.ask(
            book.id, "What does Alice find at the bottom?",
            WHOLE_BOOK_SCOPE, "", historyJSON, nano.providers, sink,
        )
        assertTrue(
            "neither an answer nor a failure arrived: $sink",
            sink.await(RecordingAskSink.COMPLETED) || sink.of(RecordingAskSink.FAILED).isNotEmpty(),
        )
        return sink
    }

    /**
     * Five answered turns, as the sheet keeps them — enough conversation that
     * the passages and the history together need more than the assembly
     * budget, which is exactly the shape the bug showed up in.
     */
    private fun fiveAnsweredTurns(): String = (1..5).joinToString(",", "[", "]") { turn ->
        """{"question":"What happens in part $turn?",""" +
            """"answerText":"$WONDERLAND","tier":"retrieval","scoped":false}"""
    }

    private fun occurrences(text: String, part: String): Int {
        var count = 0
        var index = text.indexOf(part)
        while (index >= 0) {
            count++
            index = text.indexOf(part, index + part.length)
        }
        return count
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

    // MARK: Listen — the kit's narration over a synthesizer that only moves
    // when a test says so, driven through the real facade.

    /**
     * The book every narration test reads: three chapters of three plain
     * sentences, so a segment can be named by the words it starts with and
     * checked against the chapter text it came out of.
     */
    private suspend fun narrationBook(): BookSummary {
        val text = buildString {
            for (chapter in 1..3) {
                append("# Chapter $chapter\n\n")
                append("Alpha $chapter is the first sentence here. ")
                append("Beta $chapter is the second sentence here. ")
                append("Gamma $chapter is the third sentence here.\n\n")
            }
        }
        val file = File(root, "narration.txt").apply { writeText(text) }
        return kitJson.decodeFromString(
            kit.library.importPlainText(file.absolutePath, "Narrated").await()
        )
    }

    /** The facade, its fake synthesizer and its observer. */
    private class Session(
        val narration: AndroidNarration,
        val backend: FakeSpeechBackend,
        val observer: RecordingNarrationObserver,
    ) {
        fun state(): NarrationState = kitJson.decodeFromString(onMain { narration.stateJSON() })
    }

    /**
     * A listening session, built on the main thread — where the controller
     * lives and where every call into it has to be made.
     */
    private fun session(
        bookId: String,
        settings: String = """{"rate":1.0}""",
        deviceLocale: String = "en-US",
    ): Session = onMain {
        val arena = SwiftArena.ofAuto()
        val events = NarrationEvents.init(arena)
        val backend = FakeSpeechBackend(events)
        val observer = RecordingNarrationObserver()
        Session(
            AndroidNarration.init(
                kit.library, bookId, backend, events, observer, settings, deviceLocale, arena
            ),
            backend,
            observer,
        )
    }

    /**
     * Listen begins at the first sentence that *starts* at or after the page's
     * anchor: the sentence straddling the page break began on the page before,
     * and reading it would drag the page backwards to follow the voice. A
     * selection means the sentence the reader's finger is in — the page rule
     * would skip the very words they pointed at.
     */
    @Test
    fun listenStartsAtTheFirstSentenceOfThePage() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val inside = chapter.indexOf("is the second")

        val page = session(book.id)
        onMain { page.narration.start(0, inside.toLong(), "nextSentenceStart") }
        assertTrue(
            page.backend.lastText.orEmpty(),
            page.backend.lastText.orEmpty().startsWith("Gamma 1"),
        )
        assertEquals("speaking", page.state().status)

        val selected = session(book.id)
        onMain { selected.narration.start(0, inside.toLong(), "sentenceContaining") }
        assertTrue(
            selected.backend.lastText.orEmpty(),
            selected.backend.lastText.orEmpty().startsWith("Beta 1"),
        )
    }

    /** A sentence spoken through moves the book on, and the card is told. */
    @Test
    fun finishingASentenceAdvancesTheBook() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val session = session(book.id)
        onMain { session.narration.start(0, chapter.indexOf("Alpha 1").toLong(), "sentenceContaining") }
        assertTrue(session.backend.lastText.orEmpty().startsWith("Alpha 1"))

        onMain { session.backend.finishCurrent() }
        assertTrue(
            session.backend.lastText.orEmpty(),
            session.backend.lastText.orEmpty().startsWith("Beta 1"),
        )
        val state = session.state()
        assertTrue(state.sentence, state.sentence.startsWith("Beta 1"))
        assertEquals(chapter.indexOf("Beta 1"), state.utf16SentenceStart)
        assertTrue(
            "the observer heard the new sentence: ${session.observer.sentences}",
            session.observer.sentences.any { it.startsWith("Beta 1") },
        )
    }

    /**
     * Word boundaries come back as chapter ranges, not offsets into the
     * utterance: the page, the highlights and Ask all address the chapter.
     */
    @Test
    fun wordBoundariesArriveAsChapterRanges() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val start = chapter.indexOf("Beta 1")
        val session = session(book.id)
        onMain { session.narration.start(0, start.toLong(), "sentenceContaining") }
        val sentence = session.backend.lastText.orEmpty()
        val word = sentence.indexOf("second")
        onMain { session.backend.speakWord(word, word + "second".length) }

        val reported = session.observer.spoken.last()
        assertEquals(0, reported.chapterIndex)
        assertEquals(start + word, reported.utf16Start)
        assertEquals("second", chapter.substring(reported.utf16Start, reported.utf16End))
    }

    /**
     * A pause the reader asked for is not a hold: the card shows the sentence,
     * not an explanation. (A hold is the engine setting the sentence down.)
     */
    @Test
    fun pauseCarriesNoHoldReason() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val session = session(book.id)
        onMain { session.narration.start(0, 0, "nextSentenceStart") }
        onMain { session.narration.pause() }
        val state = session.state()
        assertEquals("paused", state.status)
        assertNull(state.holdReason)
        assertNull(state.holdText)
        // The backend is stopped, not paused: Android's synthesizer has no
        // pause, so the kit takes the sentence off it and re-speaks the rest.
        assertEquals("idle", onMain { session.backend.state() })
    }

    /**
     * And that is what a pause and a play actually are here: the utterance is
     * stopped, and playing again speaks the **remainder** of the sentence from
     * the last word boundary — under a new request id, since it is a new
     * utterance. The rule is the kit's (`pausesInPlace`); this is the proof it
     * reaches the phone's engine intact.
     */
    @Test
    fun playingAfterAPauseRespeaksTheRemainderOfTheSentence() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val session = session(book.id)
        onMain { session.narration.start(0, chapter.indexOf("Beta 1").toLong(), "sentenceContaining") }
        val sentence = session.backend.lastText.orEmpty()
        val word = sentence.indexOf("second")
        onMain { session.backend.speakWord(word, word + "second".length) }

        val stopsBefore = session.backend.stops
        onMain { session.narration.pause() }
        assertEquals("paused", session.state().status)
        assertEquals("the utterance was taken off the engine", stopsBefore + 1, session.backend.stops)

        onMain { session.narration.play() }
        assertEquals("speaking", session.state().status)
        assertEquals(
            "the rest of the sentence, from the word the voice reached",
            sentence.substring(word),
            session.backend.lastText,
        )
    }

    /**
     * A phone whose synthesizer will not start: every sentence is refused. The
     * card has to say so — a Pause nobody pressed, with the sentence still on
     * it, reads as the app having quietly given up — and nothing may park
     * waiting for an engine that is never coming.
     */
    @Test
    fun aVoiceThatRefusesTheSentenceHoldsWithAnExplanation() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val session = session(book.id)
        session.backend.refusesEverySentence = true

        onMain { session.narration.start(0, 0, "nextSentenceStart") }
        val held = session.state()
        assertEquals("paused", held.status)
        assertEquals("engineFailed", held.holdReason)
        assertTrue(held.holdText.orEmpty(), held.holdText.orEmpty().isNotEmpty())
        assertTrue(
            "the card was told: ${session.observer.holds}",
            session.observer.holds.any { it.isNotEmpty() },
        )
        // Nothing is pending on an engine that will not speak.
        assertEquals("idle", onMain { session.backend.state() })

        session.backend.refusesEverySentence = false
        onMain { session.narration.play() }
        val playing = session.state()
        assertEquals("speaking", playing.status)
        assertNull("the explanation goes with the failure", playing.holdText)
    }

    /**
     * The phone cannot say which voices it has until its engine has started
     * up, and that is after the session is built. So the choice is made when
     * the reader first asks for a voice, not once in `init` against an empty
     * list — which is what used to happen, and read every book in whatever
     * the device's default was.
     */
    @Test
    fun theVoiceIsChosenOnceThePhoneSaysWhichItHas() = runTest(timeout = TEST_TIMEOUT) {
        val book = aliceBook()
        val session = session(book.id)
        assertEquals(
            "nothing installed yet",
            """{"ready":true,"voices":[]}""",
            onMain { session.backend.voicesJSON() },
        )

        session.backend.voices = FRENCH_DEFAULT_AND_ENGLISH
        onMain { session.narration.start(0, 0, "nextSentenceStart") }

        // Alice declares `dc:language` en, so the English voice reads it —
        // not the engine's own default, which here is the French one.
        assertEquals("en-us-x-tpf#female_1-local", session.backend.spoken.last().voiceID)
        assertEquals("en-us-x-tpf#female_1-local", session.state().voiceID)
    }

    /**
     * The picker's recommendation and the reading voice are one answer.
     *
     * A book that declares no language used to be two: the picker grouped by
     * the reader's own locale and marked a row "Recommended", while narration
     * left the choice to the engine's default — so on a phone whose default is
     * French, a plain-text file was listed under English and then read in
     * French, with a tick nowhere near the row the sheet was recommending.
     */
    @Test
    fun anUntaggedBookIsReadInTheVoiceThePickerRecommends() = runTest(timeout = TEST_TIMEOUT) {
        // Plain text declares no `dc:language` at all.
        val book = narrationBook()
        val session = session(book.id, deviceLocale = "en-US")
        session.backend.voices = FRENCH_DEFAULT_AND_ENGLISH

        onMain { session.narration.start(0, 0, "nextSentenceStart") }

        val picker = kitJson.decodeFromString<NarrationVoices>(
            onMain { session.narration.voicesJSON() }
        )
        assertEquals(
            "the phone's language is the guess, not its default voice",
            "en-us-x-tpf#female_1-local",
            picker.recommendedID,
        )
        assertEquals("and it is the voice reading", picker.recommendedID, session.backend.spoken.last().voiceID)
        assertEquals(picker.recommendedID, session.state().voiceID)
    }

    /** And the guess is the *device's* language, not Foundation's idea of it. */
    @Test
    fun theRecommendedVoiceFollowsTheDeviceLanguage() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val session = session(book.id, deviceLocale = "fr-FR")
        session.backend.voices = FRENCH_DEFAULT_AND_ENGLISH

        onMain { session.narration.start(0, 0, "nextSentenceStart") }

        val picker = kitJson.decodeFromString<NarrationVoices>(
            onMain { session.narration.voicesJSON() }
        )
        assertEquals("fr-fr-x-vlf#female_1-local", picker.recommendedID)
        assertEquals("fr-fr-x-vlf#female_1-local", session.backend.spoken.last().voiceID)
    }

    /**
     * The picker's whole payload is the facade's, over the kit's
     * `VoiceSelector`: the book's own language first in the kit's order,
     * everything else behind the disclosure, and the recommendation marked.
     */
    @Test
    fun voicesJSONGroupsByTheBooksLanguageAndMarksTheRecommendation() = runTest(timeout = TEST_TIMEOUT) {
        val book = aliceBook()
        val session = session(book.id, deviceLocale = "fr-FR")
        session.backend.voices = """[
          {"id":"fr-fr-x-vlf#female_1-local","name":"French","language":"fr-FR","quality":"standard","isDefault":true},
          {"id":"en-us-x-tpf#female_1-local","name":"American","language":"en-US","quality":"enhanced","isDefault":false},
          {"id":"en-gb-x-rjs#male_1-local","name":"British","language":"en-GB","quality":"standard","isDefault":false}
        ]"""

        val picker = kitJson.decodeFromString<NarrationVoices>(
            onMain { session.narration.voicesJSON() }
        )
        assertEquals(
            "Alice declares en, so the device's French is not the grouping",
            listOf("en-us-x-tpf#female_1-local", "en-gb-x-rjs#male_1-local"),
            picker.voices.map { it.id },
        )
        assertEquals(listOf("fr-fr-x-vlf#female_1-local"), picker.otherVoices.map { it.id })
        assertEquals("en-us-x-tpf#female_1-local", picker.recommendedID)
        assertTrue(picker.voices.first { it.id == picker.recommendedID }.isRecommended)
        assertFalse("an answer, not a wait", picker.looking)
        assertEquals("and nothing is missing, so nothing says so", "", picker.emptyText)
    }

    /**
     * "Not started up yet" and "this phone has none" are different answers,
     * and the picker shows different sentences for them. Both are the
     * facade's; Kotlin reports the fact and words neither.
     */
    @Test
    fun voicesJSONTellsAWaitApartFromAnEmptyPhone() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val session = session(book.id)
        session.backend.voicesReady = false

        val looking = kitJson.decodeFromString<NarrationVoices>(
            onMain { session.narration.voicesJSON() }
        )
        assertTrue(looking.isEmpty)
        assertTrue("still looking", looking.looking)
        assertTrue(looking.lookingText, looking.lookingText.isNotBlank())
        assertEquals("and nothing claims the phone has none", "", looking.emptyText)
        assertEquals(looking.lookingText, looking.absentText)

        session.backend.voicesReady = true
        val empty = kitJson.decodeFromString<NarrationVoices>(
            onMain { session.narration.voicesJSON() }
        )
        assertFalse(empty.looking)
        assertTrue(empty.emptyText, empty.emptyText.isNotBlank())
        assertEquals(empty.emptyText, empty.absentText)
    }

    /**
     * What the media session publishes: the book, who wrote it, and the
     * chapters the kit will actually read — each carrying its own index in the
     * book, since the ones it skips are not rows.
     */
    @Test
    fun nowPlayingJSONReportsTheBookItsAuthorAndItsChapters() = runTest(timeout = TEST_TIMEOUT) {
        val book = aliceBook()
        val session = session(book.id)

        val now = kitJson.decodeFromString<NarrationNowPlaying>(
            onMain { session.narration.nowPlayingJSON() }
        )
        assertEquals("Alice's Adventures in Wonderland", now.title)
        assertTrue(now.authors, now.authors.isNotBlank())
        assertEquals("every chapter of Alice is prose", 12, now.chapters.size)
        assertEquals((0 until 12).toList(), now.chapters.map { it.index })
        assertTrue(now.chapters[0].title, now.chapters[0].title.contains("Rabbit-Hole"))
        // Not a line of the book anywhere in it — the notification is not a
        // private surface, and the sentence being read stays on the card.
        assertFalse(now.chapters.any { it.title.contains("Alice was beginning") })
    }

    /**
     * The system taking the audio crosses the bridge as a *hold*, not a
     * failure: the kit stops narration by its own rules, keeps the word the
     * voice reached, and publishes a reason the card and the notification can
     * explain. Playing again re-speaks the remainder and clears it.
     */
    @Test
    fun anAudioInterruptionCrossesAsAHoldWithItsReason() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val session = session(book.id)
        onMain { session.narration.start(0, chapter.indexOf("Beta 1").toLong(), "sentenceContaining") }
        val sentence = session.backend.lastText.orEmpty()
        val word = sentence.indexOf("second")
        onMain { session.backend.speakWord(word, word + "second".length) }

        onMain { session.backend.interrupt() }

        val held = session.state()
        assertEquals("paused", held.status)
        assertEquals("audioInterrupted", held.holdReason)
        assertTrue(held.holdText.orEmpty(), held.holdText.orEmpty().isNotEmpty())
        assertTrue(
            "the card was told: ${session.observer.holds}",
            session.observer.holds.any { it == "audioInterrupted" },
        )
        assertEquals("nothing is on the engine", "idle", onMain { session.backend.state() })

        onMain { session.narration.play() }
        val playing = session.state()
        assertEquals("speaking", playing.status)
        assertNull("the hold is over", playing.holdReason)
        assertNull(playing.holdText)
        assertEquals(
            "and the rest of the sentence is re-spoken, from the word the voice reached",
            sentence.substring(word),
            session.backend.lastText,
        )
    }

    /** Skipping a chapter lands on the first sentence of the next linear one. */
    @Test
    fun skippingAChapterLandsOnTheNextOne() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val session = session(book.id)
        onMain { session.narration.start(0, 0, "nextSentenceStart") }
        onMain { session.narration.skipToNextChapter() }
        val state = session.state()
        assertEquals(1, state.chapterIndex)
        assertEquals("the chapter's first sentence", 0, state.utf16SentenceStart)
        assertTrue(state.sentence, state.sentence.startsWith("Alpha 2"))
        assertTrue(
            session.backend.lastText.orEmpty(),
            session.backend.lastText.orEmpty().startsWith("Alpha 2"),
        )
    }

    /**
     * "End of chapter" stops where the chapter does — paused, with the place
     * kept, so pressing play reads on rather than starting the book again.
     */
    @Test
    fun sleepAtTheEndOfAChapterStopsThere() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val session = session(book.id)
        onMain { session.narration.start(0, chapter.indexOf("Gamma 1").toLong(), "sentenceContaining") }
        onMain { session.narration.setSleepTimer("""{"mode":"endOfChapter"}""") }
        assertEquals("endOfChapter", session.state().sleepTimer.mode)

        val before = session.backend.spoken.size
        onMain { session.backend.finishCurrent() }
        val state = session.state()
        assertEquals("paused", state.status)
        assertEquals("nothing new was spoken", before, session.backend.spoken.size)
        assertEquals("the timer disarmed itself", "off", state.sleepTimer.mode)
        assertTrue("the place is kept", state.sentence.isNotEmpty())
    }

    /**
     * The reader's speed reaches the engine on the *platform's* scale. Android
     * documents that scale as proportional, and the facade's calibration is
     * what makes the kit's AVFoundation-shaped curve come back out straight
     * here — a 1.5× label really is a 1.5× rate.
     */
    @Test
    fun speedReachesTheEngineOnItsOwnScale() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val session = session(book.id)
        onMain { session.narration.start(0, 0, "nextSentenceStart") }
        assertEquals(1.0, session.backend.spoken.last().rate, 0.01)

        onMain { session.narration.setRate(1.5) }
        assertEquals(1.5, session.backend.spoken.last().rate, 0.01)
        onMain { session.narration.setRate(0.75) }
        assertEquals(0.75, session.backend.spoken.last().rate, 0.01)
        assertEquals(0.75, session.state().rate, 0.001)
    }

    /** What Ask quotes when it is opened with no selection while the voice reads. */
    @Test
    fun theSentenceBeingReadCrossesAsAChapterRange() = runTest(timeout = TEST_TIMEOUT) {
        val book = narrationBook()
        val chapter = kit.library.chapterText(book.id, 0)
        val start = chapter.indexOf("Beta 1")
        val session = session(book.id)
        assertEquals("", onMain { session.narration.currentSentenceRangeJSON() })

        onMain { session.narration.start(0, start.toLong(), "sentenceContaining") }
        val range = kitJson.decodeFromString<NarrationSentence>(
            onMain { session.narration.currentSentenceRangeJSON() }
        )
        assertEquals(0, range.chapterIndex)
        assertEquals(start, range.utf16Start)
        assertTrue(chapter.substring(range.utf16Start, range.utf16End).startsWith("Beta 1"))
    }
}

/**
 * Runs `body` on the main thread and hands its answer back.
 *
 * `NarrationController` is main-thread-confined — the reader's whole listening
 * session is built and driven from the main looper — so a test that drove it
 * from the instrumentation thread would be testing something the app never
 * does.
 */
internal fun <T> onMain(body: () -> T): T {
    val held = arrayOfNulls<Any>(1)
    InstrumentationRegistry.getInstrumentation().runOnMainSync { held[0] = body() }
    @Suppress("UNCHECKED_CAST")
    return held[0] as T
}
