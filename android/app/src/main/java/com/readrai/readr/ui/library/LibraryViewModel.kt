package com.readrai.readr.ui.library

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.ReadrApplication
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.EpubExtractor
import com.readrai.readr.data.LibraryRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class LibraryViewModel(private val app: ReadrApplication) : ViewModel() {
    private val _books = MutableStateFlow<List<BookSummary>>(emptyList())
    val books: StateFlow<List<BookSummary>> = _books.asStateFlow()
    private val _busy = MutableStateFlow(true)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()
    private var repository: LibraryRepository? = null

    init {
        viewModelScope.launch {
            try {
                val repo = app.library()  // opens the kit off the main thread on first use
                repository = repo
                launch { repo.books.collect { _books.value = it } }
                repo.refresh()
                repo.seedSampleIfNeeded()
            } catch (e: Exception) {
                _message.value = "Couldn't open the library: ${e.message ?: "unexpected error"}"
            } finally { _busy.value = false }
        }
    }

    fun import(uri: Uri) {
        val repo = repository ?: return
        viewModelScope.launch {
            _busy.value = true
            try {
                val book = repo.import(uri)
                _message.value = when {
                    book.isImageOnly -> "Added “${book.title}” — it has no text layer, so reading and Ask are unavailable for this book."
                    book.isFixedLayout -> "Added “${book.title}” — a fixed-layout book, shown as extracted text for now."
                    else -> "Added “${book.title}”"
                }
            } catch (e: EpubExtractor.Rejected) {
                _message.value = e.message
            } catch (e: Exception) {
                // Kit errors arrive with ReadrKit's reader-facing sentence as the message.
                _message.value = "Couldn't import that file. ${e.message ?: ""}".trim()
            } finally { _busy.value = false }
        }
    }

    fun clearMessage() { _message.value = null }
}
