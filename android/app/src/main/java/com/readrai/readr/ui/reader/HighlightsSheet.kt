package com.readrai.readr.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.Marginalia

/**
 * The book's highlights, as `AnnotationListView` shows them on iOS: colour
 * chips and a search field over reading-order cards — a marker-coloured spine,
 * the quoted passage in serif, its ❋ note, and the chapter it came from. A
 * card jumps to the passage; the overflow menu edits its note or deletes it.
 *
 * The list arrives in reading order from the bridge, so nothing is sorted here.
 * Create Article and Export are later milestones.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HighlightsSheet(
    highlights: List<Highlight>,
    chapters: List<ChapterSummary>,
    onJump: (Highlight) -> Unit,
    onEditNote: (Highlight) -> Unit,
    onDelete: (Highlight) -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = LocalReadingPalette.current
    // Colour keys rather than the enum: a plain list of strings is what
    // `rememberSaveable` can put in a Bundle without a saver of its own.
    var activeKeys by rememberSaveable { mutableStateOf(HighlightColor.entries.map { it.key }) }
    var query by rememberSaveable { mutableStateOf("") }

    val active = remember(activeKeys) { activeKeys.map { HighlightColor.fromKey(it) }.toSet() }
    val shown = remember(highlights, active, query) { visibleHighlights(highlights, active, query) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
        containerColor = palette.elevated,
    ) {
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp).testTag("notes.list")) {
            item {
                Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Highlights", style = MaterialTheme.typography.titleLarge, color = palette.ink)
                    Text(
                        countLine(highlights.size),
                        style = MaterialTheme.typography.bodyMedium,
                        color = palette.muted,
                        modifier = Modifier.testTag("notes.count"),
                    )
                }
            }
            if (highlights.isEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 36.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("No highlights yet", style = MaterialTheme.typography.titleMedium, color = palette.ink, modifier = Modifier.testTag("notes.empty"))
                        Text(
                            "Select any passage while reading and pick a color — it appears here instantly.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = palette.muted,
                        )
                    }
                }
                return@LazyColumn
            }
            item {
                Column(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                        HighlightColor.entries.forEach { color ->
                            val on = color in active
                            MarkerDot(
                                color = color,
                                selected = on,
                                size = 19.dp,
                                onClick = { activeKeys = if (on) activeKeys - color.key else activeKeys + color.key },
                                label = "${color.displayName} highlights",
                                fadeWhenOff = true,
                                modifier = Modifier.testTag("notes.filter.${color.key}"),
                            )
                        }
                    }
                    SearchField(query, { query = it }, palette.ink, palette.faint, palette.page, palette.line)
                }
            }
            if (shown.isEmpty()) {
                item {
                    Text(
                        "No matching highlights",
                        style = MaterialTheme.typography.bodyMedium,
                        color = palette.muted,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 28.dp).testTag("notes.noMatches"),
                    )
                }
            }
            items(shown, key = { it.id }) { highlight ->
                HighlightCard(
                    highlight = highlight,
                    locator = chapters.getOrNull(highlight.chapterIndex)?.title.orEmpty(),
                    onJump = { onJump(highlight) },
                    onEditNote = { onEditNote(highlight) },
                    onDelete = { onDelete(highlight) },
                )
            }
        }
    }
}

/**
 * The highlights the sheet shows: the ones whose colour is switched on, and
 * whose quote or note carries the search text. The colour is compared as the
 * enum, not the stored string, so a highlight written by a newer build in a
 * colour this one has never heard of still shows — under Yellow, exactly as
 * [Highlight.markerColor] draws it. Reading order comes from the bridge;
 * nothing is sorted here.
 */
fun visibleHighlights(highlights: List<Highlight>, active: Set<HighlightColor>, query: String): List<Highlight> {
    val needle = query.trim()
    return highlights.filter { highlight ->
        highlight.markerColor in active &&
            (needle.isEmpty() || highlight.quotedText.contains(needle, ignoreCase = true) ||
                highlight.note.orEmpty().contains(needle, ignoreCase = true))
    }
}

/** "1 highlight", "4 highlights" — the count under the title. */
private fun countLine(count: Int): String = if (count == 1) "1 highlight" else "$count highlights"

@Composable
private fun SearchField(
    query: String,
    onChange: (String) -> Unit,
    ink: Color,
    faint: Color,
    field: Color,
    line: Color,
) {
    Box(
        Modifier
            .fillMaxWidth()
            .background(field, RoundedCornerShape(8.dp))
            .border(1.dp, line, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        if (query.isEmpty()) Text("Search highlights", fontSize = 13.sp, color = faint, fontFamily = FontFamily.SansSerif)
        BasicTextField(
            value = query,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 13.sp, color = ink),
            cursorBrush = SolidColor(ink),
            modifier = Modifier
                .fillMaxWidth()
                .testTag("notes.search")
                .semantics { contentDescription = "Search highlights" },
        )
    }
}

/**
 * One Marginalia highlight card. The quote keeps its raw text as the
 * accessibility label so it stays findable as its own static text, and the
 * overflow button is a sibling of the card's own tap target rather than a
 * control nested inside another control.
 */
@Composable
private fun HighlightCard(
    highlight: Highlight,
    locator: String,
    onJump: () -> Unit,
    onEditNote: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = LocalReadingPalette.current
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 5.dp)
            .background(palette.page, RoundedCornerShape(12.dp))
            .border(1.dp, palette.line, RoundedCornerShape(12.dp))
            .clickable { onJump() }
            .testTag("notes.card.${highlight.id}")
            .padding(start = 16.dp, top = 16.dp, bottom = 16.dp, end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            Modifier
                .width(3.dp)
                .height(if (highlight.note.isNullOrBlank()) 46.dp else 68.dp)
                .background(Marginalia.markerSwatch(highlight.markerColor), RoundedCornerShape(1.5.dp)),
        )
        Column(Modifier.weight(1f)) {
            Text(
                "“${highlight.quotedText}”",
                fontFamily = FontFamily.Serif,
                fontSize = 15.sp,
                lineHeight = 22.sp,
                color = palette.ink,
                modifier = Modifier.semantics { contentDescription = highlight.quotedText },
            )
            val note = highlight.note
            if (!note.isNullOrBlank()) {
                Text(
                    "${Marginalia.noteGlyph} $note",
                    fontFamily = FontFamily.SansSerif,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    color = palette.muted,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            Text(
                locator,
                fontFamily = FontFamily.SansSerif,
                fontSize = 11.sp,
                color = palette.faint,
                modifier = Modifier.padding(top = 10.dp),
            )
        }
        Box {
            IconButton(
                onClick = { menu = true },
                modifier = Modifier.testTag("notes.more.${highlight.id}").semantics { contentDescription = "More actions" },
            ) { Text("⋯", fontSize = 18.sp, color = palette.muted) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }, containerColor = palette.elevated) {
                DropdownMenuItem(
                    text = { Text("Edit note", color = palette.ink) },
                    onClick = { menu = false; onEditNote() },
                    modifier = Modifier.testTag("notes.editNote"),
                )
                DropdownMenuItem(
                    text = { Text("Delete highlight", color = palette.ink) },
                    onClick = { menu = false; onDelete() },
                    modifier = Modifier.testTag("notes.delete"),
                )
            }
        }
    }
}
