package com.readrai.readr.ui.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.zIndex
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.ReadingPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.abs

private enum class ReaderSheet { Contents, Search, Appearance, Highlights }

/** How long a reader-facing message stays up before it fades of its own accord. */
private const val MESSAGE_MILLIS = 4_000L

/** Page margins in dp: the Apple reader's compact and regular insets. */
private class PageInsets(val top: Dp, val leading: Dp, val bottom: Dp, val trailing: Dp)

private val compactInsets = PageInsets(28.dp, 24.dp, 22.dp, 24.dp)
private val regularInsets = PageInsets(44.dp, 56.dp, 40.dp, 56.dp)
private val kickerBand = 36.dp

/** Swipe distance that turns a page, matching the iOS drag threshold. */
private val turnSwipeDistance = 40.dp

/**
 * The reading surface: one page of the chapter on full-bleed paper, a
 * running head above, the page label below, the chrome overlaid and toggled
 * by a tap in the middle of the page. Left/right quarters and horizontal
 * swipes turn pages; past a chapter's ends the reader crosses into the
 * next or previous linear chapter.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(model: ReaderViewModel, settings: ReaderSettings, onBack: () -> Unit) {
    val appearance by settings.appearance.collectAsState()
    val palette = LocalReadingPalette.current
    var showChrome by rememberSaveable { mutableStateOf(true) }
    var sheet by rememberSaveable { mutableStateOf<ReaderSheet?>(null) }

    DisposableEffect(model) { onDispose { model.flush() } }

    Box(Modifier.fillMaxSize().background(palette.page)) {
        when (val s = model.state) {
            ReaderViewModel.State.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            is ReaderViewModel.State.Failed -> Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(s.message, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.testTag("reader.error"))
                    TextButton(onClick = onBack) { Text("Back to library") }
                }
            }
            is ReaderViewModel.State.Ready -> PageSurface(model, s, appearance, palette, settings, onChromeToggle = { showChrome = !showChrome })
        }

        // Annotation trouble is the reader's business, briefly and then gone.
        // Keyed on the count, not the words: the same sentence twice running
        // is two messages, and the second gets its own four seconds.
        val message = model.message
        LaunchedEffect(model.messageCount) {
            if (model.message != null) { delay(MESSAGE_MILLIS); model.clearMessage() }
        }
        if (message != null) {
            Snackbar(
                Modifier.align(Alignment.BottomCenter).padding(16.dp).testTag("reader.message"),
                containerColor = palette.elevated,
                contentColor = palette.ink,
            ) { Text(message, style = MaterialTheme.typography.bodyMedium) }
        }

        AnimatedVisibility(visible = showChrome, modifier = Modifier.align(Alignment.TopCenter).zIndex(1f), enter = fadeIn(), exit = fadeOut()) {
            val ready = model.state as? ReaderViewModel.State.Ready
            TopAppBar(
                title = { Text(ready?.title ?: "", style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onBack, modifier = Modifier.testTag("reader.back")) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to library")
                    }
                },
                actions = {
                    if (ready != null) {
                        IconButton(onClick = { sheet = ReaderSheet.Contents }, modifier = Modifier.testTag("reader.toc")) {
                            Icon(Icons.AutoMirrored.Filled.List, contentDescription = "Table of contents")
                        }
                        IconButton(onClick = { sheet = ReaderSheet.Search }, modifier = Modifier.testTag("reader.search")) {
                            Icon(Icons.Filled.Search, contentDescription = "Find in book")
                        }
                        BookmarkAction(model, palette)
                        IconButton(onClick = { sheet = ReaderSheet.Highlights }, modifier = Modifier.testTag("reader.notes").semantics { contentDescription = "Highlights" }) {
                            MarkerGlyph(palette.ink)
                        }
                        IconButton(onClick = { sheet = ReaderSheet.Appearance }, modifier = Modifier.testTag("reader.appearance").semantics { contentDescription = "Appearance" }) {
                            Text("Aa", fontFamily = FontFamily.Serif, fontSize = 17.sp, color = palette.ink)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = palette.background.copy(alpha = 0.96f), titleContentColor = palette.ink),
            )
        }

        val ready = model.state as? ReaderViewModel.State.Ready
        when (sheet) {
            ReaderSheet.Contents -> if (ready != null) ContentsSheet(
                contents = ready.contents,
                chapters = ready.chapters,
                bookmarks = model.bookmarks,
                currentChapter = model.chapterIndex,
                onPick = { row -> sheet = null; model.jump(row.chapterIndex, row.utf16Offset) },
                onPickBookmark = { bookmark -> sheet = null; model.jump(bookmark.chapterIndex, bookmark.utf16Offset) },
                onRemoveBookmark = { bookmark -> model.removeBookmark(bookmark.id) },
                onDismiss = { sheet = null },
            )
            ReaderSheet.Search -> if (ready != null) SearchSheet(
                query = model.searchQuery,
                results = model.searchResults,
                searching = model.searching,
                capped = model.searchCapped,
                chapters = ready.chapters,
                onQueryChange = model::search,
                onPick = { result -> sheet = null; model.jump(result.chapterIndex, result.utf16Offset) },
                onDismiss = { sheet = null },
            )
            ReaderSheet.Appearance -> AppearanceSheet(appearance = appearance, onChange = settings::update, onDismiss = { sheet = null })
            ReaderSheet.Highlights -> if (ready != null) HighlightsSheet(
                highlights = model.highlights,
                chapters = ready.chapters,
                onJump = { highlight -> sheet = null; model.jump(highlight.chapterIndex, highlight.utf16Start) },
                onEditNote = { highlight -> sheet = null; model.noteOnHighlight(highlight) },
                onDelete = { highlight -> model.removeHighlight(highlight.id) },
                onDismiss = { sheet = null },
            )
            null -> Unit
        }

        // The note editor opens over whatever asked for it — the page's capsule
        // or a card in the Highlights sheet — and closes by dropping the draft.
        model.noteDraft?.let { draft ->
            NoteEditor(draft = draft, onSave = model::saveNote, onCancel = model::cancelNote)
        }
    }
}

/**
 * The ribbon in the bar. "The current bookmark" is the first one in this
 * chapter whose place lies on the visible page; tapping adds one at the page's
 * first drawn character, or takes that one away. A page from the chapter just
 * left is no page at all — the ribbon waits, disabled, until the chapter being
 * read is the chapter on screen.
 */
@Composable
private fun BookmarkAction(model: ReaderViewModel, palette: ReadingPalette) {
    val visible = model.visible?.takeIf { it.chapterIndex == model.chapterIndex }
    val current = visible?.let { on ->
        model.bookmarks.firstOrNull { it.chapterIndex == on.chapterIndex && it.utf16Offset in on.page }
    }
    IconButton(
        onClick = {
            if (current != null) model.removeBookmark(current.id)
            else visible?.let { model.addBookmark(it.chapterIndex, it.page.textStart) }
        },
        enabled = visible != null,
        modifier = Modifier
            .testTag("reader.bookmarks")
            .semantics { contentDescription = if (current != null) "Remove bookmark" else "Bookmark this page" },
    ) { BookmarkRibbon(filled = current != null, color = palette.ink) }
}

/** A highlighter's slanted nib over its mark — the Highlights sheet's button. */
@Composable
private fun MarkerGlyph(color: Color) {
    Canvas(Modifier.size(18.dp)) {
        val w = size.width
        val h = size.height
        val nib = Path().apply {
            moveTo(w * 0.14f, h * 0.58f)
            lineTo(w * 0.58f, h * 0.14f)
            lineTo(w * 0.84f, h * 0.40f)
            lineTo(w * 0.40f, h * 0.84f)
            close()
        }
        drawPath(nib, color, style = Stroke(width = 1.4.dp.toPx()))
        drawLine(color, Offset(w * 0.10f, h * 0.95f), Offset(w * 0.90f, h * 0.95f), strokeWidth = 2.dp.toPx())
    }
}

@Composable
private fun PageSurface(
    model: ReaderViewModel,
    ready: ReaderViewModel.State.Ready,
    appearance: ReaderAppearance,
    palette: ReadingPalette,
    settings: ReaderSettings,
    onChromeToggle: () -> Unit,
) {
    val chapter = model.chapter
    val density = LocalDensity.current
    val fontFamilyResolver = LocalFontFamilyResolver.current
    val layoutDirection = LocalLayoutDirection.current
    val clipboard = LocalClipboardManager.current
    val lastColor by settings.lastHighlightColor.collectAsState()

    BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
        val compact = maxWidth < 600.dp
        val insets = if (compact) compactInsets else regularInsets
        val labelBand = if (compact) 24.dp else 28.dp
        val layoutKey = LayoutKey(appearance)
        val textStyle = remember(layoutKey, palette) { ChapterStyling.pageTextStyle(layoutKey, palette) }

        // The column is at most 33 em wide (65–70 characters a line), centred.
        val geometry = with(density) {
            val fontPx = appearance.fontSize.sp.toPx()
            val horizontal = insets.leading.toPx() + insets.trailing.toPx()
            val column = minOf(maxWidth.toPx(), fontPx * 33 + horizontal)
            val textWidth = maxOf(1f, column - horizontal)
            val pageHeight = maxOf(
                1f,
                maxHeight.toPx() - insets.top.toPx() - insets.bottom.toPx() - labelBand.toPx() - kickerBand.toPx() - 4.dp.toPx(),
            )
            Triple(textWidth.toInt(), pageHeight.toInt(), column.toDp())
        }
        val (textWidthPx, pageHeightPx, columnWidth) = geometry
        // The text column is centred on the surface, so a distance from the
        // column's middle is a distance from the surface's — which is what the
        // page-turn zones are measured in.
        val surfaceWidthPx = with(density) { maxWidth.toPx() }

        val pageKey = chapter?.let { PageKey(it.index, textWidthPx, pageHeightPx, density.density, density.fontScale, layoutKey) }
        val pageSet by produceState<PageSet?>(initialValue = null, chapter, pageKey) {
            val loaded = chapter
            val key = pageKey
            if (loaded == null || key == null) { value = null; return@produceState }
            // Measurement ignores colour, so the theme is not part of the key.
            val measureStyle = textStyle
            value = withContext(Dispatchers.Default) {
                model.pageSet(key) {
                    val styled = ChapterStyling.styled(loaded.text, loaded.layout.spans, layoutKey)
                    val measurer = TextMeasurer(fontFamilyResolver, density, layoutDirection, cacheSize = 0)
                    PageSet(loaded.index, styled, Pagination(LayoutPaginator.paginate(styled, measureStyle, textWidthPx, pageHeightPx, measurer)))
                }
            }
        }
        val set = pageSet
        LaunchedEffect(set) { if (set != null) model.settle(set.pagination) }

        val pages = set?.pagination?.pages ?: emptyList()
        val pageIndex = set?.pagination?.pageIndex(model.anchor) ?: 0
        // The bar bookmarks the page, so it has to know which page is on screen
        // — and which chapter that page belongs to, which is the set's, never
        // the ViewModel's: after a jump they differ for one composition.
        LaunchedEffect(set, pageIndex) { model.showing(set?.chapterIndex ?: -1, pages.getOrNull(pageIndex)) }
        // The gesture handlers below are keyed on the page set, which a turn
        // does not change, so they read the turn through updated state rather
        // than closing over this composition's page index.
        val turn by rememberUpdatedState { direction: Int ->
            if (set != null) {
                val next = pageIndex + direction
                if (next in pages.indices) model.turned(pages[next].rangeStart) else model.overflow(direction)
            }
        }
        val swipeDistancePx = with(density) { turnSwipeDistance.toPx() }

        // Selecting on the page: the selection and the capsule belong to the
        // glyphs on screen, so a turn or a re-pagination drops them.
        val selection = remember { PageSelectionState() }
        var editedId by remember { mutableStateOf<String?>(null) }
        LaunchedEffect(set, pageIndex) { selection.clear(); editedId = null }
        val annotating = { selection.isActive || editedId != null }
        val dismiss = { selection.clear(); editedId = null }

        Column(
            Modifier
                .fillMaxSize()
                .pointerInput(set) {
                    detectTapGestures { offset ->
                        when {
                            // While the capsule is up, a tap anywhere else puts it away.
                            annotating() -> dismiss()
                            offset.x < size.width * 0.25f -> turn(-1)
                            offset.x > size.width * 0.75f -> turn(1)
                            else -> onChromeToggle()
                        }
                    }
                }
                .pointerInput(set) {
                    var dragged = 0f
                    detectHorizontalDragGestures(
                        onDragStart = { dragged = 0f },
                        onDragEnd = {
                            // A swipe with a selection or a capsule up puts it away
                            // rather than turning the page out from under it.
                            if (abs(dragged) > swipeDistancePx) {
                                if (annotating()) dismiss() else turn(if (dragged < 0) 1 else -1)
                            }
                        },
                        onDragCancel = { dragged = 0f },
                    ) { _, amount -> dragged += amount }
                },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(
                Modifier
                    .width(columnWidth)
                    .fillMaxHeight()
                    .padding(top = insets.top, bottom = insets.bottom, start = insets.leading, end = insets.trailing),
            ) {
                val chapterTitle = ready.chapters.getOrNull(model.chapterIndex)?.title ?: ""
                Box(Modifier.height(kickerBand).fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
                    Text(
                        chapterTitle.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = palette.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.testTag("reader.kicker").semantics { contentDescription = chapterTitle },
                    )
                }
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    val error = model.chapterError
                    when {
                        error != null -> Text(error, style = MaterialTheme.typography.bodyMedium, color = palette.ink, modifier = Modifier.testTag("reader.error"))
                        set == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = palette.muted) }
                        pages.isNotEmpty() -> {
                            val page = pages[pageIndex]
                            // Everything below belongs to the chapter the *pages* came
                            // from; `model.chapterIndex` may already be the next one.
                            val chapterIndex = set.chapterIndex
                            val onPage = model.highlights.filter {
                                it.chapterIndex == chapterIndex && it.utf16Start < page.textEnd && it.utf16End > page.textStart
                            }
                            val content = remember(set, pageIndex, palette, onPage) {
                                ChapterStyling.pageText(set.styled, page.textStart, page.textEnd, palette, onPage)
                            }
                            // The quote is the kit's own text: the styled string draws
                            // every newline as a space, and a copied passage keeps its
                            // paragraph breaks.
                            val chapterText = chapter?.takeIf { it.index == chapterIndex }?.text
                            val edited = editedId?.let { id -> onPage.firstOrNull { it.id == id } }
                            val range = selection.range
                            val target: AnnotationTarget? = when {
                                edited != null -> AnnotationTarget.Existing(edited)
                                range != null && !range.collapsed && chapterText != null -> {
                                    val start = (page.textStart + range.min).coerceIn(0, chapterText.length)
                                    val end = (page.textStart + range.max).coerceIn(start, chapterText.length)
                                    AnnotationTarget.Selected(
                                        chapterIndex = chapterIndex,
                                        utf16Start = start,
                                        utf16End = end,
                                        quotedText = chapterText.substring(start, end),
                                    )
                                }
                                else -> null
                            }
                            Text(
                                text = content,
                                style = textStyle,
                                softWrap = true,
                                overflow = TextOverflow.Clip,
                                onTextLayout = { selection.layout = it },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag("reader.page")
                                    .pageSelection(
                                        key = listOf(set, pageIndex, palette, onPage),
                                        state = selection,
                                        palette = palette,
                                    ) { pageOffset, position ->
                                        // A tap puts the capsule away, or opens it on the highlight under the finger;
                                        // anything else is left to the page-turn zones behind. A highlight only
                                        // claims the middle half of the surface: in the outer quarters the reader
                                        // is turning the page, whatever happens to be marked under the finger.
                                        if (target != null) {
                                            dismiss()
                                            true
                                        } else if (abs(position.x - textWidthPx / 2f) >= surfaceWidthPx * 0.25f) {
                                            false
                                        } else {
                                            val offset = page.textStart + pageOffset
                                            val hit = onPage.firstOrNull { offset >= it.utf16Start && offset < it.utf16End }
                                            if (hit != null) { editedId = hit.id; true } else false
                                        }
                                    },
                            )
                            if (target != null) {
                                AnnotationCapsule(
                                    target = target,
                                    palette = palette,
                                    onHighlight = { color ->
                                        when (target) {
                                            is AnnotationTarget.Existing -> model.recolor(target.highlight.id, color)
                                            is AnnotationTarget.Selected -> {
                                                model.addHighlight(target.chapterIndex, target.utf16Start, target.utf16End, color)
                                                dismiss()
                                            }
                                        }
                                        settings.rememberHighlightColor(color)
                                    },
                                    onCopy = { clipboard.setText(AnnotatedString(target.quotedText)); dismiss() },
                                    onNote = { noted ->
                                        when (noted) {
                                            // A note needs a highlight to live on: make one in the
                                            // colour last used, and the editor opens on it.
                                            is AnnotationTarget.Selected ->
                                                model.noteOnSelection(noted.chapterIndex, noted.utf16Start, noted.utf16End, lastColor)
                                            is AnnotationTarget.Existing -> model.noteOnHighlight(noted.highlight)
                                        }
                                        dismiss()
                                    },
                                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 4.dp),
                                    onRemove = (target as? AnnotationTarget.Existing)?.let { existing ->
                                        { model.removeHighlight(existing.highlight.id); dismiss() }
                                    },
                                )
                            }
                        }
                    }
                }
                Box(Modifier.height(labelBand).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (set != null && pages.isNotEmpty()) {
                        val minutes = LayoutPaginator.minutes(set.pagination.wordsRemaining[pageIndex])
                        val pageText = "Page ${pageIndex + 1} of ${pages.size}"
                        val suffix = if (compact) "min left" else "min left in chapter"
                        Text(
                            if (minutes > 0) "$pageText · ~$minutes $suffix" else pageText,
                            fontSize = 11.sp,
                            color = palette.muted,
                            fontFamily = FontFamily.SansSerif,
                            maxLines = 1,
                            modifier = Modifier.testTag("reader.pageLabel"),
                        )
                    }
                }
            }
        }
    }
}
