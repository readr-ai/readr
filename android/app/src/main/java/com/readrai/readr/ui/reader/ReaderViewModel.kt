package com.readrai.readr.ui.reader

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.data.ChapterLayout
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Contents
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
