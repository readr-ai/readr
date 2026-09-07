package com.readrai.readr.ui.reader

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.Bookmark
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Contents
import com.readrai.readr.data.ContentsRow
import com.readrai.readr.ui.theme.LocalReadingPalette

/**
 * The book's places: the reader's own bookmarks first (when there are any),
 * then the table of contents (or the spine when the book has none), the
 * current row bold. With a real TOC the current row is the last one at or
 * before the chapter being read — front matter and multi-entry documents make
 * "equal" the wrong test. A contents row whose stretch of the book holds a
 * bookmark wears a faint ribbon.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContentsSheet(
    contents: Contents,
    chapters: List<ChapterSummary>,
    bookmarks: List<Bookmark>,
    currentChapter: Int,
    onPick: (ContentsRow) -> Unit,
    onPickBookmark: (Bookmark) -> Unit,
    onRemoveBookmark: (Bookmark) -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = LocalReadingPalette.current
    val currentRow = currentRow(contents, currentChapter)
    val marked = remember(contents, bookmarks) { rowsHoldingBookmarks(contents, bookmarks) }
    val listState = rememberLazyListState()
    // The CONTENTS header, and above it the bookmarks section when there is one,
    // sit before row `id`, so that row is item `id + leading`.
    val leading = if (bookmarks.isEmpty()) 1 else bookmarks.size + 2
    LaunchedEffect(currentRow, leading) { if (currentRow > 0) listState.scrollToItem(currentRow + leading) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false), containerColor = palette.elevated) {
        LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp).testTag("contents.list")) {
            if (bookmarks.isNotEmpty()) {
                item { SectionHeader("BOOKMARKS") }
                items(bookmarks, key = { "bookmark-${it.id}" }) { bookmark ->
                    BookmarkRow(
                        bookmark = bookmark,
                        chapterTitle = chapters.getOrNull(bookmark.chapterIndex)?.title.orEmpty(),
                        onPick = { onPickBookmark(bookmark) },
                        onRemove = { onRemoveBookmark(bookmark) },
                    )
                }
            }
            item { SectionHeader("CONTENTS") }
            items(contents.rows, key = { it.id }) { row ->
                val isCurrent = row.id == currentRow
                val hasBookmark = row.id in marked
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onPick(row) }
                        .semantics {
                            selected = isCurrent
                            if (hasBookmark) stateDescription = "Has a bookmark"
                        }
                        .testTag("contents.row.${row.id}")
                        .padding(start = (20 + row.depth * 14).dp, end = 20.dp, top = 9.dp, bottom = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        row.title.ifBlank { "Untitled" },
                        fontFamily = FontFamily.Serif,
                        fontSize = 15.sp,
                        fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                        color = palette.ink,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (hasBookmark) {
                        Box(
                            Modifier
                                .padding(start = 8.dp)
                                .testTag("contents.hasBookmark.${row.id}")
                                .clearAndSetSemantics { },
                        ) { BookmarkRibbon(filled = true, color = palette.faint, size = 11.dp) }
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    val palette = LocalReadingPalette.current
    Text(
        title,
        style = MaterialTheme.typography.labelSmall,
        color = palette.muted,
        modifier = Modifier.padding(start = 20.dp, top = 4.dp, bottom = 8.dp),
    )
}

/**
 * One bookmark: where it is, and the line it sits on. Jumping and removing are
 * two sibling controls — the row is not itself the only button, so "remove"
 * never hides inside "go there".
 */
@Composable
private fun BookmarkRow(bookmark: Bookmark, chapterTitle: String, onPick: () -> Unit, onRemove: () -> Unit) {
    val palette = LocalReadingPalette.current
    Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .weight(1f)
                .clickable { onPick() }
                .testTag("contents.bookmark.${bookmark.id}")
                .padding(start = 20.dp, top = 8.dp, bottom = 8.dp, end = 8.dp),
        ) {
            Column {
                Text(
                    chapterTitle.uppercase(),
                    style = MaterialTheme.typography.labelSmall,
                    color = palette.faint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "“${bookmark.snippet}”",
                    fontFamily = FontFamily.Serif,
                    fontStyle = FontStyle.Italic,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    color = palette.ink,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
        IconButton(
            onClick = onRemove,
            modifier = Modifier
                .testTag("contents.removeBookmark.${bookmark.id}")
                .semantics { contentDescription = "Remove bookmark" },
        ) { Text("✕", fontSize = 13.sp, color = palette.faint) }
    }
}

/**
 * A ribbon: the reader's bookmark mark, drawn rather than bundled (Material's
 * core icon set carries no bookmark). Filled when the place is bookmarked,
 * outlined when it is not.
 */
@Composable
fun BookmarkRibbon(filled: Boolean, color: Color, size: Dp = 18.dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val inset = w * 0.22f
        val path = Path().apply {
            moveTo(inset, h * 0.08f)
            lineTo(w - inset, h * 0.08f)
            lineTo(w - inset, h * 0.92f)
            lineTo(w / 2f, h * 0.66f)
            lineTo(inset, h * 0.92f)
            close()
        }
        if (filled) drawPath(path, color) else drawPath(path, color, style = Stroke(width = 1.5.dp.toPx()))
    }
}

/** The row to mark as current: see the class comment. -1 when none applies. */
fun currentRow(contents: Contents, currentChapter: Int): Int {
    if (contents.isFallback) return contents.rows.firstOrNull { it.chapterIndex == currentChapter }?.id ?: -1
    return contents.rows.lastOrNull { it.chapterIndex <= currentChapter }?.id ?: -1
}

/**
 * The contents rows that own a bookmark: a row owns every place from its own
 * (chapter, offset) up to the next row's. Rows are in document order, so the
 * comparison is the pair, not the chapter alone — several rows can share a
 * chapter.
 */
fun rowsHoldingBookmarks(contents: Contents, bookmarks: List<Bookmark>): Set<Int> {
    if (bookmarks.isEmpty() || contents.rows.isEmpty()) return emptySet()
    fun place(chapter: Int, offset: Int): Long = chapter.toLong() * PLACE_SCALE + offset
    val starts = contents.rows.map { place(it.chapterIndex, it.utf16Offset) }
    val marked = HashSet<Int>()
    for (bookmark in bookmarks) {
        val at = place(bookmark.chapterIndex, bookmark.utf16Offset)
        val row = contents.rows.indices.lastOrNull { starts[it] <= at } ?: continue
        marked.add(contents.rows[row].id)
    }
    return marked
}

/** Chapters are ordered before offsets, and no chapter is anywhere near this long. */
private const val PLACE_SCALE = 1_000_000_000L
