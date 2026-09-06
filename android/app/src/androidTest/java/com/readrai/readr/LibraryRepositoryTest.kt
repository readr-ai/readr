package com.readrai.readr

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.kit.KeystoreSecretStore
import com.readrai.readr.kit.Kit
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** The import path a reader actually takes: a picker URI in, a book on the shelf out. */
@RunWith(AndroidJUnit4::class)
class LibraryRepositoryTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File
    private lateinit var repository: LibraryRepository

    @Before
    fun setUp() {
        root = File(context.cacheDir, "repo-test-${System.nanoTime()}").apply { mkdirs() }
        repository = LibraryRepository(context, Kit.open(root, KeystoreSecretStore(context, alias = "readr.secrets.test")))
    }

    @After
    fun tearDown() { root.deleteRecursively() }

    @Test
    fun safeFileNamesNeverEscapeTheStagingDirectory() {
        assertEquals("secrets.xml", LibraryRepository.safeFileName("../../shared_prefs/secrets.xml"))
        assertEquals("book.epub", LibraryRepository.safeFileName("primary:Download/book.epub"))
        assertEquals("100_ Pure.epub", LibraryRepository.safeFileName("100% Pure.epub"))
        assertEquals("book", LibraryRepository.safeFileName("///"))
        assertEquals(80, LibraryRepository.safeFileName("x".repeat(500)).length)
    }

    @Test
    fun importsAPlainTextFileWithAnAwkwardName() = runTest {
        val file = File(root, "100% Pure & Simple.txt").apply { writeText("Chapter one\n\nIt was a bright cold day in April.") }
        val book = repository.import(Uri.fromFile(file))
        assertEquals("100% Pure & Simple", book.title)
        assertEquals(listOf(book.id), repository.books.value.map { it.id })
        assertTrue(File(root, "Books").listFiles()!!.any { it.name.endsWith(".txt") })
        assertTrue("staging is cleaned up", File(context.cacheDir, "import").listFiles().orEmpty().none { it.name.contains("Pure") })
    }

    @Test
    fun importsTheBundledEpubThroughThePickerPath() = runTest {
        val file = File(root, "alice.epub")
        context.assets.open("alice-in-wonderland.epub").use { i -> file.outputStream().use { i.copyTo(it) } }
        val book = repository.import(Uri.fromFile(file))
        assertEquals("Alice's Adventures in Wonderland", book.title)
        assertEquals(12, repository.chapters(book.id).size)
        assertEquals(null, repository.position(book.id))
        repository.savePosition(book.id, 3, 0)
        assertEquals(3, repository.position(book.id)?.chapterIndex)
    }

    @Test
    fun rejectsANonArchiveNamedEpubWithReaderFacingText() = runTest {
        // Not a zip at all: ZipInputStream yields no entries, the kit sees an
        // empty container and answers with its reader-facing sentence.
        val file = File(root, "notreally.epub").apply { writeText("this is not a zip") }
        try {
            repository.import(Uri.fromFile(file))
            assertTrue("expected rejection", false)
        } catch (e: Exception) {
            val message = e.message ?: ""
            assertFalse("no filename in reader-facing text", message.contains("notreally"))
            assertTrue(message, message.startsWith("This file seems to be damaged"))
        }
        assertTrue(repository.books.value.isEmpty())
    }

    @Test
    fun seedsOnlyWhenTheKitAsksForIt() = runTest {
        repository.seedSampleIfNeeded()
        assertEquals(1, repository.books.value.size)
        repository.seedSampleIfNeeded()
        assertEquals(1, repository.books.value.size)
    }
}
