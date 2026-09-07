package com.readrai.readr.ui.reader

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.data.Bookmark
import com.readrai.readr.data.ChapterLayout
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Contents
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.data.LibraryRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The reader's place in a book: which chapter, and the anchor — the UTF-16
 * offset the visible page is derived from at render time, so re-pagination
 * never jumps. Saving follows the Apple reader: a page turn debounces the
 * save by a second, a chapter change or a jump saves at once, and leaving
 * the reader flushes whatever is pending. Nothing is written unless the
 * place actually moved, so opening a book and leaving touches nothing.
 */
class ReaderViewModel(private val library: suspend () -> LibraryRepository, val bookId: String) : ViewModel() {
    sealed interface State {
        data object Loading : State
        data class Failed(val message: String) : State
        data class Ready(val title: String, val chapters: List<ChapterSummary>, val contents: Contents) : State
    }

    class LoadedChapter(val index: Int, val text: String, val layout: ChapterLayout)

    var state by mutableStateOf<State>(State.Loading)
        private set
    var chapterIndex by mutableIntStateOf(-1)
        private set
    var anchor by mutableIntStateOf(0)
        private set
    var chapter by mutableStateOf<LoadedChapter?>(null)
        private set
    var chapterError by mutableStateOf<String?>(null)
        private set

    /** The book's highlights, so the page can draw the ones it covers. Reloaded after every change. */
    var highlights by mutableStateOf<List<Highlight>>(emptyList())
        private set

    /** The book's bookmarks, in reading order. Reloaded after every change. */
    var bookmarks by mutableStateOf<List<Bookmark>>(emptyList())
        private set

    /**
     * The page on screen. The reader's bar bookmarks *the page*, not the
     * anchor, so the page it is looking at has to be visible up there; the
     * page surface reports it as it renders, and clears it while a chapter
     * is being laid out.
     */
    var visiblePage by mutableStateOf<Page?>(null)
        private set

    /** The note being written, or null when no editor is open. */
    var noteDraft by mutableStateOf<NoteDraft?>(null)
        private set

    /** A short-lived reader-facing message — an annotation that would not save. */
    var message by mutableStateOf<String?>(null)
        private set

    private var repository: LibraryRepository? = null
    private val cache = PaginationCache()
    private var saveJob: Job? = null
    private var loadJob: Job? = null

    /** The place last written (or read) from the store; a save is skipped when nothing moved. */
    private var persisted: Pair<Int, Int>? = null

    /** Set by a backward chapter crossing: the anchor becomes the chapter's end once its length is known. */
    private var wantsChapterEnd = false

    init {
        viewModelScope.launch { open() }
    }

    private suspend fun open() {
        try {
            val repo = library()
            repository = repo
            val book = repo.book(bookId) ?: throw IllegalStateException("This book is no longer in your library.")
            val chapters = repo.chapters(bookId)
            if (chapters.isEmpty()) throw IllegalStateException("This book has no readable text.")
            val contents = repo.contents(bookId)
            val position = repo.position(bookId)
            chapterIndex = position?.chapterIndex?.coerceIn(0, chapters.size - 1) ?: 0
            anchor = maxOf(0, position?.utf16Offset ?: 0)
            persisted = chapterIndex to anchor
            state = State.Ready(book.title, chapters, contents)
            loadChapter()
            reloadHighlights(repo)
            reloadBookmarks(repo)
        } catch (e: Exception) {
            state = State.Failed(e.message ?: "Couldn't open this book.")
        }
    }

    private fun loadChapter() {
        val repo = repository ?: return
        val index = chapterIndex
        loadJob?.cancel()
        chapter = null
        chapterError = null
        loadJob = viewModelScope.launch {
            try {
                val loaded = coroutineScope {
                    val text = async { repo.chapterText(bookId, index) }
                    val layout = async { repo.chapterLayout(bookId, index) }
                    LoadedChapter(index, text.await(), layout.await())
                }
                if (chapterIndex != index) return@launch
                // Going back: show the last page now; the exact anchor settles with the pages.
                if (wantsChapterEnd) anchor = loaded.layout.utf16Length
                chapter = loaded
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (chapterIndex == index) chapterError = e.message ?: "Couldn't load this chapter."
            }
        }
    }

    /** Go to a place in the book (Contents, a search hit, a bookmark). Saves at once. */
    fun jump(index: Int, utf16Offset: Int) {
        val ready = state as? State.Ready ?: return
        if (index !in ready.chapters.indices) return
        wantsChapterEnd = false
        anchor = maxOf(0, utf16Offset)
        if (index != chapterIndex) {
            chapterIndex = index
            loadChapter()
        }
        saveNow()
    }

    /** A page turn within the chapter: the new page's range start becomes the anchor. */
    fun turned(toOffset: Int) {
        anchor = maxOf(0, toOffset)
        scheduleSave()
    }

    /**
     * Past the last page forward or the first page backward: cross into the
     * neighbouring linear chapter — its start going forward, its end going
     * back. Going back, the last page is not known until the chapter is
     * paginated; the anchor is settled and saved then. False at either end
     * of the book.
     */
    fun overflow(direction: Int): Boolean {
        val ready = state as? State.Ready ?: return false
        var index = chapterIndex + direction
        while (index in ready.chapters.indices && !ready.chapters[index].isLinear) index += direction
        if (index !in ready.chapters.indices) return false
        if (direction > 0) {
            jump(index, 0)
        } else {
            wantsChapterEnd = true
            chapterIndex = index
            loadChapter()
        }
        return true
    }

    /** Once the pages exist, a backward crossing lands on the last page's start, and that is what is saved. */
    fun settle(pagination: Pagination) {
        if (!wantsChapterEnd) return
        wantsChapterEnd = false
        anchor = pagination.pages.lastOrNull()?.rangeStart ?: 0
        saveNow()
    }

    // MARK: Annotations. Every offset is UTF-16 into the chapter text, as
    // Compose reports it; the page converts its own offsets with `textStart`.

    /** Highlights the selected range. The list is reloaded so the page redraws with it. */
    fun addHighlight(chapterIndex: Int, utf16Start: Int, utf16End: Int, color: HighlightColor) {
        annotate("Couldn't save that highlight.") { repo ->
            repo.addHighlight(bookId, chapterIndex, utf16Start, utf16End, color, note = null)
        }
    }

    /** Recolours a highlight, keeping whatever note it carries. */
    fun recolor(id: String, color: HighlightColor) {
        val note = highlights.firstOrNull { it.id == id }?.note
        annotate("Couldn't change that highlight.") { repo -> repo.updateHighlight(id, color, note) }
    }

    fun removeHighlight(id: String) {
        annotate("Couldn't remove that highlight.") { repo -> repo.removeHighlight(id) }
    }

    fun clearMessage() { message = null }

    // MARK: Notes. A note always belongs to a highlight, so "Note" on a plain
    // selection highlights it first, in the colour last used, and remembers
    // that it did: cancelling then takes that highlight away again, while
    // cancelling a note on a highlight the reader already had keeps it.

    /** "Note" on a selection: highlight it, then open the editor on what was created. */
    fun noteOnSelection(chapterIndex: Int, utf16Start: Int, utf16End: Int, color: HighlightColor) {
        val repo = repository ?: return
        viewModelScope.launch {
            try {
                val created = repo.addHighlight(bookId, chapterIndex, utf16Start, utf16End, color, note = null)
                reloadHighlights(repo)
                noteDraft = NoteDraft(created.id, created.quotedText, created.note.orEmpty(), createdForNote = true)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "note highlight failed: ${e.message}")
                message = "Couldn't save that highlight."
            }
        }
    }

    /** "Edit note" on a highlight the reader already has: the editor opens on its note. */
    fun noteOnHighlight(highlight: Highlight) {
        noteDraft = NoteDraft(highlight.id, highlight.quotedText, highlight.note.orEmpty(), createdForNote = false)
    }

    /** Saves the note; an empty or blank one stores no note at all rather than "". */
    fun saveNote(text: String) {
        val draft = noteDraft ?: return
        noteDraft = null
        val color = highlights.firstOrNull { it.id == draft.highlightId }?.markerColor ?: HighlightColor.YELLOW
        annotate("Couldn't save that note.") { repo ->
            repo.updateHighlight(draft.highlightId, color, text.trim().ifBlank { null })
        }
    }

    /** Cancels the note; a highlight made only to carry it goes with it. */
    fun cancelNote() {
        val draft = noteDraft ?: return
        noteDraft = null
        if (draft.createdForNote) removeHighlight(draft.highlightId)
    }

    // MARK: Bookmarks — a place in the book, kept as a chapter and an offset.

    fun addBookmark(chapterIndex: Int, utf16Offset: Int) {
        bookmark("Couldn't save that bookmark.") { repo -> repo.addBookmark(bookId, chapterIndex, utf16Offset) }
    }

    fun removeBookmark(id: String) {
        bookmark("Couldn't remove that bookmark.") { repo -> repo.removeBookmark(id) }
    }

    /** The page surface reporting what it is drawing, so the bar can bookmark it. */
    fun showing(page: Page?) { visiblePage = page }

    private fun annotate(failure: String, work: suspend (LibraryRepository) -> Unit) =
        mutate(failure, work) { repo -> reloadHighlights(repo) }

    private fun bookmark(failure: String, work: suspend (LibraryRepository) -> Unit) =
        mutate(failure, work) { repo -> reloadBookmarks(repo) }

    private fun mutate(
        failure: String,
        work: suspend (LibraryRepository) -> Unit,
        reload: suspend (LibraryRepository) -> Unit,
    ) {
        val repo = repository ?: return
        viewModelScope.launch {
            try {
                work(repo)
                reload(repo)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "annotation failed: ${e.message}")
                message = failure
            }
        }
    }

    private suspend fun reloadHighlights(repo: LibraryRepository) {
        try {
            highlights = repo.highlights(bookId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "highlights load failed: ${e.message}")
        }
    }

    private suspend fun reloadBookmarks(repo: LibraryRepository) {
        try {
            bookmarks = repo.bookmarks(bookId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "bookmarks load failed: ${e.message}")
        }
    }

    /** Pages for `key`, computed once; `compute` runs on the caller's thread. */
    fun pageSet(key: PageKey, compute: () -> PageSet): PageSet =
        cache.get(key) ?: compute().also { cache.put(key, it) }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = viewModelScope.launch {
            delay(SAVE_DEBOUNCE_MS)
            persist()
        }
    }

    private fun saveNow() {
        saveJob?.cancel()
        saveJob = viewModelScope.launch { persist() }
    }

    private suspend fun persist() {
        val repo = repository ?: return
        val place = chapterIndex to anchor
        if (chapterIndex < 0 || wantsChapterEnd || place == persisted) return
        try {
            repo.savePosition(bookId, place.first, place.second)
            persisted = place
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "position save failed: ${e.message}")
        }
    }

    /** Leaving the reader: whatever is pending is written now, off this scope; nothing if the place did not move. */
    fun flush() {
        saveJob?.cancel()
        val repo = repository ?: return
        val place = chapterIndex to anchor
        if (chapterIndex < 0 || wantsChapterEnd || place == persisted) return
        persisted = place
        repo.savePositionLater(bookId, place.first, place.second)
    }

    override fun onCleared() {
        flush()
    }

    companion object {
        const val SAVE_DEBOUNCE_MS = 1000L
        private const val TAG = "Readr.Reader"
    }
}
