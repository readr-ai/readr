package com.readrai.readr.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.readrai.readr.kit.Kit
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext

/** The shelf: what ReadrKit's `FileLibraryStore` holds, as the UI sees it. */
class LibraryRepository(private val context: Context, private val kit: Kit) {
    private val _books = MutableStateFlow<List<BookSummary>>(emptyList())
    val books: StateFlow<List<BookSummary>> = _books.asStateFlow()

    private val staging: File get() = File(context.cacheDir, "import").apply { mkdirs() }

    suspend fun refresh() = withContext(Dispatchers.IO) {
        _books.value = kitJson.decodeFromString<List<BookSummary>>(kit.library.booksJSON())
    }

    /** First launch: the bundled sample book, as on iOS. */
    suspend fun seedSampleIfNeeded() = withContext(Dispatchers.IO) {
        val original = File(staging, "sample.epub")
        context.assets.open(SAMPLE_ASSET).use { input -> original.outputStream().use { input.copyTo(it) } }
        val extracted = File(staging, "sample")
        EpubExtractor.extract(original.inputStream(), extracted)
        kit.library.seedSampleIfNeeded(extracted.absolutePath, original.absolutePath).await()
        extracted.deleteRecursively(); original.delete()
        refresh()
    }

    /** Import a document the reader picked with the system file picker. */
    suspend fun import(uri: Uri): BookSummary = withContext(Dispatchers.IO) {
        val name = displayName(uri) ?: "book"
        val original = File(staging, "import-${System.nanoTime()}-$name")
        context.contentResolver.openInputStream(uri)?.use { input -> original.outputStream().use { input.copyTo(it) } }
            ?: throw IllegalStateException("could not open $uri")
        val json = try {
            if (name.lowercase().endsWith(".epub") || isZip(original)) {
                val extracted = File(staging, original.name + ".d")
                try {
                    EpubExtractor.extract(original.inputStream(), extracted)
                    kit.library.importEPUB(extracted.absolutePath, original.absolutePath, name.substringBeforeLast('.')).await()
                } finally { extracted.deleteRecursively() }
            } else {
                kit.library.importPlainText(original.absolutePath, name.substringBeforeLast('.')).await()
            }
        } finally { original.delete() }
        refresh()
        kitJson.decodeFromString<BookSummary>(json)
    }

    suspend fun chapters(bookId: String): List<ChapterSummary> = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.chaptersJSON(bookId))
    }

    suspend fun chapterText(bookId: String, index: Int): String = withContext(Dispatchers.IO) {
        kit.library.chapterText(bookId, index.toLong())
    }

    suspend fun position(bookId: String): ReadingPosition? = withContext(Dispatchers.IO) {
        kit.library.positionJSON(bookId).takeIf { it.isNotEmpty() }?.let { kitJson.decodeFromString<ReadingPosition>(it) }
    }

    suspend fun savePosition(bookId: String, chapterIndex: Int, characterOffset: Int) = withContext(Dispatchers.IO) {
        kit.library.savePosition(bookId, chapterIndex.toLong(), characterOffset.toLong())
    }

    suspend fun remove(bookId: String) = withContext(Dispatchers.IO) {
        kit.library.removeBook(bookId)
        refresh()
    }

    private fun displayName(uri: Uri): String? =
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: uri.lastPathSegment

    private fun isZip(file: File): Boolean = file.inputStream().use { s ->
        val h = ByteArray(4); s.read(h) == 4 && h[0] == 0x50.toByte() && h[1] == 0x4B.toByte()
    }

    companion object { const val SAMPLE_ASSET = "alice-in-wonderland.epub" }
}
