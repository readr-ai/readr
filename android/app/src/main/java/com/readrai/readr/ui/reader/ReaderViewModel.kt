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
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The reader's place in a book: which chapter, and the anchor — the UTF-16
 * offset the visible page is derived from at render time, so re-pagination
 * never jumps. Saving follows the Apple reader: a page turn debounces the
 * save by a second, a chapter change or a jump saves at once, and leaving
 * the reader flushes whatever is pending.
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
                val text = repo.chapterText(bookId, index)
                val layout = repo.chapterLayout(bookId, index)
                if (chapterIndex == index) chapter = LoadedChapter(index, text, layout)
            } catch (e: Exception) {
                if (chapterIndex == index) chapterError = e.message ?: "Couldn't load this chapter."
            }
        }
    }

    /** Go to a place in the book (Contents, a search hit, a bookmark). Saves at once. */
    fun jump(index: Int, utf16Offset: Int) {
        val ready = state as? State.Ready ?: return
        if (index !in ready.chapters.indices) return
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
     * back. False at either end of the book.
     */
    fun overflow(direction: Int): Boolean {
        val ready = state as? State.Ready ?: return false
        var index = chapterIndex + direction
        while (index in ready.chapters.indices && !ready.chapters[index].isLinear) index += direction
        if (index !in ready.chapters.indices) return false
        jump(index, if (direction > 0) 0 else END)
        return true
    }

    /** Once the pages exist, an "end of chapter" anchor settles on the last page's start. */
    fun settle(pagination: Pagination) {
        val pages = pagination.pages
        if (anchor == END && pages.isNotEmpty()) anchor = pages.last().rangeStart
    }

    /** Pages for `key`, computed once; `compute` runs on the caller's thread. */
    fun pageSet(key: String, compute: () -> PageSet): PageSet =
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
        val index = chapterIndex
        if (index < 0) return
        try {
            repo.savePosition(bookId, index, anchor)
        } catch (e: Exception) {
            Log.w(TAG, "position save failed: ${e.message}")
        }
    }

    /** Leaving the reader: whatever is pending is written now, off this scope. */
    fun flush() {
        saveJob?.cancel()
        val repo = repository ?: return
        if (chapterIndex >= 0) repo.savePositionLater(bookId, chapterIndex, anchor)
    }

    override fun onCleared() {
        flush()
    }

    companion object {
        /** An anchor past any page: "the last page", until the pages exist. */
        const val END = Int.MAX_VALUE
        const val SAVE_DEBOUNCE_MS = 1000L
        private const val TAG = "Readr.Reader"
    }
}
