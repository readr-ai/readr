package com.readrai.readr.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.SearchResult
import com.readrai.readr.ui.theme.LocalReadingPalette

/**
 * Find in book: one field over the matches, as the kit found them — reading
 * order, case-insensitive, capped at a hundred. A row is the chapter it came
 * from over the line it sits on, the searched-for words picked out in bold,
 * and tapping it takes the reader there.
 *
 * The query and the results live in the ViewModel, so closing this and
 * opening it again picks up where the reader left off rather than starting
 * over.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchSheet(
    query: String,
    results: List<SearchResult>,
    searching: Boolean,
    capped: Boolean,
    chapters: List<ChapterSummary>,
    onQueryChange: (String) -> Unit,
    onPick: (SearchResult) -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = LocalReadingPalette.current
    val focus = remember { FocusRequester() }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = palette.elevated,
    ) {
        // The field is composed with the sheet rather than as a row of the
        // list below, so it is on screen (and focusable) before the results
        // are, and it does not scroll away under them.
        QueryField(
            query = query,
            onChange = onQueryChange,
            // Enter goes to the first hit, the one the reader is looking at
            // while typing.
            onSubmit = { results.firstOrNull()?.let(onPick) },
            ink = palette.ink,
            faint = palette.faint,
            field = palette.page,
            line = palette.line,
            modifier = Modifier.focusRequester(focus),
        )
        // The sheet exists to be typed into, so it opens with the cursor
        // waiting. A focus request that cannot land is not worth a crash.
        LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 24.dp).testTag("search.list")) {
            // Nothing typed yet: the placeholder says what the field will do,
            // and there is nothing else worth saying.
            if (query.isBlank()) return@LazyColumn
            if (results.isEmpty()) {
                if (!searching) {
                    item {
                        Text(
                            "No matches.",
                            fontFamily = FontFamily.SansSerif,
                            fontSize = 13.sp,
                            color = palette.muted,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp, vertical = 28.dp)
                                .testTag("search.noMatches"),
                        )
                    }
                }
                return@LazyColumn
            }
            items(results, key = { it.id }) { result ->
                ResultRow(
                    result = result,
                    title = result.chapterTitle ?: chapters.getOrNull(result.chapterIndex)?.title.orEmpty(),
                    query = query,
                    onPick = { onPick(result) },
                )
            }
            if (capped) {
                item {
                    Text(
                        "Showing the first ${results.size} matches.",
                        fontFamily = FontFamily.SansSerif,
                        fontSize = 12.sp,
                        color = palette.faint,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 8.dp)
                            .testTag("search.capped"),
                    )
                }
            }
        }
    }
}

@Composable
private fun QueryField(
    query: String,
    onChange: (String) -> Unit,
    onSubmit: () -> Unit,
    ink: Color,
    faint: Color,
    field: Color,
    line: Color,
    modifier: Modifier = Modifier,
) {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 8.dp)
            .background(field, RoundedCornerShape(8.dp))
            .border(1.dp, line, RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 11.dp),
    ) {
        if (query.isEmpty()) {
            Text(
                "Search every chapter of this book.",
                fontSize = 14.sp,
                color = faint,
                fontFamily = FontFamily.SansSerif,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        BasicTextField(
            value = query,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, color = ink),
            cursorBrush = SolidColor(ink),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
            modifier = modifier
                .fillMaxWidth()
                .testTag("reader.search.field")
                .semantics { contentDescription = "Find in book" },
        )
    }
}

/** One hit: where it is, then the line it is on with the words picked out. */
@Composable
private fun ResultRow(result: SearchResult, title: String, query: String, onPick: () -> Unit) {
    val palette = LocalReadingPalette.current
    val snippet = remember(result.snippet, query, palette) { markedSnippet(result.snippet, query, palette.ink) }
    Column(
        Modifier
            .fillMaxWidth()
            .clickable { onPick() }
            .testTag("reader.search.result.${result.id}")
            .padding(horizontal = 20.dp, vertical = 9.dp),
    ) {
        Text(
            title.ifBlank { "Untitled" },
            fontFamily = FontFamily.SansSerif,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = palette.muted,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            snippet,
            fontFamily = FontFamily.Serif,
            fontSize = 14.sp,
            lineHeight = 20.sp,
            color = palette.ink,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 3.dp),
        )
    }
}

/**
 * The snippet with every occurrence of the searched-for text in bold — the
 * same case-insensitive match the kit made, so what is emboldened is what was
 * found. A snippet carries a little context on either side and can hold the
 * term more than once. The context stays in ink rather than going grey: it is
 * body text at reading size, and the weight is difference enough.
 */
fun markedSnippet(snippet: String, query: String, ink: Color): AnnotatedString {
    val needle = query.trim()
    return buildAnnotatedString {
        append(snippet)
        if (needle.isEmpty()) return@buildAnnotatedString
        var from = 0
        while (from <= snippet.length - needle.length) {
            val at = snippet.indexOf(needle, from, ignoreCase = true)
            if (at < 0) break
            addStyle(SpanStyle(fontWeight = FontWeight.Bold, color = ink), at, at + needle.length)
            from = at + needle.length
        }
    }
}
