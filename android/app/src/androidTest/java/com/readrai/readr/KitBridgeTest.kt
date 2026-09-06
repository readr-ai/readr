package com.readrai.readr

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.EpubExtractor
import com.readrai.readr.data.ReadingPosition
import com.readrai.readr.data.kitJson
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import java.io.File
import kotlinx.coroutines.future.await
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        assertTrue(kit.description.startsWith("ReadrKit on"))
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
        assertEquals(ReadingPosition(0, 12), kitJson.decodeFromString<ReadingPosition>(kit.library.positionJSON(book.id)))

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
        val chapters = kitJson.decodeFromString<List<ChapterSummary>>(kit.library.chaptersJSON(book.id))
        assertEquals(12, chapters.size)
        assertTrue(chapters[0].title.contains("Rabbit-Hole"))
        assertTrue(kit.library.chapterText(book.id, 0).contains("Alice was beginning to get very tired"))
    }

    @Test
    fun seedsTheSampleOnce() = runTest {
        val original = File(root, "alice.epub")
        context.assets.open("alice-in-wonderland.epub").use { i -> original.outputStream().use { i.copyTo(it) } }
        val extracted = File(root, "alice")
        EpubExtractor.extract(original.inputStream(), extracted)
        val first = kit.library.seedSampleIfNeeded(extracted.absolutePath, original.absolutePath).await()
        assertTrue(first.contains("Alice"))
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
            assertTrue(e.message, e.message!!.contains("escapes") || e.message!!.contains("malformed"))
        }
    }
}
