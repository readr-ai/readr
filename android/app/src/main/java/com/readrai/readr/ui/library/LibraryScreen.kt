package com.readrai.readr.ui.library

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.readrai.readr.data.BookSummary
import com.readrai.readr.ui.theme.Marginalia

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(model: LibraryViewModel, onOpen: (BookSummary) -> Unit) {
    val books by model.books.collectAsState()
    val busy by model.busy.collectAsState()
    val message by model.message.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(model::import) }

    LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it); model.clearMessage() } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Library", style = MaterialTheme.typography.titleLarge) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { picker.launch(arrayOf("application/epub+zip", "text/plain", "text/markdown", "application/octet-stream")) },
                modifier = Modifier.testTag("library.import"),
            ) { Icon(Icons.Filled.Add, contentDescription = "Import a book") }
        },
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        if (busy && books.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        } else if (books.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text("No books yet. Tap + to import an EPUB or text file.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 120.dp),
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding() + 8.dp, bottom = 96.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().testTag("library.grid"),
            ) {
                items(books, key = { it.id }) { book -> BookCard(book) { onOpen(book) } }
            }
        }
    }
}

@Composable
private fun BookCard(book: BookSummary, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick).testTag("library.book.${book.id}")) {
        Cover(book)
        Text(book.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
        if (book.authors.isNotEmpty()) {
            Text(book.authors.joinToString(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun Cover(book: BookSummary) {
    val shape = RoundedCornerShape(6.dp)
    val bitmap = remember(book.coverPath) { book.coverPath?.let { BitmapFactory.decodeFile(it) } }
    if (bitmap != null) {
        Image(bitmap.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(shape))
    } else {
        val (field, ink) = Marginalia.coverTint(book.title)
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(shape).background(field).padding(12.dp), contentAlignment = Alignment.Center) {
            Text(book.title, style = MaterialTheme.typography.titleMedium, color = ink, maxLines = 4, overflow = TextOverflow.Ellipsis)
        }
    }
}
