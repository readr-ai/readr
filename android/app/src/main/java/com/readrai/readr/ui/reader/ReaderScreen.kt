package com.readrai.readr.ui.reader

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.zIndex
import com.readrai.readr.data.ChapterImages
import com.readrai.readr.data.Footnote
import com.readrai.readr.data.Highlight
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.ReadingPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
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

/**
 * The width from which the reader is "regular": literary margins, and a
 * facing-page spread on offer. One constant, so the surface and the
 * Appearance sheet can never disagree about what fits.
 */
val readerRegularWidth = 600.dp

/** The facing-page gutter — one hairline, as `PagedChapterView.spineWidth` on iOS. */
private val spineWidth = 1.dp

/** Swipe distance that turns a page, matching the iOS drag threshold. */
private val turnSwipeDistance = 40.dp

/**
 * The reading surface: the chapter on full-bleed paper — one page, two facing
 * pages, or a continuous scroll — with a running head above and the page
 * label (or the scroll footer) below. The chrome is toggled by a tap in the
 * middle of the page, and while it is up the surface sits *below* the bar
 * rather than under it, so the running head is never covered. Left/right
 * quarters and horizontal swipes turn pages; past a chapter's ends the reader
 * crosses into the next or previous linear chapter.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderScreen(model: ReaderViewModel, settings: ReaderSettings, onBack: () -> Unit) {
    val appearance by settings.appearance.collectAsState()
    val palette = LocalReadingPalette.current
    var showChrome by rememberSaveable { mutableStateOf(true) }
    var sheet by rememberSaveable { mutableStateOf<ReaderSheet?>(null) }
    // The surface's own width test, reported up so the Appearance sheet offers
    // the same layouts the reader can actually draw. The sheet cannot measure
    // it for itself — a modal sheet is capped at 640 dp however wide the
    // window is — and a phone-width window must not be offered two pages.
    var wideSurface by rememberSaveable { mutableStateOf(false) }

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
            is ReaderViewModel.State.Ready -> PageSurface(
                model = model,
                ready = s,
                appearance = appearance,
                palette = palette,
                settings = settings,
                // The bar is chrome over the *window*, not over the page: the
                // surface gives up exactly the bar's own height below the
                // status bar (which `safeDrawingPadding` has already taken)
                // while it is shown, and takes it back when it is hidden. The
                // page is therefore a different height in the two states —
                // which is what the multi-slot `PaginationCache` is for, and
                // why the reading place is the anchor rather than a page
                // number: the page index is re-derived and nothing jumps.
                chromeInset = if (showChrome) TopAppBarDefaults.TopAppBarExpandedHeight else 0.dp,
                onWide = { wideSurface = it },
                onChromeToggle = { showChrome = !showChrome },
            )
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
            ReaderSheet.Appearance -> AppearanceSheet(
                appearance = appearance,
                onChange = settings::update,
                onDismiss = { sheet = null },
                offersDoublePage = wideSurface,
            )
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
 * chapter whose place lies on the visible page (or, in a spread, anywhere on
 * the two of them); tapping adds one at the first drawn character, or takes
 * that one away. A page from the chapter just left is no page at all — the
 * ribbon waits, disabled, until the chapter being read is the chapter on
 * screen.
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

/**
 * The surface's geometry for one layout. `textWidthPx` is the width of **one
 * column** — what is measured and what is keyed — derived from the rounded
 * dp the column is actually laid out at, so what was measured is exactly what
 * is drawn (a half-pixel of drift re-wraps a justified line, and the page
 * then holds one line more than it was cut for).
 */
private class PageGeometry(
    val textWidthPx: Int,
    val pageHeightPx: Int,
    val columnWidth: Dp,
    val blockWidth: Dp,
    /** Where a column's text begins, in surface pixels — the page-turn zones are measured from the surface. */
    val textOriginPx: (Int) -> Float,
)

/**
 * The live selections, one per drawn column: the two pages of a spread, or
 * the chunks a scroll is drawn in. A selection belongs to the glyphs it was
 * made on and dies with them, so each column keeps its own — and only ever one
 * of them is live, because the capsule belongs over the words that were
 * actually tapped and nowhere else.
 *
 * Every slot exists from the start rather than being made when a column first
 * asks for one: [active] is read while the surface composes, and a slot that
 * did not exist yet would be a state nothing was watching — the capsule would
 * never appear, because nothing would recompose when the selection arrived.
 */
private class PageSelections(slots: Int) {
    private val states = List(maxOf(1, slots)) { PageSelectionState() }

    fun of(slot: Int): PageSelectionState = states[slot.coerceIn(states.indices)]

    /** The slot whose selection is live, or null when none is. */
    val active: Int? get() = states.indexOfFirst { it.isActive }.takeIf { it >= 0 }

    fun clear() = states.forEach { it.clear() }
}

/**
 * What the capsule is for: the highlight being edited, or the passage
 * selected — in chapter offsets, through the page's own `textStart` (never
 * `rangeStart`; see [Page]). The quote is the kit's own text, so a copied
 * passage keeps the paragraph breaks the styled string draws as spaces.
 */
private fun annotationTarget(
    page: Page,
    chapterIndex: Int,
    chapterText: String?,
    selection: PageSelectionState,
    edited: Highlight?,
): AnnotationTarget? {
    if (edited != null) return AnnotationTarget.Existing(edited)
    val range = selection.range?.takeIf { !it.collapsed } ?: return null
    if (chapterText == null) return null
    val start = (page.textStart + range.min).coerceIn(0, chapterText.length)
    val end = (page.textStart + range.max).coerceIn(start, chapterText.length)
    return AnnotationTarget.Selected(chapterIndex, start, end, chapterText.substring(start, end))
}

@Composable
private fun PageSurface(
    model: ReaderViewModel,
    ready: ReaderViewModel.State.Ready,
    appearance: ReaderAppearance,
    palette: ReadingPalette,
    settings: ReaderSettings,
    chromeInset: Dp,
    onWide: (Boolean) -> Unit,
    onChromeToggle: () -> Unit,
) {
    val chapter = model.chapter
    val density = LocalDensity.current
    val fontFamilyResolver = LocalFontFamilyResolver.current
    val layoutDirection = LocalLayoutDirection.current
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val lastColor by settings.lastHighlightColor.collectAsState()

    BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().padding(top = chromeInset)) {
        val wide = maxWidth >= readerRegularWidth
        LaunchedEffect(wide) { onWide(wide) }
        val compact = !wide
        val insets = if (compact) compactInsets else regularInsets
        val labelBand = if (compact) 24.dp else 28.dp
        // A stored `doublePage` on a narrow window reads as a single page; the
        // preference itself is left alone (see `PageLayout.on`).
        val layout = appearance.layout.on(wide)
        val columns = layout.pagesPerSpread
        val scrolling = layout == PageLayout.Scroll
        val layoutKey = LayoutKey(appearance)
        val textStyle = remember(layoutKey, palette) { ChapterStyling.pageTextStyle(layoutKey, palette) }

        // Each column is at most 33 em wide (65–70 characters a line); the
        // block of columns is centred, and in a spread a hairline spine sits
        // inside it, so the two pages share `block − spine`, not `block`.
        val geometry = with(density) {
            val fontPx = appearance.fontSize.sp.toPx()
            val horizontal = insets.leading.roundToPx() + insets.trailing.roundToPx()
            val spinePx = if (layout == PageLayout.DoublePage) spineWidth.roundToPx() else 0
            val block = minOf(maxWidth.toPx(), (fontPx * 33 + horizontal) * columns)
            val columnWidth = ((block - spinePx) / columns).toDp()
            val columnPx = columnWidth.roundToPx()
            val blockPx = columnPx * columns + spinePx * (columns - 1)
            val left = (maxWidth.roundToPx() - blockPx) / 2f
            PageGeometry(
                textWidthPx = maxOf(1, columnPx - horizontal),
                pageHeightPx = maxOf(
                    1,
                    maxHeight.roundToPx() - insets.top.roundToPx() - insets.bottom.roundToPx() -
                        labelBand.roundToPx() - kickerBand.roundToPx() - ChapterImages.pageMargin.roundToPx(),
                ),
                columnWidth = columnWidth,
                blockWidth = blockPx.toDp(),
                textOriginPx = { column -> left + column * (columnPx + spinePx) + insets.leading.roundToPx() },
            )
        }
        val textWidthPx = geometry.textWidthPx
        val pageHeightPx = geometry.pageHeightPx
        val surfaceWidthPx = with(density) { maxWidth.toPx() }
        // How tall a picture may be drawn. On a cut page that is the page; in
        // a scroll it is the surface with the chrome *down*, so showing and
        // hiding the bar cannot resize a plate — and so cannot re-measure a
        // chapter that has one.
        val imageCeilingPx = if (scrolling) pageHeightPx + with(density) { chromeInset.roundToPx() } else pageHeightPx
        val fallbackLineHeightPx = with(density) { (appearance.fontSize * layoutKey.lineHeightMultiplier).sp.toPx() }

        // One producer for the whole shape of the chapter: the pictures are
        // placed and the text is measured together, off the main thread,
        // because an image decides where the lines fall — a pagination built
        // without them would be thrown away the moment they arrived, and a
        // pagination cached under a key that did not name them could come back
        // beside a different set of pictures. Everything it depends on is in
        // the key; null means "not resolved yet", and nothing is drawn from a
        // set that was measured for a window that has gone.
        val pageKey = chapter?.let {
            PageKey(
                chapterIndex = it.index,
                widthPx = textWidthPx,
                // A scroll fills no page, so its shape must not name a page
                // height: the bar comes and goes all day and re-measuring a
                // chapter each time it does would be the cost of a tap.
                heightPx = if (scrolling) 0 else pageHeightPx,
                imageCeilingPx = imageCeilingPx,
                density = density.density,
                fontScale = density.fontScale,
                layout = layoutKey,
            )
        }
        val pageSet by produceState<PageSet?>(initialValue = null, chapter, pageKey) {
            val loaded = chapter
            val key = pageKey
            value = null
            if (loaded == null || key == null) return@produceState
            // Measurement ignores colour, so the theme is not part of the key.
            val measureStyle = textStyle
            value = withContext(Dispatchers.Default) {
                model.pageSet(key) {
                    val images = ChapterImages.place(
                        archive = model.archive,
                        bookId = model.bookId,
                        images = loaded.images,
                        density = density,
                        textWidthPx = key.widthPx,
                        pageHeightPx = key.imageCeilingPx,
                        fallbackLineHeightPx = fallbackLineHeightPx,
                    )
                    val styled = ChapterStyling.styled(loaded.text, loaded.layout.spans, layoutKey, images)
                    val pages = if (key.heightPx <= 0) {
                        // A scroll cuts no pages: the chapter is drawn in
                        // measurement-sized chunks and nothing is laid out
                        // twice to find out where a page would have ended.
                        LayoutPaginator.chunks(styled)
                    } else {
                        val measurer = TextMeasurer(fontFamilyResolver, density, layoutDirection, cacheSize = 0)
                        LayoutPaginator.paginate(styled, measureStyle, key.widthPx, key.heightPx, measurer)
                    }
                    PageSet(loaded.index, styled, Pagination(pages))
                }
            }
        }
        val set = pageSet
        LaunchedEffect(set, scrolling) {
            val laid = set ?: return@LaunchedEffect
            if (scrolling) model.settleAtChapterEnd() else model.settle(laid.pagination)
        }

        // The pictures themselves, decoded after the pages were measured and
        // drawn, and kept out of the key on purpose: a bitmap landing fills a
        // box that is already exactly the size the archive's header said it
        // would be, so no line moves and nothing re-measures.
        val artwork = remember(set) { mutableStateMapOf<String, ImageBitmap>() }
        LaunchedEffect(set) {
            val styled = set?.styled ?: return@LaunchedEffect
            ChapterImages.load(model.archive, model.bookId, styled.images, textWidthPx) { id, bitmap ->
                artwork[id] = bitmap
            }
        }

        // In a paged layout these are the cut pages; in a scroll they are the
        // chunks it is drawn in. Either way every offset on one is a chapter
        // offset through its own `textStart`.
        val pages = set?.pagination?.pages ?: emptyList()
        // The place is the anchor; the page it falls on is derived here, every
        // time, so a re-pagination (an appearance change, the chrome, a
        // rotation) never moves the reader. A spread starts on an even index,
        // as `Paginator.spreadStart` does.
        val pageIndex = set?.pagination?.pageIndex(model.anchor) ?: 0
        val spreadStart = when {
            scrolling -> 0
            layout == PageLayout.DoublePage -> pageIndex - pageIndex % 2
            else -> pageIndex
        }

        // The bar bookmarks what is on screen, so it has to know which pages
        // those are — and which chapter they belong to, which is the set's,
        // never the ViewModel's: after a jump they differ for one composition.
        val spread = remember(set, spreadStart, layout) {
            val first = pages.getOrNull(spreadStart) ?: return@remember null
            val last = pages.getOrNull(spreadStart + columns - 1) ?: first
            Page(first.rangeStart, last.rangeEnd, first.textStart, last.textEnd, first.wordCount)
        }
        LaunchedEffect(set, spread, scrolling) {
            if (!scrolling) model.showing(set?.chapterIndex ?: -1, spread)
        }

        // The gesture handlers below are keyed on the page set, which a turn
        // does not change, so they read the turn through updated state rather
        // than closing over this composition's page index. A turn moves a
        // whole spread — two pages at a time when two are shown.
        val turn by rememberUpdatedState { direction: Int ->
            if (set != null) {
                val next = spreadStart + direction * columns
                if (next in pages.indices) model.turned(pages[next].rangeStart) else model.overflow(direction)
            }
        }
        val swipeDistancePx = with(density) { turnSwipeDistance.toPx() }

        // Selecting on the page: the selection and the capsule belong to the
        // glyphs on screen, so a turn or a re-pagination drops them. Each
        // column has its own — two pages are two texts, each with its own
        // layout, and a scroll's chunks are as many again — and only one of
        // them is ever live.
        val slotCount = maxOf(2, if (scrolling) pages.size else columns)
        val selections = remember(slotCount) { PageSelections(slotCount) }
        // Which column the capsule was opened in, and on what: a highlight
        // tapped on the left-hand page is not a highlight on the right-hand
        // one, even where the same passage runs across both.
        var edited by remember { mutableStateOf<Pair<Int, String>?>(null) }
        // A tapped link: a note shown in place, or a question before the book
        // hands the reader to another app. Both belong to the page, not to the
        // book, so a turn or a jump leaves them behind.
        var footnote by remember { mutableStateOf<Footnote?>(null) }
        var externalLink by remember { mutableStateOf<Pair<ExternalLinkPrompt, String>?>(null) }
        // A scroll has no turns to drop a selection on, and its anchor moves
        // with every finger: only a new set clears one there.
        LaunchedEffect(set, spreadStart) { selections.clear(); edited = null }
        val annotating = { selections.active != null || edited != null }
        val dismiss = { selections.clear(); edited = null }
        val annotatedSlot = edited?.first ?: selections.active

        // MARK: the scroll layout's place. The anchor is the offset of the
        // first line wholly on screen, and a jump (Contents, search, a
        // bookmark) is the same thing read the other way round: scroll until
        // that line is at the top. `reported` keeps the two apart — an anchor
        // this surface put there is not a jump to obey.
        val lazyScroll = rememberLazyListState()
        var reported by remember(set) { mutableStateOf<Int?>(null) }
        var shown by remember(set) { mutableStateOf<Page?>(null) }
        var restored by remember(set) { mutableStateOf(false) }
        // The "Previous chapter" button is a row of the list too, so the chunk
        // at list index n is chunk n − this.
        val chunkOffset = if (model.neighbour(-1) != null) 1 else 0

        LaunchedEffect(set, scrolling) {
            val laid = set ?: return@LaunchedEffect
            if (!scrolling || laid.pagination.pages.isEmpty()) return@LaunchedEffect
            snapshotFlow { model.anchor }.collect { anchor ->
                if (anchor == reported) return@collect
                val index = laid.pagination.pageIndex(anchor)
                val chunk = laid.pagination.pages[index]
                lazyScroll.scrollToItem(chunkOffset + index)
                // A chunk has no layout until it has been composed, and it is
                // the layout that says which line the anchor is on.
                val result = snapshotFlow { selections.of(index).layout }.filterNotNull().first()
                val length = result.layoutInput.text.length
                val local = (anchor - chunk.textStart).coerceIn(0, maxOf(0, length - 1))
                reported = anchor
                restored = true
                lazyScroll.scrollToItem(chunkOffset + index, result.getLineTop(result.getLineForOffset(local)).toInt())
            }
        }

        LaunchedEffect(set, scrolling) {
            val laid = set ?: return@LaunchedEffect
            if (!scrolling || laid.pagination.pages.isEmpty()) return@LaunchedEffect
            snapshotFlow { lazyScroll.layoutInfo }.collect { info ->
                // Nothing is read from the scroll until the saved place has
                // been scrolled to: where it opens is not where the reader is.
                if (!restored) return@collect
                val visible = info.visibleItemsInfo.firstOrNull { it.key is Int } ?: return@collect
                val index = visible.key as Int
                val chunk = laid.pagination.pages.getOrNull(index) ?: return@collect
                val result = selections.of(index).layout ?: return@collect
                val top = maxOf(0f, (info.viewportStartOffset - visible.offset).toFloat())
                val firstLine = firstLineFrom(result, top)
                val lastLine = firstLineFrom(result, top + (info.viewportEndOffset - info.viewportStartOffset))
                    .coerceAtLeast(firstLine)
                val start = chunk.textStart + result.getLineStart(firstLine)
                val end = chunk.textStart + maxOf(result.getLineStart(firstLine), result.getLineEnd(lastLine, visibleEnd = false))
                val page = Page(start, end, start, end, 0)
                // This fires on every frame of a scroll, and both the bar and
                // the saved place recompose on a report: only a change is one.
                if (page != shown) {
                    shown = page
                    model.showing(laid.chapterIndex, page)
                }
                if (start != model.anchor) {
                    reported = start
                    model.turned(start)
                }
            }
        }

        // One drawn stretch of chapter text — a cut page, or a chunk of the
        // scroll. Both are `Page`s in chapter offsets, so everything written
        // here works either way: selection, highlights, links and the capsule.
        val readingText: @Composable (PageSet, Page, Int, Int) -> Unit = { laid, page, slot, column ->
            // Everything below belongs to the chapter the *pages* came from;
            // `model.chapterIndex` may already be the next one.
            val chapterIndex = laid.chapterIndex
            val selection = selections.of(slot)
            val onPage = model.highlights.filter {
                it.chapterIndex == chapterIndex && it.utf16Start < page.textEnd && it.utf16End > page.textStart
            }
            val content = remember(laid, page, palette, onPage) {
                ChapterStyling.pageText(laid.styled, page.textStart, page.textEnd, palette, onPage)
            }
            val textOriginPx = geometry.textOriginPx(column)
            Text(
                text = content,
                style = textStyle,
                softWrap = true,
                overflow = TextOverflow.Clip,
                // What was measured is what is drawn: the same pictures, at
                // the same sizes, in the same places.
                inlineContent = laid.styled.inlineContent,
                onTextLayout = { selection.layout = it },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag(if (column == 0) "reader.page" else "reader.page.facing")
                    .pageSelection(
                        key = listOf(laid, page, palette, onPage),
                        state = selection,
                        palette = palette,
                    ) { pageOffset, position ->
                        // A tap follows the link under the finger, puts the capsule away, or
                        // opens it on the highlight under the finger; anything else is left to
                        // the page-turn zones behind. A link claims the whole surface — it is a
                        // control the author put there, and a reader who aims at one means it —
                        // while a highlight only claims the middle half of the *surface*: in its
                        // outer quarters the reader is turning the page, whatever happens to be
                        // marked there. (A scroll has no turn zones, so a mark is a mark
                        // wherever it lies.) A tap that landed on no glyph claims nothing at all.
                        val offset = if (pageOffset == NO_CHARACTER) NO_CHARACTER else page.textStart + pageOffset
                        val link = if (offset == NO_CHARACTER) null else laid.styled.linkAt(offset)
                        when {
                            link != null -> {
                                dismiss()
                                val url = link.url
                                if (url != null) {
                                    val prompt = externalLinkPrompt(url)
                                    if (prompt == null) model.report(UNOPENABLE_LINK_MESSAGE)
                                    else externalLink = prompt to url
                                } else {
                                    model.followLink(link.path, link.fragment) { note -> footnote = note }
                                }
                                true
                            }
                            annotating() -> { dismiss(); true }
                            offset == NO_CHARACTER -> false
                            !scrolling &&
                                abs(textOriginPx + position.x - surfaceWidthPx / 2f) >= surfaceWidthPx * 0.25f -> false
                            else -> {
                                val hit = onPage.firstOrNull { offset >= it.utf16Start && offset < it.utf16End }
                                if (hit != null) { edited = slot to hit.id; true } else false
                            }
                        }
                    },
            )
        }

        CompositionLocalProvider(LocalInlineBitmaps provides artwork) {
            Box(
                Modifier
                    .fillMaxSize()
                    .testTag("reader.surface")
                    .pointerInput(set, scrolling) {
                        detectTapGestures { offset ->
                            when {
                                // While the capsule is up, a tap anywhere else puts it away.
                                annotating() -> dismiss()
                                // A scroll has no page edges: every clean tap is the chrome.
                                scrolling -> onChromeToggle()
                                offset.x < size.width * 0.25f -> turn(-1)
                                offset.x > size.width * 0.75f -> turn(1)
                                else -> onChromeToggle()
                            }
                        }
                    }
                    .pointerInput(set, scrolling) {
                        if (scrolling) return@pointerInput
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
            ) {
                Row(Modifier.width(geometry.blockWidth).fillMaxHeight().align(Alignment.TopCenter)) {
                    for (column in 0 until columns) {
                        if (column > 0) {
                            // The gutter, and — when the last spread has one page —
                            // an empty facing page behind it, so the spine stays
                            // where the book's spine is: in the middle.
                            Box(Modifier.width(spineWidth).fillMaxHeight().background(palette.line.copy(alpha = 0.5f)))
                        }
                        Column(
                            Modifier
                                .width(geometry.columnWidth)
                                .fillMaxHeight()
                                .padding(
                                    top = insets.top,
                                    bottom = insets.bottom + labelBand,
                                    start = insets.leading,
                                    end = insets.trailing,
                                ),
                        ) {
                            val chapterTitle = ready.chapters.getOrNull(model.chapterIndex)?.title ?: ""
                            Box(Modifier.height(kickerBand).fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
                                // The band is reserved on every page — it is in the
                                // measured height — but the running head is drawn
                                // once per spread, on the page it opens on.
                                if (column == 0) {
                                    Text(
                                        chapterTitle.uppercase(),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = palette.muted,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.testTag("reader.kicker").semantics { contentDescription = chapterTitle },
                                    )
                                }
                            }
                            Box(Modifier.weight(1f).fillMaxWidth()) {
                                val error = model.chapterError
                                val page = if (scrolling) null else pages.getOrNull(spreadStart + column)
                                when {
                                    error != null -> if (column == 0) {
                                        Text(error, style = MaterialTheme.typography.bodyMedium, color = palette.ink, modifier = Modifier.testTag("reader.error"))
                                    }
                                    set == null -> if (column == 0) {
                                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = palette.muted) }
                                    }
                                    // A scroll is one column of chunks, each drawn by
                                    // the same composable a cut page is drawn by. The
                                    // chapter's ends are where the book carries on:
                                    // the previous chapter above the first line, the
                                    // next one below the last.
                                    scrolling -> LazyColumn(
                                        state = lazyScroll,
                                        modifier = Modifier.fillMaxSize().testTag("reader.scroll"),
                                    ) {
                                        if (chunkOffset > 0) {
                                            item(key = "previous") {
                                                ChapterStep("Previous chapter", palette, tag = "reader.previousChapter") { model.overflow(-1) }
                                            }
                                        }
                                        items(pages.size, key = { it }) { index ->
                                            readingText(set, pages[index], index, 0)
                                        }
                                        if (model.neighbour(1) != null) {
                                            item(key = "next") {
                                                ChapterStep("Next chapter", palette, tag = "reader.nextChapter") { model.overflow(1) }
                                            }
                                        }
                                    }
                                    page != null -> readingText(set, page, column, column)
                                }

                                // The capsule belongs over the column the annotation was
                                // made in — one capsule per tap, however many columns are
                                // drawn — and at the bottom of what the reader can see,
                                // which in a scroll is this box rather than any one chunk.
                                val capsulePage = if (set == null || annotatedSlot == null) null else if (scrolling) {
                                    pages.getOrNull(annotatedSlot).takeIf { column == 0 }
                                } else if (annotatedSlot == column) {
                                    pages.getOrNull(spreadStart + column)
                                } else {
                                    null
                                }
                                val target = if (set == null || annotatedSlot == null || capsulePage == null) null else {
                                    annotationTarget(
                                        page = capsulePage,
                                        chapterIndex = set.chapterIndex,
                                        chapterText = chapter?.takeIf { it.index == set.chapterIndex }?.text,
                                        selection = selections.of(annotatedSlot),
                                        edited = edited?.let { (_, id) -> model.highlights.firstOrNull { it.id == id } },
                                    )
                                }
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
                                            { model.removeHighlight(existing.highlight.id) ; dismiss() }
                                        },
                                    )
                                }
                            }
                        }
                    }
                }

                // The band below the columns: the spread's page label, or — in a
                // scroll, which has no pages to number — how far through the book
                // this chapter is and what is left of it.
                Box(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = insets.bottom, start = insets.leading, end = insets.trailing)
                        .width(geometry.blockWidth - insets.leading - insets.trailing)
                        .height(labelBand),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        scrolling && set != null && pages.isNotEmpty() -> {
                            // What is left of the chapter, from where the reader
                            // has actually scrolled to: the words after the anchor,
                            // which is the chunks below it plus the tail of the one
                            // it is in. No pagination is involved, and none is run.
                            val words = remember(set, pageIndex, model.anchor) {
                                val chunk = pages[pageIndex]
                                val raw = set.styled.text.text
                                val read = LayoutPaginator.wordCount(
                                    raw, chunk.textStart, model.anchor.coerceIn(chunk.textStart, chunk.textEnd),
                                )
                                (set.pagination.wordsRemaining[pageIndex] - read).coerceAtLeast(0)
                            }
                            ScrollFooter(
                                words = words,
                                fraction = readFraction(ready, model.chapterIndex),
                                palette = palette,
                            )
                        }
                        !scrolling && set != null && pages.isNotEmpty() -> {
                            val last = minOf(spreadStart + columns, pages.size)
                            val minutes = LayoutPaginator.minutes(set.pagination.wordsRemaining[spreadStart])
                            val pageText = if (last - spreadStart > 1) {
                                "Pages ${spreadStart + 1}–$last of ${pages.size}"
                            } else {
                                "Page ${spreadStart + 1} of ${pages.size}"
                            }
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

        footnote?.let { note -> FootnoteSheet(note, onDismiss = { footnote = null }) }
        externalLink?.let { (prompt, url) ->
            ExternalLinkDialog(
                prompt = prompt,
                onOpen = {
                    externalLink = null
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (e: RuntimeException) {
                        // Whatever the system objects to — no app for the
                        // scheme, a uri it will not let out of the process, a
                        // permission it will not grant — the reader is told the
                        // same thing, because there is one thing to say.
                        model.report("No app on this device can open that link.")
                    }
                },
                onDismiss = { externalLink = null },
            )
        }
    }
}

/** The first line whose top is at or below `top` — the first one wholly on screen. */
private fun firstLineFrom(layout: TextLayoutResult, top: Float): Int {
    var low = 0
    var high = layout.lineCount - 1
    while (low < high) {
        val middle = (low + high) / 2
        if (layout.getLineTop(middle) >= top) high = middle else low = middle + 1
    }
    return low
}

/** How far through the book's linear chapters the reader is — the iOS scroll footer's fraction. */
private fun readFraction(ready: ReaderViewModel.State.Ready, chapterIndex: Int): Float {
    val total = ready.chapters.count { it.isLinear }
    if (total == 0) return 0f
    val read = ready.chapters.take(chapterIndex + 1).count { it.isLinear }
    return (read.toFloat() / total).coerceIn(0f, 1f)
}

/**
 * The scroll layout's footer: a hairline progress track for the book, and
 * what is left of this chapter from the line the reader has scrolled to —
 * the words still below the anchor, at the kit's own reading speed.
 */
@Composable
private fun ScrollFooter(words: Int, fraction: Float, palette: ReadingPalette) {
    val minutes = LayoutPaginator.minutes(words)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.weight(1f).height(2.dp).background(palette.line).testTag("reader.progress")) {
            Box(Modifier.fillMaxWidth(fraction).height(2.dp).background(palette.ink))
        }
        if (minutes > 0) {
            Text(
                "~$minutes min left in chapter",
                fontSize = 11.sp,
                color = palette.muted,
                fontFamily = FontFamily.SansSerif,
                maxLines = 1,
                modifier = Modifier.testTag("reader.scrollLabel"),
            )
        }
    }
}

/** "Previous chapter" / "Next chapter" — where a scroll runs out of chapter. */
@Composable
private fun ChapterStep(title: String, palette: ReadingPalette, tag: String, onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(vertical = 8.dp), contentAlignment = Alignment.Center) {
        TextButton(onClick = onClick, modifier = Modifier.testTag(tag)) {
            Text(title, fontSize = 13.sp, color = palette.muted, fontFamily = FontFamily.SansSerif)
        }
    }
}
