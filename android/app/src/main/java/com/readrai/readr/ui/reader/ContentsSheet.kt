package com.readrai.readr.ui.reader

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.Contents
import com.readrai.readr.data.ContentsRow
import com.readrai.readr.ui.theme.LocalReadingPalette

/**
 * The book's table of contents (or its spine when it has none), the current
 * row bold. With a real TOC the current row is the last one at or before the
 * chapter being read — front matter and multi-entry documents make "equal"
 * the wrong test. Bookmarks join this sheet in A2b.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContentsSheet(contents: Contents, currentChapter: Int, onPick: (ContentsRow) -> Unit, onDismiss: () -> Unit) {
    val palette = LocalReadingPalette.current
    val currentRow = currentRow(contents, currentChapter)
    val listState = rememberLazyListState()
    // Item 0 is the section header, so row `id` sits at item `id + 1`.
    LaunchedEffect(currentRow) { if (currentRow > 0) listState.scrollToItem(currentRow + 1) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false), containerColor = palette.elevated) {
        LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp).testTag("contents.list")) {
            item {
                Text(
                    "CONTENTS",
                    style = MaterialTheme.typography.labelSmall,
                    color = palette.muted,
                    modifier = Modifier.padding(start = 20.dp, top = 4.dp, bottom = 8.dp),
                )
            }
            items(contents.rows, key = { it.id }) { row ->
                val isCurrent = row.id == currentRow
                Box(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onPick(row) }
                        .semantics { selected = isCurrent }
                        .testTag("contents.row.${row.id}")
                        .padding(start = (20 + row.depth * 14).dp, end = 20.dp, top = 9.dp, bottom = 9.dp),
                ) {
                    Text(
                        row.title.ifBlank { "Untitled" },
                        fontFamily = FontFamily.Serif,
                        fontSize = 15.sp,
                        fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                        color = palette.ink,
                    )
                }
            }
        }
    }
}

/** The row to mark as current: see the class comment. -1 when none applies. */
fun currentRow(contents: Contents, currentChapter: Int): Int {
    if (contents.isFallback) return contents.rows.firstOrNull { it.chapterIndex == currentChapter }?.id ?: -1
    return contents.rows.lastOrNull { it.chapterIndex <= currentChapter }?.id ?: -1
}
