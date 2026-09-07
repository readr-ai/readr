package com.readrai.readr.ui.reader

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.data.Bookmark
import com.readrai.readr.data.ChapterImage
import com.readrai.readr.data.ChapterLayout
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Contents
import com.readrai.readr.data.Footnote
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.data.LibraryRepository
import com.readrai.readr.data.SearchResult
import java.io.File
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

    /**
     * A chapter as the page needs it: its text, its layout, the inline images
     * anchored in it, and the footnotes lifted out of it. All four arrive
     * together — pagination depends on the pictures, so a chapter that is half
     * loaded is a chapter that would have to be laid out twice.
     */
    class LoadedChapter(
        val index: Int,
        val text: String,
        val layout: ChapterLayout,
        val images: List<ChapterImage> = emptyList(),
        val footnotes: List<Footnote> = emptyList(),
    )

    /** A drawn page and the chapter it came from — the pair, never the page alone. */
    data class VisiblePage(val chapterIndex: Int, val page: Page)

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

    /**
     * The book's highlights, in reading order. A change is spliced in here
     * rather than reloaded: the bridge already told us what it wrote, and a
     * reload per tap would re-read every highlight in the book.
     */
    var highlights by mutableStateOf<List<Highlight>>(emptyList())
        private set

    /** The book's bookmarks, in reading order, kept in step the same way. */
    var bookmarks by mutableStateOf<List<Bookmark>>(emptyList())
        private set

    /**
     * The page on screen and the chapter it was laid out from. The reader's
     * bar bookmarks *the page*, not the anchor, so the page it is looking at
     * has to be visible up there; the page surface reports it as it renders,
     * and a jump or a crossing clears it until the new chapter's pages exist.
     * The chapter travels with the page because for one composition after a
     * jump the pages still belong to the chapter just left.
     */
    var visible by mutableStateOf<VisiblePage?>(null)
        private set

    /**
     * The in-book search: what was typed, what came back, and whether a scan
     * is still running. It lives here rather than in the sheet so closing the
     * sheet and opening it again shows the last search instead of a blank
     * field — the reader who jumped to a hit usually wants the next one.
     */
    var searchQuery by mutableStateOf("")
        private set
    var searchResults by mutableStateOf<List<SearchResult>>(emptyList())
        private set
    var searching by mutableStateOf(false)
        private set

    /** True when the scan stopped at the cap, so the list is the first hits, not all of them. */
    val searchCapped: Boolean get() = searchResults.size >= LibraryRepository.SEARCH_LIMIT

    /** The note being written, or null when no editor is open. */
    var noteDraft by mutableStateOf<NoteDraft?>(null)
        private set

    /** A short-lived reader-facing message — an annotation that would not save. */
    var message by mutableStateOf<String?>(null)
        private set

    /**
     * How many messages have been shown. The same sentence twice running is
     * two messages, and the screen's dismissal timer keys on this rather than
     * on the words, so the second one still gets its full turn.
     */
    var messageCount by mutableIntStateOf(0)
        private set

    /**
     * The book's retained original, where an inline image's bytes live. Null
     * until the book is open, and for a book with no archive behind it — the
     * page then draws alt text where a picture would have been.
     */
    var archive by mutableStateOf<File?>(null)
        private set

    private var repository: LibraryRepository? = null
    private val cache = PaginationCache()
    private var saveJob: Job? = null
    private var loadJob: Job? = null

    /** The query waiting to be scanned, and the one worker allowed to scan — see [search]. */
    private var pendingQuery: String? = null
    private var debounceJob: Job? = null
    private var searchWorker: Job? = null

    /**
     * Footnotes of chapters other than the one being read, kept because a
     * noteref into another document has to ask whether that document lifts the
     * id before it can decide between a popup and a jump — and a reader
     * following a run of endnote markers asks the same question of the same
     * document over and over.
     */
    private val otherChapterFootnotes = object : LinkedHashMap<Int, List<Footnote>>(4, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, List<Footnote>>?): Boolean = size > 4
    }

    /** The place last written (or read) from the store; a save is skipped when nothing moved. */
    private var persisted: Pair<Int, Int>? = null

    /**
     * The start of the sentence the voice is reading, while one is. It — not
     * the page top — is what gets written down: the kit's rule, because
     * pressing Listen again has to pick the book back up on the sentence the
     * reader last actually heard. Cleared by anything the reader does.
     */
    private var narrationResumeAnchor: Int? = null

    /** The chapter and offset a save would write. */
    private val place: Pair<Int, Int> get() = chapterIndex to (narrationResumeAnchor ?: anchor)

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
            archive = repo.archive(bookId)
            val position = repo.position(bookId)
            chapterIndex = position?.chapterIndex?.coerceIn(0, chapters.size - 1) ?: 0
            anchor = maxOf(0, position?.utf16Offset ?: 0)
            persisted = chapterIndex to anchor
            state = State.Ready(book.title, chapters, contents)
            // Ask's index, off the critical path. Building it is seconds on a
            // long book, and the reader is about to spend minutes on page one
            // — which is a far better moment to pay for it than after they
            // have typed a question and are watching a spinner. Fire and
            // forget: a failure here costs nothing, because `ask` builds
            // (and waits for) whatever is missing.
            viewModelScope.launch { runCatching { repo.prepareAsk(bookId) } }
            loadChapter()
            reload(repo)
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
                    val images = async { repo.chapterImages(bookId, index) }
                    val footnotes = async { repo.chapterFootnotes(bookId, index) }
                    LoadedChapter(index, text.await(), layout.await(), images.await(), footnotes.await())
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
        narrationResumeAnchor = null
        anchor = maxOf(0, utf16Offset)
        visible = null
        if (index != chapterIndex) {
            chapterIndex = index
            loadChapter()
        }
        saveNow()
    }

    /** A page turn within the chapter: the new page's range start becomes the anchor. */
    fun turned(toOffset: Int) {
        // The reader moved, so the voice's sentence is no longer where they
        // are — their page is the place again.
        narrationResumeAnchor = null
        anchor = maxOf(0, toOffset)
        scheduleSave()
    }

    /**
     * The voice moved on: put the page under it. `utf16Offset` is where the
     * voice actually is (to the word), so a long sentence spanning a page
     * break turns the page partway through rather than at its end;
     * `utf16SentenceStart` is what gets written down, because that is where
     * pressing Listen again would pick the book back up.
     *
     * The ordinary page-turn debounce applies, and reaches the store between
     * sentences: a sentence takes several seconds to say and the debounce is
     * one, so a reader who puts the phone down mid-chapter has their place.
     */
    fun followVoice(utf16Offset: Int, utf16SentenceStart: Int) {
        narrationResumeAnchor = maxOf(0, utf16SentenceStart)
        anchor = maxOf(0, utf16Offset)
        scheduleSave()
    }

    /** Narration stopped: the reader's own page is the place again. */
    fun stopFollowingVoice() {
        narrationResumeAnchor = null
    }

    /**
     * Past the last page forward or the first page backward: cross into the
     * neighbouring linear chapter — its start going forward, its end going
     * back. Going back, the last page is not known until the chapter is
     * paginated; the anchor is settled and saved then. False at either end
     * of the book.
     */
    fun overflow(direction: Int): Boolean {
        val index = neighbour(direction) ?: return false
        visible = null
        if (direction > 0) {
            jump(index, 0)
        } else {
            wantsChapterEnd = true
            chapterIndex = index
            loadChapter()
        }
        return true
    }

    /**
     * The linear chapter this one runs into going `direction`, skipping the
     * non-linear ones on the way, or null at either end of the book. The
     * scroll layout's chapter buttons ask so they can stand down at the
     * covers; [overflow] asks so a page turn past the end knows where to go.
     */
    fun neighbour(direction: Int): Int? {
        val ready = state as? State.Ready ?: return null
        var index = chapterIndex + direction
        while (index in ready.chapters.indices && !ready.chapters[index].isLinear) index += direction
        return index.takeIf { it in ready.chapters.indices }
    }

    /** Once the pages exist, a backward crossing lands on the last page's start, and that is what is saved. */
    fun settle(pagination: Pagination) {
        if (!wantsChapterEnd) return
        wantsChapterEnd = false
        anchor = pagination.pages.lastOrNull()?.rangeStart ?: 0
        saveNow()
    }

    /**
     * A backward crossing in a scroll, which has no last page to land on: the
     * end of the text — where [loadChapter] has already put the anchor — is
     * the place, and now that the chapter is drawn it is worth saving.
     */
    fun settleAtChapterEnd() {
        if (!wantsChapterEnd) return
        wantsChapterEnd = false
        saveNow()
    }

    // MARK: Search — the whole book, a fifth of a second after the typing
    // stops. The scan itself runs inside the kit, across the JNI boundary,
    // where a cancelled coroutine cannot reach it: cancelling the Kotlin side
    // would only orphan a scan that keeps running, and a reader typing quickly
    // would have several of them competing for the bridge at once. So exactly
    // one scan is allowed at a time. The debounce leaves the latest query in
    // [pendingQuery]; a single worker takes whatever is there, scans, publishes
    // if it is still the latest, and goes round again.

    fun search(query: String) {
        searchQuery = query
        val needle = query.trim()
        debounceJob?.cancel()
        if (needle.isEmpty()) {
            // Nothing typed: whatever is queued is no longer wanted, and the
            // scan in flight (if any) will find its answer out of date.
            pendingQuery = null
            searchResults = emptyList()
            searching = false
            return
        }
        searching = true
        debounceJob = viewModelScope.launch {
            delay(SEARCH_DEBOUNCE_MS)
            pendingQuery = needle
            scanPending()
        }
    }

    /** Starts the one search worker, unless it is already running — it will pick the query up. */
    private fun scanPending() {
        if (searchWorker?.isActive == true) return
        searchWorker = viewModelScope.launch {
            while (true) {
                val needle = pendingQuery ?: break
                pendingQuery = null
                val repo = repository ?: break
                val found = try {
                    repo.search(bookId, needle)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.w(TAG, "search failed: ${e.javaClass.simpleName}")
                    say("Couldn't search this book.")
                    emptyList()
                }
                // Typing carried on while the bridge was busy: what came back
                // is not an answer to what is on screen, so it is dropped and
                // the newer query goes round the loop instead.
                if (pendingQuery == null && needle == searchQuery.trim()) searchResults = found
            }
            searching = pendingQuery != null
        }
    }

    // MARK: Annotations. Every offset is UTF-16 into the chapter text, as
    // Compose reports it; the page converts its own offsets with `textStart`.

    /** Highlights the selected range; the new highlight takes its place in the list. */
    fun addHighlight(chapterIndex: Int, utf16Start: Int, utf16End: Int, color: HighlightColor) {
        mutating(
            "Couldn't save that highlight.",
            { repo -> repo.addHighlight(bookId, chapterIndex, utf16Start, utf16End, color, note = null) },
        ) { created -> highlights = highlights.plusInReadingOrder(created) }
    }

    /** Recolours a highlight; the bridge leaves whatever note it carries alone. */
    fun recolor(id: String, color: HighlightColor) {
        mutating(
            "Couldn't change that highlight.",
            { repo -> repo.setHighlightColor(bookId, id, color) },
        ) { highlights = highlights.map { if (it.id == id) it.copy(color = color.key) else it } }
    }

    fun removeHighlight(id: String) {
        mutating(
            "Couldn't remove that highlight.",
            { repo -> repo.removeHighlight(bookId, id) },
        ) { highlights = highlights.filterNot { it.id == id } }
    }

    fun clearMessage() { message = null }

    /** Says something to the reader on the page's behalf — a link that leads nowhere, a browser that isn't there. */
    fun report(text: String) = say(text)

    // MARK: Links. A tap on a link into the book resolves its archive path
    // against the chapter list already in hand, and its fragment against the
    // *target* chapter's anchors — one id, asked for on its own, which is the
    // only thing that has to be fetched and only when there is one to resolve.

    /**
     * A tapped link that stays inside the book: a noteref answered in place,
     * or a jump. The fragment is looked for in the footnotes of the chapter
     * the *path* names — the current one when the path names none — and only
     * there; a target that lifts no such note is navigation, never a same-id
     * note out of the chapter in hand ([noterefChapter] says why). `onNote` is
     * the page's, because a note shown in place belongs to the page it was
     * tapped on and dies with it.
     */
    fun followLink(path: String?, fragment: String?, onNote: (Footnote) -> Unit) {
        val ready = state as? State.Ready ?: return
        if (fragment == null) {
            if (path != null) followInternalLink(path, null) else say(NOWHERE)
            return
        }
        val target = noterefChapter(ready.chapters, path, chapterIndex)
        val loaded = chapter?.takeIf { it.index == target }?.footnotes
        if (loaded != null) {
            answerNoteref(loaded, path, fragment, onNote)
            return
        }
        viewModelScope.launch {
            answerNoteref(footnotes(target), path, fragment, onNote)
        }
    }

    private fun answerNoteref(notes: List<Footnote>, path: String?, fragment: String, onNote: (Footnote) -> Unit) {
        val note = notes.firstOrNull { it.id == fragment }
        when {
            note != null -> onNote(note)
            path != null -> followInternalLink(path, fragment)
            else -> say(NOWHERE)
        }
    }

    /** A chapter's lifted footnotes, remembered; an unreadable chapter simply lifts none. */
    private suspend fun footnotes(index: Int): List<Footnote> {
        val ready = state as? State.Ready ?: return emptyList()
        if (index !in ready.chapters.indices) return emptyList()
        otherChapterFootnotes[index]?.let { return it }
        val repo = repository ?: return emptyList()
        return try {
            repo.chapterFootnotes(bookId, index).also { otherChapterFootnotes[index] = it }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "footnotes failed: ${e.javaClass.simpleName}")
            emptyList()
        }
    }

    fun followInternalLink(path: String, fragment: String?) {
        val ready = state as? State.Ready ?: return
        val repo = repository ?: return
        val target = chapterIndexForPath(ready.chapters, path)
        if (target == null) {
            say(NOWHERE)
            return
        }
        if (fragment == null) {
            jump(target, 0)
            return
        }
        viewModelScope.launch {
            val offset = try {
                repo.anchorOffset(bookId, target, fragment)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "link anchors failed: ${e.javaClass.simpleName}")
                null
            }
            // A fragment that names no anchor lands at the chapter's start,
            // as a TOC row with an unresolvable fragment does.
            jump(target, offset ?: 0)
        }
    }

    /** Says something to the reader; every saying is its own, however it reads. */
    private fun say(text: String) {
        message = text
        messageCount++
    }

    // MARK: Notes. A note always belongs to a highlight, so "Note" on a plain
    // selection highlights it first, in the colour last used, and remembers
    // that it did: cancelling then takes that highlight away again, while
    // cancelling a note on a highlight the reader already had keeps it.

    /** "Note" on a selection: highlight it, then open the editor on what was created. */
    fun noteOnSelection(chapterIndex: Int, utf16Start: Int, utf16End: Int, color: HighlightColor) {
        mutating(
            "Couldn't save that highlight.",
            { repo -> repo.addHighlight(bookId, chapterIndex, utf16Start, utf16End, color, note = null) },
        ) { created ->
            highlights = highlights.plusInReadingOrder(created)
            noteDraft = NoteDraft(created.id, created.quotedText, created.note.orEmpty(), createdForNote = true)
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
        val note = text.trim().ifBlank { null }
        mutating(
            "Couldn't save that note.",
            { repo -> repo.setHighlightNote(bookId, draft.highlightId, note) },
        ) { highlights = highlights.map { if (it.id == draft.highlightId) it.copy(note = note) else it } }
    }

    /** Cancels the note; a highlight made only to carry it goes with it. */
    fun cancelNote() {
        val draft = noteDraft ?: return
        noteDraft = null
        if (draft.createdForNote) removeHighlight(draft.highlightId)
    }

    // MARK: Bookmarks — a place in the book, kept as a chapter and an offset.

    fun addBookmark(chapterIndex: Int, utf16Offset: Int) {
        mutating(
            "Couldn't save that bookmark.",
            { repo -> repo.addBookmark(bookId, chapterIndex, utf16Offset) },
        ) { created -> bookmarks = bookmarks.plusInReadingOrder(created) }
    }

    fun removeBookmark(id: String) {
        mutating(
            "Couldn't remove that bookmark.",
            { repo -> repo.removeBookmark(bookId, id) },
        ) { bookmarks = bookmarks.filterNot { it.id == id } }
    }

    /** The page surface reporting what it is drawing, so the bar can bookmark it. */
    fun showing(chapterIndex: Int, page: Page?) {
        visible = page?.let { VisiblePage(chapterIndex, it) }
    }

    /**
     * One annotation change: `work` writes it through the bridge and `then`
     * splices what came back into the list in hand, so a tap costs one call
     * rather than a call and a reload of the whole book. Only a failure goes
     * back for the lists — what is on screen may no longer be what is stored.
     */
    private fun <T> mutating(failure: String, work: suspend (LibraryRepository) -> T, then: (T) -> Unit) {
        val repo = repository ?: return
        viewModelScope.launch {
            try {
                then(work(repo))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "annotation failed: ${e.message}")
                reload(repo)
                say(failure)
            }
        }
    }

    /** Both lists from the store: on open, and to resync after a change that would not save. */
    private suspend fun reload(repo: LibraryRepository) {
        try {
            highlights = repo.highlights(bookId)
            bookmarks = repo.bookmarks(bookId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "annotations load failed: ${e.message}")
            say("Couldn't load your highlights and bookmarks.")
        }
    }

    /**
     * The styled chapter and its pages for `key`, built once. `compute` places
     * the chapter's images and measures it, and runs on the caller's coroutine
     * — the surface calls this off the main thread. Everything that shape
     * depends on is in the key (see [PageKey]), so a set that comes back from
     * the cache can only be the set that would have been built again.
     */
    suspend fun pageSet(key: PageKey, compute: suspend () -> PageSet): PageSet =
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
        val place = place
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
        val place = place
        if (chapterIndex < 0 || wantsChapterEnd || place == persisted) return
        persisted = place
        repo.savePositionLater(bookId, place.first, place.second)
    }

    override fun onCleared() {
        flush()
    }

    companion object {
        const val SAVE_DEBOUNCE_MS = 1000L

        /** How long the typing rests before the book is scanned. */
        const val SEARCH_DEBOUNCE_MS = 200L
        private const val TAG = "Readr.Reader"

        /** What a link that names no document in this book is answered with. */
        private const val NOWHERE = "That link doesn't lead anywhere in this book."
    }
}

/**
 * The list with `made` in it, in the order the bridge would have returned:
 * chapter, then where it starts, then when it was made. The sort is stable
 * and the new one is appended, so it lands after anything it ties with —
 * which is where the bridge, sorting on `createdAt` last, would put it too.
 */
private fun List<Highlight>.plusInReadingOrder(made: Highlight): List<Highlight> =
    (this + made).sortedWith(compareBy({ it.chapterIndex }, { it.utf16Start }))

private fun List<Bookmark>.plusInReadingOrder(made: Bookmark): List<Bookmark> =
    (this + made).sortedWith(compareBy({ it.chapterIndex }, { it.utf16Offset }))
