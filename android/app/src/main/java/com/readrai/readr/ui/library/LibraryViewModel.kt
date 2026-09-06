package com.readrai.readr.ui.library

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.data.BookSummary
import com.readrai.readr.data.LibraryRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class LibraryViewModel(private val repository: LibraryRepository) : ViewModel() {
    val books: StateFlow<List<BookSummary>> = repository.books
    private val _busy = MutableStateFlow(true)
    val busy: StateFlow<Boolean> = _busy.asStateFlow()
    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    init {
        viewModelScope.launch {
            try {
                repository.refresh()
                repository.seedSampleIfNeeded()
            } catch (e: Exception) {
                _message.value = "Couldn't open the library: ${e.message}"
            } finally { _busy.value = false }
        }
    }

    fun import(uri: Uri) {
        viewModelScope.launch {
            _busy.value = true
            try {
                val book = repository.import(uri)
                _message.value = "Added “${book.title}”"
            } catch (e: Exception) {
                _message.value = "Couldn't import that file: ${e.message ?: e::class.simpleName}"
            } finally { _busy.value = false }
        }
    }

    fun clearMessage() { _message.value = null }
}
