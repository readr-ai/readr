package com.readrai.readr.ui.reader

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.ChapterSummary
import com.readrai.readr.data.Footnote
import com.readrai.readr.ui.theme.LocalReadingPalette

/**
 * A link span on the page: the stretch of chapter text it covers (UTF-16, as
 * everything on this side of the bridge is) and where it points. Exactly one
 * of `url` (out of the book) and `path` (into it) is set; `fragment` is the
 * element id after the `#`, which may name an anchor or a footnote.
 */
data class ChapterLink(
    val start: Int,
    val end: Int,
    val url: String? = null,
    val path: String? = null,
    val fragment: String? = null,
) {
    val isExternal: Boolean get() = url != null
}

/** Where an internal link lands: a chapter, and a place in it. */
data class LinkDestination(val chapterIndex: Int, val utf16Offset: Int)

/**
 * The chapter an internal link's archive path names, and the place in it its
 * fragment names. Matching follows the Apple reader: the exact `sourcePath`
 * first, then case-insensitively (hrefs and archive paths drift in case), and
 * only then on the file name — a link written relative to a directory the
 * spine spells differently still finds its document. A suffix match must fall
 * on a path separator, so `notes.xhtml` never claims `endnotes.xhtml`.
 *
 * `anchors` are the *target* chapter's, which the caller loads once the
 * chapter is known; a fragment that names none lands at the chapter's start,
 * as a TOC row with an unresolvable fragment does. Null when no chapter in
 * the book answers to the path.
 */
fun resolveInternalLink(
    chapters: List<ChapterSummary>,
    path: String,
    fragment: String?,
    anchors: Map<String, Int>,
): LinkDestination? {
    val index = chapterIndexForPath(chapters, path) ?: return null
    val offset = fragment?.let { anchors[it] } ?: 0
    return LinkDestination(index, maxOf(0, offset))
}

private fun chapterIndexForPath(chapters: List<ChapterSummary>, path: String): Int? {
    if (path.isEmpty()) return null
    chapters.firstOrNull { it.sourcePath == path }?.let { return it.index }
    val lowered = path.lowercase()
    chapters.firstOrNull { it.sourcePath?.lowercase() == lowered }?.let { return it.index }
    return chapters.firstOrNull { chapter ->
        val source = chapter.sourcePath?.lowercase() ?: return@firstOrNull false
        source.endsWith("/$lowered") || lowered.endsWith("/$source")
    }?.index
}

/**
 * A footnote, in place: the note's text on a sheet the size of the note, in
 * the page's serif so it reads as part of the book rather than as chrome.
 * The body scrolls, because an endnote can run long.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FootnoteSheet(footnote: Footnote, onDismiss: () -> Unit) {
    val palette = LocalReadingPalette.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = palette.elevated,
        modifier = Modifier.testTag("footnote.sheet"),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(start = 24.dp, end = 24.dp, bottom = 32.dp),
        ) {
            Text("NOTE", style = MaterialTheme.typography.labelSmall, color = palette.muted)
            Text(
                footnote.text.trim(),
                fontFamily = FontFamily.Serif,
                fontSize = 16.sp,
                lineHeight = 25.sp,
                color = palette.ink,
                modifier = Modifier.padding(top = 10.dp).testTag("footnote.text"),
            )
        }
    }
}

/**
 * A link out of the book asks first, and says where it goes: the host is the
 * one part of a URL a reader can judge, so it is what the question shows.
 */
@Composable
fun ExternalLinkDialog(url: String, onOpen: () -> Unit, onDismiss: () -> Unit) {
    val palette = LocalReadingPalette.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = palette.elevated,
        title = { Text("Open link?", color = palette.ink) },
        text = {
            Text(
                linkHost(url),
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
                modifier = Modifier.testTag("link.host"),
            )
        },
        confirmButton = { TextButton(onClick = onOpen, modifier = Modifier.testTag("link.open")) { Text("Open") } },
        dismissButton = { TextButton(onClick = onDismiss, modifier = Modifier.testTag("link.cancel")) { Text("Cancel") } },
        modifier = Modifier.testTag("link.dialog"),
    )
}

/**
 * What to show for a link: its host, or the whole thing when it has none
 * (`mailto:`, and anything malformed). Parsed without `android.net.Uri` so
 * the rule is the same under a unit test as on a device.
 */
fun linkHost(url: String): String {
    val afterScheme = url.substringAfter("://", missingDelimiterValue = "")
    if (afterScheme.isEmpty()) return url.take(120)
    val authority = afterScheme.substringBefore('/').substringBefore('?').substringBefore('#')
    val host = authority.substringAfterLast('@').substringBefore(':')
    return host.ifBlank { url.take(120) }
}
