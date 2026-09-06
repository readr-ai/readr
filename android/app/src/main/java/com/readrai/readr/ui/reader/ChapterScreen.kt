package com.readrai.readr.ui.reader

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.LibraryRepository

/**
 * Phase-1 reading surface: the chapter the reader left off in, as scrolling
 * text on paper. The paginated surface with selection and highlights (the
 * counterpart of `SelectableTextView`) is the next milestone; this exists so
 * an imported book can be opened and its position kept.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChapterScreen(repository: LibraryRepository, bookId: String, title: String, onBack: () -> Unit) {
    var chapters by remember { mutableStateOf<List<ChapterSummary>>(emptyList()) }
    var index by remember { mutableStateOf(0) }
    var text by remember { mutableStateOf("") }

    LaunchedEffect(bookId) {
        chapters = repository.chapters(bookId)
        index = repository.position(bookId)?.chapterIndex?.coerceIn(0, (chapters.size - 1).coerceAtLeast(0)) ?: 0
    }
    LaunchedEffect(bookId, index, chapters.size) {
        if (chapters.isNotEmpty()) {
            text = repository.chapterText(bookId, index)
            repository.savePosition(bookId, index, 0)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(chapters.getOrNull(index)?.title ?: title, style = MaterialTheme.typography.titleMedium) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to library") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        containerColor = MaterialTheme.colorScheme.surface,
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 16.dp).testTag("reader.page")) {
            Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}
