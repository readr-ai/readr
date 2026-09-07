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

    /** Format spans, anchors and linearity for a chapter; offsets in UTF-16. */
    suspend fun chapterLayout(bookId: String, index: Int): ChapterLayout = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.chapterLayoutJSON(bookId, index.toLong()))
    }

    /** The chapter's inline images, in reading order; offsets in UTF-16. */
    suspend fun chapterImages(bookId: String, index: Int): List<ChapterImage> = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.chapterImagesJSON(bookId, index.toLong()))
    }

    /** The chapter's lifted footnotes — empty for most books. */
    suspend fun chapterFootnotes(bookId: String, index: Int): List<Footnote> = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.chapterFootnotesJSON(bookId, index.toLong()))
    }

    /**
     * The book's retained original, where an inline image's bytes live. Null
     * for a book with no archive behind it (plain text) or one whose original
     * has gone — the reader draws alt text rather than failing to open. The
     * path is the facade's, existence-checked there; nothing here knows how
     * the library lays its directories out.
     */
    suspend fun archive(bookId: String): File? {
        val path = book(bookId)?.archivePath ?: return null
        return withContext(Dispatchers.IO) { File(path).takeIf { it.isFile } }
    }

    /**
     * The UTF-16 offset a link's fragment names in a chapter, or null when
     * that chapter lifts no such anchor. One question, one answer: reading it
     * out of [chapterLayout] would ship every format span in the document
     * across the bridge to resolve a single id.
     */
    suspend fun anchorOffset(bookId: String, index: Int, fragment: String): Int? = withContext(Dispatchers.IO) {
        kit.library.anchorOffset(bookId, index.toLong(), fragment).takeIf { it >= 0 }?.toInt()
    }

    /** The Contents rows: the real table of contents, or the spine when there is none. */
    suspend fun contents(bookId: String): Contents = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.contentsJSON(bookId))
    }

    suspend fun position(bookId: String): ReadingPosition? = withContext(Dispatchers.IO) {
        kit.library.positionJSON(bookId).takeIf { it.isNotEmpty() }?.let { kitJson.decodeFromString<ReadingPosition>(it) }
    }

    /** Saves the reader's place; `utf16Offset` is into the chapter text as Kotlin sees it. */
    suspend fun savePosition(bookId: String, chapterIndex: Int, utf16Offset: Int) = withContext(Dispatchers.IO) {
        kit.library.savePosition(bookId, chapterIndex.toLong(), utf16Offset.toLong())
    }

    /** Fire-and-forget position save from UI callbacks; failures are logged, never shown. */
    fun savePositionLater(bookId: String, chapterIndex: Int, utf16Offset: Int) {
        scope.launch {
            try { savePosition(bookId, chapterIndex, utf16Offset) } catch (e: Exception) { Log.w(TAG, "position save failed: ${e.message}") }
        }
    }

    /**
     * Every match for `query` in the book, in reading order and capped at
     * [SEARCH_LIMIT]. Case-insensitive, and a blank query matches nothing —
     * the kit decides both, so a phrase found here is the phrase the Apple
     * reader finds too.
     */
    suspend fun search(bookId: String, query: String, limit: Int = SEARCH_LIMIT): List<SearchResult> =
        withContext(Dispatchers.IO) {
            kitJson.decodeFromString(kit.library.searchJSON(bookId, query, limit.toLong()))
        }

    // MARK: Annotations — every offset is UTF-16, as Compose reports it.

    /** The book's highlights in reading order: chapter, then where each starts. */
    suspend fun highlights(bookId: String): List<Highlight> = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.highlightsJSON(bookId))
    }

    /** Highlights the selected range and returns the new highlight. A blank `note` stores none. */
    suspend fun addHighlight(
        bookId: String,
        chapterIndex: Int,
        utf16Start: Int,
        utf16End: Int,
        color: HighlightColor = HighlightColor.YELLOW,
        note: String? = null,
    ): Highlight = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(
            kit.library.addHighlight(
                bookId, chapterIndex.toLong(), utf16Start.toLong(), utf16End.toLong(), color.key, note.orEmpty()
            )
        )
    }

    /** Recolours a highlight, leaving its note alone. */
    suspend fun setHighlightColor(bookId: String, id: String, color: HighlightColor) = withContext(Dispatchers.IO) {
        kit.library.setHighlightColor(bookId, id, color.key)
    }

    /** Sets a highlight's note, leaving its colour alone; a null or blank note clears it. */
    suspend fun setHighlightNote(bookId: String, id: String, note: String?) = withContext(Dispatchers.IO) {
        kit.library.setHighlightNote(bookId, id, note.orEmpty())
    }

    suspend fun removeHighlight(bookId: String, id: String) = withContext(Dispatchers.IO) {
        kit.library.removeHighlight(bookId, id)
    }

    /** The book's text bookmarks, sorted by chapter then offset. */
    suspend fun bookmarks(bookId: String): List<Bookmark> = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.bookmarksJSON(bookId))
    }

    suspend fun addBookmark(bookId: String, chapterIndex: Int, utf16Offset: Int): Bookmark = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.library.addBookmark(bookId, chapterIndex.toLong(), utf16Offset.toLong()))
    }

    suspend fun removeBookmark(bookId: String, id: String) = withContext(Dispatchers.IO) {
        kit.library.removeBookmark(bookId, id)
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

        /** The kit's own `BookSearcher.resultCap`: more hits than anyone scans in a list. */
        const val SEARCH_LIMIT = 100
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
