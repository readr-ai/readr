package com.readrai.readr.ui.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.readrai.readr.ReadrApplication
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.LibraryRepository

private sealed interface ReaderState {
    data object Loading : ReaderState
    data class Failed(val message: String) : ReaderState
    data class Ready(val title: String, val chapters: List<ChapterSummary>) : ReaderState
}

/**
 * Phase-1 reading surface: the chapter the reader left off in, as scrolling
 * text on paper, with previous/next chapter. The paginated surface with
 * selection and highlights (the counterpart of `SelectableTextView`) is the
 * next milestone. Opening a book never writes its position; only a chapter
 * change does, and then with the chapter's start (offset 0) — the kit's
 * `characterOffset` for the chapter being read is left untouched.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChapterScreen(app: ReadrApplication, bookId: String, onBack: () -> Unit) {
    var repository by remember { mutableStateOf<LibraryRepository?>(null) }
    var state by remember { mutableStateOf<ReaderState>(ReaderState.Loading) }
    var index by remember { mutableIntStateOf(-1) }
    var text by remember { mutableStateOf<String?>(null) }
    var textError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(bookId) {
        try {
            val repo = app.library()
            repository = repo
            val book = repo.book(bookId) ?: throw IllegalStateException("This book is no longer in your library.")
            val chapters = repo.chapters(bookId)
            if (chapters.isEmpty()) throw IllegalStateException("This book has no readable text.")
            index = repo.position(bookId)?.chapterIndex?.coerceIn(0, chapters.size - 1) ?: 0
            state = ReaderState.Ready(book.title, chapters)
        } catch (e: Exception) {
            state = ReaderState.Failed(e.message ?: "Couldn't open this book.")
        }
    }
    LaunchedEffect(index) {
        val repo = repository ?: return@LaunchedEffect
        if (index < 0) return@LaunchedEffect
        text = null; textError = null
        try {
            text = repo.chapterText(bookId, index)
        } catch (e: Exception) {
            textError = e.message ?: "Couldn't load this chapter."
        }
    }

    val ready = state as? ReaderState.Ready
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(ready?.chapters?.getOrNull(index)?.title ?: ready?.title ?: "", style = MaterialTheme.typography.titleMedium) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to library") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        containerColor = MaterialTheme.colorScheme.surface,
    ) { padding ->
        when (val s = state) {
            ReaderState.Loading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            is ReaderState.Failed -> Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(s.message, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.testTag("reader.error"))
                    TextButton(onClick = onBack) { Text("Back to library") }
                }
            }
            is ReaderState.Ready -> Column(Modifier.fillMaxSize().padding(padding)) {
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 16.dp).testTag("reader.page")) {
                    when {
                        textError != null -> Text(textError!!, style = MaterialTheme.typography.bodyMedium)
                        text == null -> CircularProgressIndicator()
                        else -> Text(text!!, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
                    }
                }
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    IconButton(enabled = index > 0, onClick = { moveTo(index - 1, s.chapters.size, repository, bookId) { index = it } }, modifier = Modifier.testTag("reader.previous")) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Previous chapter")
                    }
                    Text("${index + 1} of ${s.chapters.size}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    IconButton(enabled = index < s.chapters.size - 1, onClick = { moveTo(index + 1, s.chapters.size, repository, bookId) { index = it } }, modifier = Modifier.testTag("reader.next")) {
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "Next chapter")
                    }
                }
            }
        }
    }
}

private fun moveTo(target: Int, count: Int, repository: LibraryRepository?, bookId: String, set: (Int) -> Unit) {
    if (target !in 0 until count) return
    set(target)
    repository?.savePositionLater(bookId, target, 0)
}
