package com.readrai.readr.ui.reader

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

/** Original page rendering keeps figures, equations and fixed layout available
 * beside the reflowed/OCR text used by Listen, selection and Ask. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PdfOriginalDialog(file: File, page: Int, spokenPage: Int?, onPage: (Int) -> Unit, onDismiss: () -> Unit) {
    val count by produceState<Result<Int>?>(null, file.path) {
        value = withContext(Dispatchers.IO) { runCatching {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor -> PdfRenderer(descriptor).use { it.pageCount } }
        } }
    }
    val list = rememberLazyListState(initialFirstVisibleItemIndex = page.coerceAtLeast(0))
    val openingPage = remember(file.path) { page }
    var positioned by remember(file.path) { mutableStateOf(false) }
    var userNavigating by remember(file.path) { mutableStateOf(false) }
    LaunchedEffect(list) {
        list.interactionSource.interactions.collect { if (it is DragInteraction.Start) userNavigating = true }
    }
    var seeded by remember(file.path) { mutableStateOf(false) }
    var readyPages by remember(file.path) { mutableStateOf(emptySet<Int>()) }
    LaunchedEffect(count) {
        val pages = count?.getOrNull() ?: return@LaunchedEffect
        if (pages == 0) return@LaunchedEffect
        snapshotFlow { list.layoutInfo.totalItemsCount }.first { it == pages }
        list.scrollToItem(openingPage.coerceIn(0, pages - 1))
        seeded = true
    }
    LaunchedEffect(seeded, readyPages) {
        if (!seeded || positioned) return@LaunchedEffect
        val visible = list.layoutInfo.visibleItemsInfo.map { it.index }
        if (visible.isEmpty() || !visible.all { it in readyPages }) return@LaunchedEffect
        // Bitmap dimensions replace the placeholders. Restore the intended
        // anchor after that layout, before publishing any reading position.
        withFrameNanos { }
        val target = openingPage.coerceIn(0, (count?.getOrNull() ?: 1) - 1)
        if (!userNavigating) { list.scrollToItem(target); onPage(target) }
        positioned = true
    }
    LaunchedEffect(spokenPage, positioned) {
        if (!positioned) return@LaunchedEffect
        val pages = count?.getOrNull() ?: return@LaunchedEffect
        if (spokenPage != null && spokenPage in 0 until pages) {
            userNavigating = false
            list.animateScrollToItem(spokenPage)
            onPage(spokenPage)
        }
    }
    LaunchedEffect(list, positioned, userNavigating) {
        if (!positioned || !userNavigating) return@LaunchedEffect
        snapshotFlow {
            val info = list.layoutInfo
            // The last page may be shorter than the viewport. Its preceding
            // page is then still first-visible; choose the page most in view.
            info.visibleItemsInfo.maxByOrNull {
                (minOf(it.offset + it.size, info.viewportEndOffset) - maxOf(it.offset, info.viewportStartOffset)).coerceAtLeast(0)
            }?.index
        }.distinctUntilChanged().collect { it?.let(onPage) }
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(topBar = {
            TopAppBar(title = { Text("Original PDF") }, navigationIcon = { IconButton(onClick = onDismiss) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to reading text") } })
        }) { padding ->
            val result = count
            when {
                result == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                result.isFailure -> Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) { Text("The original PDF couldn't be opened. Close this view and try importing it again.") }
                else -> LazyColumn(state = list, contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding()), modifier = Modifier.fillMaxSize().testTag("reader.pdfOriginal"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    items((0 until result.getOrThrow()).toList(), key = { it }) { index -> PdfPageImage(file, index) { readyPages = readyPages + index } }
                }
            }
        }
    }
}

@Composable
private fun PdfPageImage(file: File, index: Int, onReady: () -> Unit) {
    val bitmap by produceState<Result<Bitmap>?>(null, file.path, index) {
        value = withContext(Dispatchers.IO) { runCatching {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { document -> document.openPage(index).use { page ->
                    val scale = 1600f / maxOf(page.width, page.height).coerceAtLeast(1)
                    Bitmap.createBitmap(maxOf(1, (page.width * scale).toInt()), maxOf(1, (page.height * scale).toInt()), Bitmap.Config.ARGB_8888).also {
                        it.eraseColor(Color.WHITE); page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                } }
            }
        } }
    }
    LaunchedEffect(bitmap) { if (bitmap?.isSuccess == true) onReady() }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Page ${index + 1}", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(8.dp))
        val image = bitmap?.getOrNull()
        when {
            image != null -> Image(image.asImageBitmap(), "Original PDF page ${index + 1}", Modifier.fillMaxWidth().aspectRatio(image.width.toFloat() / image.height).testTag("reader.pdfPage.$index"))
            bitmap?.isFailure == true -> Text("This page couldn't be rendered. Try re-importing the PDF.", Modifier.padding(24.dp))
            else -> Box(Modifier.fillMaxWidth().height(360.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }
    }
}
