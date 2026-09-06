package com.readrai.readr.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.readrai.readr.kit.Kit
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.future.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The shelf: what ReadrKit's `FileLibraryStore` holds, as the UI sees it. */
class LibraryRepository(private val context: Context, private val kit: Kit) {
    private val _books = MutableStateFlow<List<BookSummary>>(emptyList())
    val books: StateFlow<List<BookSummary>> = _books.asStateFlow()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val staging: File get() = File(context.cacheDir, "import").apply { mkdirs() }

    suspend fun refresh() = withContext(Dispatchers.IO) {
        _books.value = kitJson.decodeFromString<List<BookSummary>>(kit.library.booksJSON())
    }

    /** The shelf entry for a book; loads the shelf first when the process was restored straight into a reader. */
    suspend fun book(id: String): BookSummary? {
        if (_books.value.isEmpty()) refresh()
        return _books.value.firstOrNull { it.id == id }
    }

    /** First launch: the bundled sample book, as on iOS. Nothing is staged unless the kit says a seed is due. */
    suspend fun seedSampleIfNeeded() = withContext(Dispatchers.IO) {
        if (!kit.library.needsSampleSeed()) return@withContext
        val original = File(staging, "sample.epub")
        val extracted = File(staging, "sample")
        try {
            context.assets.open(SAMPLE_ASSET).use { input -> original.outputStream().use { input.copyTo(it) } }
            EpubExtractor.extract(original.inputStream(), extracted)
            kit.library.seedSampleIfNeeded(extracted.absolutePath, original.absolutePath).await()
        } finally {
            extracted.deleteRecursively(); original.delete()
        }
        refresh()
    }

    /** Import a document the reader picked with the system file picker. */
    suspend fun import(uri: Uri): BookSummary = withContext(Dispatchers.IO) {
        val displayName = displayName(uri)
        val title = displayName.substringBeforeLast('.').ifBlank { "Untitled" }
        val stagedName = safeFileName(displayName)
        val original = File(staging, "import-${System.nanoTime()}-$stagedName")
        context.contentResolver.openInputStream(uri)?.use { input -> original.outputStream().use { input.copyTo(it) } }
            ?: throw ImportFailed("Readr couldn't read that file.")
        val json = try {
            if (displayName.lowercase().endsWith(".epub") || isZip(original)) {
                val extracted = File(staging, original.name + ".d")
                try {
                    EpubExtractor.extract(original.inputStream(), extracted)
                    kit.library.importEPUB(extracted.absolutePath, original.absolutePath, title).await()
                } finally { extracted.deleteRecursively() }
            } else {
                kit.library.importPlainText(original.absolutePath, title).await()
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

    /** Fire-and-forget position save from UI callbacks; failures are logged, never shown. */
    fun savePositionLater(bookId: String, chapterIndex: Int, characterOffset: Int) {
        scope.launch {
            try { savePosition(bookId, chapterIndex, characterOffset) } catch (e: Exception) { Log.w(TAG, "position save failed: ${e.message}") }
        }
    }

    suspend fun remove(bookId: String) = withContext(Dispatchers.IO) {
        kit.library.removeBook(bookId)
        refresh()
    }

    class ImportFailed(message: String) : Exception(message)

    private fun displayName(uri: Uri): String =
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment?.substringAfterLast('/')?.substringAfterLast(':') ?: "book"

    private fun isZip(file: File): Boolean = file.inputStream().use { s ->
        val h = ByteArray(4); s.read(h) == 4 && h[0] == 0x50.toByte() && h[1] == 0x4B.toByte()
    }

    companion object {
        const val SAMPLE_ASSET = "alice-in-wonderland.epub"
        private const val TAG = "Readr.Library"

        /**
         * A provider-supplied display name is untrusted: keep only a safe
         * basename (no separators, no traversal, bounded length) for the
         * staging file. The title shown to the reader is derived separately.
         */
        fun safeFileName(displayName: String): String {
            val base = displayName.substringAfterLast('/').substringAfterLast('\\').substringAfterLast(':')
            val cleaned = base.replace(Regex("[^A-Za-z0-9._ -]"), "_").trim().trimStart('.').take(80)
            return cleaned.ifBlank { "book" }
        }
    }
}
