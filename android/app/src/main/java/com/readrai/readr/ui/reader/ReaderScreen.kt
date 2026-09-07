package com.readrai.readr.ui.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import kotlinx.coroutines.withContext
import kotlin.math.abs

private enum class ReaderSheet { Contents, Appearance }

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
            is ReaderViewModel.State.Ready -> PageSurface(model, s, appearance, palette, onChromeToggle = { showChrome = !showChrome })
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
                currentChapter = model.chapterIndex,
                onPick = { row -> sheet = null; model.jump(row.chapterIndex, row.utf16Offset) },
                onDismiss = { sheet = null },
            )
            ReaderSheet.Appearance -> AppearanceSheet(appearance = appearance, onChange = settings::update, onDismiss = { sheet = null })
            null -> Unit
        }
    }
}

@Composable
private fun PageSurface(
    model: ReaderViewModel,
    ready: ReaderViewModel.State.Ready,
    appearance: ReaderAppearance,
    palette: ReadingPalette,
    onChromeToggle: () -> Unit,
) {
    val chapter = model.chapter
    val density = LocalDensity.current
    val fontFamilyResolver = LocalFontFamilyResolver.current
    val layoutDirection = LocalLayoutDirection.current

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
                    PageSet(styled, Pagination(LayoutPaginator.paginate(styled, measureStyle, textWidthPx, pageHeightPx, measurer)))
                }
            }
        }
        val set = pageSet
        LaunchedEffect(set) { if (set != null) model.settle(set.pagination) }

        val pages = set?.pagination?.pages ?: emptyList()
        val pageIndex = set?.pagination?.pageIndex(model.anchor) ?: 0
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

        Column(
            Modifier
                .fillMaxSize()
                .pointerInput(set) {
                    detectTapGestures { offset ->
                        when {
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
                        onDragEnd = { if (abs(dragged) > swipeDistancePx) turn(if (dragged < 0) 1 else -1) },
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
                            val content = remember(set, pageIndex, palette) { ChapterStyling.pageText(set.styled, page.textStart, page.textEnd, palette) }
                            Text(
                                text = content,
                                style = textStyle,
                                softWrap = true,
                                overflow = TextOverflow.Clip,
                                modifier = Modifier.fillMaxWidth().testTag("reader.page"),
                            )
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
