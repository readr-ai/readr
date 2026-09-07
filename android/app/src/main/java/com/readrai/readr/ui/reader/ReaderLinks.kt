package com.readrai.readr.ui.reader

import android.net.Uri
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

/**
 * The chapter an internal link's archive path names. Matching follows the
 * Apple reader (`ReaderView.spineIndex`): the exact `sourcePath` first, then
 * case-insensitively (hrefs and archive paths drift in case), and only then on
 * the file name — a link written relative to a directory the spine spells
 * differently still finds its document. A suffix match must fall on a path
 * separator, so `notes.xhtml` never claims `endnotes.xhtml`. Null when no
 * chapter in the book answers to the path.
 */
fun chapterIndexForPath(chapters: List<ChapterSummary>, path: String): Int? {
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
 * Which chapter's footnotes a tapped noteref is answered from: the *target*
 * document when the path names a spine entry, and the chapter being read when
 * it names none, names this one, or there is no path at all (a same-document
 * ref).
 *
 * This is the Apple reader's `resolveFootnote` rule, and the whole of it: note
 * ids (`fn1`, `fn2`…) recur document by document, so a link that resolves
 * somewhere *else* must never be answered by a same-id note out of the chapter
 * in hand. When the target lifts no such note, the tap is navigation.
 */
fun noterefChapter(chapters: List<ChapterSummary>, path: String?, currentChapter: Int): Int =
    path?.let { chapterIndexForPath(chapters, it) } ?: currentChapter

/**
 * The question asked before a link leaves the book: what the reader is about
 * to do, and the one part of the link they can judge — the host for the web,
 * the address or the number for the rest.
 */
data class ExternalLinkPrompt(val title: String, val detail: String)

/** What is said about a link Readr will not hand to another app. */
const val UNOPENABLE_LINK_MESSAGE = "Readr can't open that kind of link."

/** Longer than any honest link in a book; a URL past this is not asked about. */
private const val MAX_LINK_LENGTH = 2_048

/**
 * Whether a link may leave the app, and what to ask about it. Only the web
 * (`http`, `https`), mail and the telephone are ever handed on: `file`,
 * `content`, `intent`, `javascript`, `data`, `market` and everything unknown
 * are refused before an `Intent` is built, because an author's markup is not
 * a reason to open a device's own scheme, and an implicit `ACTION_VIEW` is not
 * a thing to point at an arbitrary one.
 *
 * A URL holding a backslash, whitespace or a control character is refused
 * outright: those are how one parser is made to read a different host than the
 * next, and nothing in a book needs them. What is left is parsed with
 * `android.net.Uri` — the same parser the `Intent` will use, so what the reader
 * is shown is what the system will act on — and a web link whose host that
 * parser cannot name is refused too. Null means "do not open this".
 */
fun externalLinkPrompt(url: String): ExternalLinkPrompt? {
    if (url.isEmpty() || url.length > MAX_LINK_LENGTH) return null
    if (url.any { it == '\\' || it.isWhitespace() || it.isISOControl() }) return null
    val parsed = runCatching { Uri.parse(url) }.getOrNull() ?: return null
    val target = parsed.schemeSpecificPart?.substringBefore('?').orEmpty().trim()
    return when (parsed.scheme?.lowercase()) {
        "http", "https" -> parsed.host?.takeIf { it.isNotBlank() }?.let { ExternalLinkPrompt("Open link?", it) }
        "mailto" -> target.takeIf { it.isNotBlank() }?.let { ExternalLinkPrompt("Send an email to…", it) }
        "tel" -> target.takeIf { it.isNotBlank() }?.let { ExternalLinkPrompt("Call…", it) }
        else -> null
    }
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
 * A link out of the book asks first, and says where it goes: the host (or the
 * address, or the number) is the one part of a link a reader can judge, so it
 * is what the question shows.
 */
@Composable
fun ExternalLinkDialog(prompt: ExternalLinkPrompt, onOpen: () -> Unit, onDismiss: () -> Unit) {
    val palette = LocalReadingPalette.current
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = palette.elevated,
        title = { Text(prompt.title, color = palette.ink) },
        text = {
            Text(
                prompt.detail,
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
