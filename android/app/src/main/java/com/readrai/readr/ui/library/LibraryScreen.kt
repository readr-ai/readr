package com.readrai.readr.ui.library

import android.graphics.Bitmap
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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.readrai.readr.ui.theme.LocalReadingPalette
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
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.produceState
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(model: LibraryViewModel, onOpen: (BookSummary) -> Unit, onSettings: () -> Unit = {}) {
    val books by model.books.collectAsState()
    val busy by model.busy.collectAsState()
    val message by model.message.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(model::import) }

    LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it); model.clearMessage() } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("readr", style = MaterialTheme.typography.titleLarge) },
                actions = {
                    IconButton(onClick = onSettings, modifier = Modifier.testTag("library.settings")) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { picker.launch(arrayOf("application/pdf", "application/epub+zip", "text/plain", "text/markdown", "application/octet-stream")) },
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
                Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("A little room for a good book.", style = MaterialTheme.typography.headlineSmall, fontFamily = FontFamily.Serif)
                    Text("Bring a PDF, EPUB, or text file. Your library stays on this device.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(onClick = { picker.launch(arrayOf("application/pdf", "application/epub+zip", "text/plain", "text/markdown")) }) { Text("Import a book") }
                }
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 144.dp),
                contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = padding.calculateTopPadding() + 8.dp, bottom = 96.dp),
                horizontalArrangement = Arrangement.spacedBy(24.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.fillMaxSize().testTag("library.grid"),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("Your library", fontFamily = FontFamily.Serif, fontSize = 32.sp, color = MaterialTheme.colorScheme.onBackground)
                        Text("Good books, at your own pace.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                item(span = { GridItemSpan(maxLineSpan) }) {
                    FeaturedBook(books.first(), model) { onOpen(books.first()) }
                }
                if (books.size > 1) item(span = { GridItemSpan(maxLineSpan) }) {
                    Text("MORE TO READ · ${books.size - 1}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (books.size == 1) item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(Modifier.padding(vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("What will you read next?", fontFamily = FontFamily.Serif, style = MaterialTheme.typography.titleLarge)
                        Text("Import a PDF, EPUB, or text file. Scanned PDFs get text recognition on this device.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        androidx.compose.material3.TextButton(onClick = { picker.launch(arrayOf("application/pdf", "application/epub+zip", "text/plain", "text/markdown")) }) { Text("Add another book") }
                    }
                }
                items(books.drop(1), key = { it.id }) { book -> BookCard(book) { onOpen(book) } }
            }
        }
    }
}

@Composable
private fun BookCard(book: BookSummary, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick).testTag("library.book.${book.id}")) {
        Box(Modifier.fillMaxWidth().height(190.dp), contentAlignment = Alignment.Center) { Box(Modifier.width(126.dp)) { Cover(book) } }
        Text(book.title, style = MaterialTheme.typography.titleMedium, fontFamily = FontFamily.Serif, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
        if (book.authors.isNotEmpty()) {
            Text(book.authors.joinToString(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Decodes a cover off the main thread, downsampled to the card's size (covers are often 1600×2400). */
@Composable
private fun rememberCover(path: String?): Bitmap? {
    val bitmap by produceState<Bitmap?>(initialValue = null, path) {
        value = path?.let { p ->
            withContext(Dispatchers.IO) {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(p, bounds)
                val sample = maxOf(1, minOf(bounds.outWidth / 360, bounds.outHeight / 540))
                BitmapFactory.decodeFile(p, BitmapFactory.Options().apply { inSampleSize = sample })
            }
        }
    }
    return bitmap
}

@Composable
private fun Cover(book: BookSummary, compact: Boolean = false) {
    val shape = RoundedCornerShape(6.dp)
    val bitmap = rememberCover(book.coverPath)
    if (bitmap != null) {
        Image(bitmap.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(shape))
    } else {
        val (field, ink) = Marginalia.coverTint(book.title)
        Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(shape).background(field).padding(12.dp), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(book.title.trim().take(1), fontFamily = FontFamily.Serif, fontSize = if (compact) 28.sp else 40.sp, color = ink)
                if (!compact) Text(book.title, style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Serif, color = ink, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun FeaturedBook(book: BookSummary, model: LibraryViewModel, onOpen: () -> Unit) {
    val palette = LocalReadingPalette.current
    var label by androidx.compose.runtime.remember(book.id) { androidx.compose.runtime.mutableStateOf("Start reading") }
    LaunchedEffect(book.id) { label = model.resumeLabel(book) }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(palette.page).clickable(onClick = onOpen).testTag("library.book.${book.id}").padding(20.dp), horizontalArrangement = Arrangement.spacedBy(20.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(76.dp)) { Cover(book, compact = true) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(label.uppercase(), style = MaterialTheme.typography.labelSmall, color = palette.muted)
            Text(book.title, fontFamily = FontFamily.Serif, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (book.authors.isNotEmpty()) Text(book.authors.joinToString(), style = MaterialTheme.typography.bodyMedium, color = palette.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Open book", style = MaterialTheme.typography.labelLarge, color = palette.ink)
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(16.dp))
            }
        }
    }
}
