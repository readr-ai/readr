package com.readrai.readr.ui.ask

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.PaddingValues
import com.readrai.readr.data.AskCitation
import com.readrai.readr.data.AskTier
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.Marginalia
import com.readrai.readr.ui.theme.ReadingPalette
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.conflate

/**
 * "Ask the book" — the Android side of `App/Ask/AskPanelView`.
 *
 * A full-height sheet: the passage (or where the reader is) at the top, the
 * conversation under it, and a composer pinned to the bottom with the
 * grounding promise beneath. Opened from a text book it is spoiler-scoped —
 * answers see only what has been read — and the ANSWERS FROM control lifts
 * that for the questions that follow.
 *
 * Every failure sentence and every position line comes from the kit through
 * the facade; what this file writes is labels.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AskSheet(
    model: AskViewModel,
    onDismiss: () -> Unit,
    onShowInBook: (chapterIndex: Int, utf16Offset: Int) -> Unit,
    onOpenProviders: () -> Unit,
) {
    val palette = LocalReadingPalette.current
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // Every time the sheet appears — including on the way back from the
    // provider settings — the provider is resolved again, so a key saved
    // there takes effect without restarting the app.
    LaunchedEffect(Unit) { model.refresh() }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = state,
        containerColor = palette.background,
        contentColor = palette.ink,
        modifier = Modifier.fillMaxHeight(),
    ) {
        Column(Modifier.fillMaxHeight().imePadding()) {
            Header(model, palette)
            Box(Modifier.fillMaxWidth().height(1.dp).background(palette.line))
            when (model.hasProvider) {
                null -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                false -> NoProvider(model.setupGuidance, palette, Modifier.weight(1f), onOpenProviders)
                true -> {
                    Transcript(model, palette, Modifier.weight(1f), onShowInBook = { chapter, offset ->
                        onShowInBook(chapter, offset)
                        onDismiss()
                    })
                    Composer(model, palette)
                }
            }
        }
    }
}

@Composable
private fun Header(model: AskViewModel, palette: ReadingPalette) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            "${Marginalia.aiGlyph}  Ask the book",
            style = MaterialTheme.typography.titleMedium,
            color = palette.ink,
            modifier = Modifier.testTag("ask.header"),
        )
        Spacer(Modifier.weight(1f))
        if (model.exchanges.isNotEmpty()) {
            TextButton(
                onClick = { model.startOver() },
                modifier = Modifier.testTag("ask.newConversation"),
            ) { Text("New conversation", fontSize = 12.sp, color = palette.muted) }
        }
    }
}

/**
 * Nothing connected: the guidance carries a button, not just directions —
 * the same actionable empty state the Apple panel shows.
 */
@Composable
private fun NoProvider(
    guidance: String,
    palette: ReadingPalette,
    modifier: Modifier,
    onOpenProviders: () -> Unit,
) {
    Column(
        modifier.fillMaxWidth().padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(Marginalia.aiGlyph, fontSize = 26.sp, color = palette.iris)
        Text(
            "No AI provider connected",
            style = MaterialTheme.typography.titleMedium,
            color = palette.ink,
            textAlign = TextAlign.Center,
        )
        Text(
            guidance,
            style = MaterialTheme.typography.bodyMedium,
            color = palette.muted,
            textAlign = TextAlign.Center,
            modifier = Modifier.testTag("ask.setupGuidance"),
        )
        Spacer(Modifier.height(4.dp))
        Box(
            Modifier
                .clip(RoundedCornerShape(9.dp))
                .background(palette.ink)
                .clickable(onClick = onOpenProviders)
                .padding(horizontal = 18.dp, vertical = 10.dp)
                .testTag("ask.openProviders"),
        ) {
            Text("Open AI Providers", color = palette.background, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
        }
    }
}

@Composable
private fun Transcript(
    model: AskViewModel,
    palette: ReadingPalette,
    modifier: Modifier,
    onShowInBook: (Int, Int) -> Unit,
) {
    val listState = rememberLazyListState()
    // A list, not a column in a scroller: a long conversation would otherwise
    // measure and lay out every answer in it on every streamed token.
    //
    // Followed down as it grows, by ONE driver: a new turn and the answer
    // growing inside it are the same event as far as the transcript is
    // concerned, and two effects racing for the scroll mutex meant the loser
    // was cancelled — which, on the effect keyed by the turn count, took the
    // scroll for that turn with it. Conflated, so a fast stream produces one
    // scroll per frame rather than one per delta.
    LaunchedEffect(listState) {
        snapshotFlow { model.exchanges.size to (model.exchanges.lastOrNull()?.answerText?.length ?: 0) }
            .conflate()
            .collect {
                try {
                    listState.scrollToEnd()
                } catch (e: CancellationException) {
                    // A scroll interrupted by another one — a drag, or the
                    // next delta — is reported as MutationInterruptedException,
                    // a CancellationException that would otherwise end this
                    // collector and leave the transcript stuck where it was.
                    // The collector's own cancellation still ends it: that
                    // one is on the coroutine.
                    currentCoroutineContext().ensureActive()
                }
            }
    }
    LazyColumn(
        modifier.fillMaxWidth().padding(horizontal = 20.dp).testTag("ask.transcript"),
        state = listState,
        contentPadding = PaddingValues(top = 14.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item(key = "context") { ContextHeader(model, palette) }
        // Keyed by the turn's own id, so a re-composition moves nothing: the
        // answer growing in the last one must not re-key the ones above it.
        items(model.exchanges, key = { it.id }) { exchange ->
            ExchangeView(exchange, palette, onShowInBook)
        }
        if (model.isStreaming && model.exchanges.lastOrNull()?.answerText.isNullOrEmpty()) {
            item(key = "thinking") { ThinkingDots(palette.iris) }
        }
    }
}

/**
 * The bottom of the last item, not its top: `scrollToItem` aligns an item's
 * start with the viewport's, which on an answer taller than the sheet would
 * leave the words being written below the fold.
 */
private suspend fun LazyListState.scrollToEnd() {
    val last = layoutInfo.totalItemsCount - 1
    if (last < 0) return
    scrollToItem(last)
    val info = layoutInfo
    val item = info.visibleItemsInfo.lastOrNull { it.index == last } ?: return
    val overflow = item.size - (info.viewportEndOffset - info.viewportStartOffset)
    if (overflow > 0) scrollBy(overflow.toFloat())
}

/**
 * What the question is anchored to: the selected sentence, or where the
 * reader is — with the scope choice beneath whenever there is a reading
 * position to scope to.
 */
@Composable
private fun ContextHeader(model: AskViewModel, palette: ReadingPalette) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val quoted = model.selection?.quotedText.orEmpty()
        if (quoted.isNotBlank()) {
            QuotedText(quoted, palette, Modifier.testTag("ask.quote"))
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(BOOK_GLYPH, fontSize = 13.sp, color = palette.muted)
                    Text(
                        headline(model),
                        style = MaterialTheme.typography.bodyMedium,
                        color = palette.muted,
                    )
                }
                val caption = model.position?.caption
                if (model.isScoped && caption != null) {
                    Text(
                        caption,
                        fontSize = 12.sp,
                        color = palette.faint,
                        modifier = Modifier.testTag("ask.position"),
                    )
                }
            }
        }
        if (model.frontier != null) ScopePicker(model, palette)
    }
}

private fun headline(model: AskViewModel): String =
    if (model.isScoped) "Ask about what you've read so far" else "Ask anything about this book"

/**
 * "Up to where I am" or "Whole book": two scopes to pick between, not a
 * feature to switch on — off, a switch gave no hint the other scope existed.
 * Changing it changes every question sent after; the answers already on
 * screen keep the scope they were asked under.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScopePicker(model: AskViewModel, palette: ReadingPalette) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("ANSWERS FROM", style = MaterialTheme.typography.labelSmall, color = palette.faint)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().testTag("ask.scope")) {
            SegmentedButton(
                selected = !model.wholeBook,
                onClick = { model.wholeBook = false },
                shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                modifier = Modifier.testTag("ask.scope.upToHere"),
            ) { Text("Up to where I am", fontSize = 13.sp, maxLines = 1) }
            SegmentedButton(
                selected = model.wholeBook,
                onClick = { model.wholeBook = true },
                shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                modifier = Modifier.testTag("ask.scope.wholeBook"),
            ) { Text("Whole book", fontSize = 13.sp, maxLines = 1) }
        }
        Text(
            if (model.wholeBook) "Answers may use the whole book, including what you haven’t read."
            else "Answers stop where you stopped reading — no spoilers.",
            fontSize = 12.sp,
            color = palette.faint,
            modifier = Modifier.testTag("ask.scopeNote"),
        )
    }
}

/**
 * One turn of the conversation. Everything it draws is ON the exchange —
 * which is `@Immutable` — so a state write anywhere else in the sheet skips
 * it, and nothing it draws costs a call across the bridge.
 */
@Composable
private fun ExchangeView(
    exchange: AskExchange,
    palette: ReadingPalette,
    onShowInBook: (Int, Int) -> Unit,
) {
    Column(
        Modifier.testTag("ask.exchange.${exchange.id}"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SentQuestion(exchange.question, palette)
        val failure = exchange.failure
        if (exchange.answerText.isNotBlank()) {
            Answer(exchange, palette)
        }
        if (failure != null) {
            // Under the question it belongs to, and for good: the composer's
            // error card is cleared by the next question, and a transcript
            // that then shows a question with nothing under it says the app
            // lost the answer rather than that this one failed.
            Column(
                Modifier.testTag("ask.exchangeFailure.${exchange.id}"),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(failure, style = MaterialTheme.typography.bodyMedium, color = palette.muted)
                exchange.failureRecovery?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.sp, color = palette.faint)
                }
            }
        } else if (exchange.isEmpty) {
            // The stream ended with nothing worth showing. A blank bubble over
            // a Sources list reads as a broken app; say what happened.
            Text(
                "The model couldn’t find an answer to that in the book. Try asking about something that happens in it.",
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
                modifier = Modifier.testTag("ask.emptyAnswer"),
            )
        }
        val citations = exchange.citations
        when {
            exchange.answerText.isBlank() -> Unit
            exchange.tier == AskTier.RETRIEVAL && !citations.isEmpty ->
                Sources(citations.items, palette, onShowInBook)
            exchange.tier == AskTier.WHOLE_BOOK -> WholeBookNote(exchange.scoped, palette)
        }
    }
}

/** The reader's own message, in an iris-tinted bubble: it has to look SENT. */
@Composable
private fun SentQuestion(text: String, palette: ReadingPalette) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = palette.ink,
            modifier = Modifier
                .clip(RoundedCornerShape(14.dp))
                .background(palette.iris.copy(alpha = 0.12f))
                .border(1.dp, palette.iris.copy(alpha = 0.22f), RoundedCornerShape(14.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .testTag("ask.sentQuestion")
                .semantics { contentDescription = "You asked: $text" },
        )
    }
}

/**
 * The answer as it stands. While it streams there are no blocks yet — the
 * kit's parser is a bridge call, and composition is the last place to make
 * one — so the text is drawn as paragraphs with their inline bold; the
 * finished answer's real structure arrives on the exchange a moment later
 * and replaces it.
 */
@Composable
private fun Answer(exchange: AskExchange, palette: ReadingPalette) {
    Column(
        Modifier.fillMaxWidth().testTag("ask.answer"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (exchange.blocks.isEmpty) {
            for (paragraph in AnswerMarkdown.paragraphs(exchange.answerText)) {
                Text(
                    AnswerMarkdown.inline(paragraph),
                    style = MaterialTheme.typography.bodyMedium,
                    color = palette.ink,
                    lineHeight = 21.sp,
                )
            }
        }
        for (block in exchange.blocks.items) {
            when (block) {
                is AnswerBlock.Paragraph -> Text(
                    AnswerMarkdown.inline(block.text),
                    style = MaterialTheme.typography.bodyMedium,
                    color = palette.ink,
                    lineHeight = 21.sp,
                )
                is AnswerBlock.Heading -> Text(
                    AnswerMarkdown.inline(block.text),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.ink,
                    lineHeight = 21.sp,
                )
                is AnswerBlock.Items -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    for (item in block.items) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            // The marker the kit rendered — "•" for a bullet,
                            // "2." for the second item of a numbered list, so
                            // an ordered list keeps its numbers.
                            Text(
                                item.marker,
                                style = MaterialTheme.typography.bodyMedium,
                                color = palette.muted,
                            )
                            Text(
                                AnswerMarkdown.inline(item.text),
                                style = MaterialTheme.typography.bodyMedium,
                                color = palette.ink,
                                lineHeight = 21.sp,
                            )
                        }
                    }
                }
                is AnswerBlock.Quote -> QuotedText(block.paragraphs.joinToString("\n\n"), palette, Modifier)
                is AnswerBlock.Code -> Text(
                    block.text,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                    color = palette.ink,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(palette.elevated)
                        .horizontalScroll(rememberScrollState())
                        .padding(10.dp),
                )
                AnswerBlock.Rule -> Box(
                    Modifier.fillMaxWidth().height(1.dp).background(palette.line)
                )
            }
        }
    }
}

/**
 * A quotation from the book: serif and italic, behind an iris rule.
 *
 * `IntrinsicSize.Min` on the row is what gives the rule a height to fill —
 * inside a scrolling column the incoming height is unbounded, and
 * `fillMaxHeight` against an unbounded constraint draws nothing at all.
 */
@Composable
private fun QuotedText(text: String, palette: ReadingPalette, modifier: Modifier) {
    Row(
        modifier.fillMaxWidth().height(IntrinsicSize.Min),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.width(2.dp).fillMaxHeight().background(palette.iris, RoundedCornerShape(1.dp)))
        Text(
            text,
            fontFamily = FontFamily.Serif,
            fontStyle = FontStyle.Italic,
            fontSize = 14.sp,
            lineHeight = 21.sp,
            color = palette.muted,
        )
    }
}

/**
 * The passages the answer leaned on, as iris pills. Tapping one opens its
 * quote underneath; a citation that knows where it came from also offers to
 * open the book there.
 */
@Composable
private fun Sources(citations: List<AskCitation>, palette: ReadingPalette, onShowInBook: (Int, Int) -> Unit) {
    var expanded by remember { mutableStateOf(-1) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("SOURCES", style = MaterialTheme.typography.labelSmall, color = palette.faint)
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            citations.forEachIndexed { index, citation ->
                val isOpen = expanded == index
                Text(
                    citation.locator,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = palette.iris,
                    maxLines = 1,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(palette.iris.copy(alpha = 0.10f))
                        .border(1.dp, palette.iris.copy(alpha = if (isOpen) 0.6f else 0.25f), CircleShape)
                        .clickable { expanded = if (isOpen) -1 else index }
                        .padding(horizontal = 10.dp, vertical = 5.dp)
                        .testTag("ask.citation.$index"),
                )
            }
        }
        val open = citations.getOrNull(expanded)
        if (open != null) {
            QuotedText(open.quotedText, palette, Modifier)
            if (open.isLocated) {
                TextButton(
                    onClick = { onShowInBook(open.chapterIndex!!, open.utf16Offset!!) },
                    modifier = Modifier.testTag("ask.showInBook.$expanded"),
                ) { Text("Show in book", fontSize = 13.sp, color = palette.iris) }
            }
        }
    }
}

/**
 * The honest whole-book footer: the answer drew on the entire text (or, under
 * a scope, everything read so far), so there is no passage retrieval and no
 * citation list to show.
 */
@Composable
private fun WholeBookNote(scoped: Boolean, palette: ReadingPalette) {
    Column(
        Modifier.testTag("ask.wholeBookNote"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            if (scoped) "USING EVERYTHING YOU’VE READ" else "USING THE WHOLE BOOK",
            style = MaterialTheme.typography.labelSmall,
            color = palette.faint,
        )
        Text(
            if (scoped) "Everything you've read so far fits in one request, so the answer draws on all of it — no passage retrieval, no citation list."
            else "This book is short enough to read in full, so the answer draws on the entire text — no passage retrieval, no citation list.",
            fontSize = 12.sp,
            color = palette.muted,
        )
    }
}

/** The composer, its suggestions, the error card and the grounding promise. */
@Composable
private fun Composer(model: AskViewModel, palette: ReadingPalette) {
    var question by remember { mutableStateOf("") }
    Box(Modifier.fillMaxWidth().height(1.dp).background(palette.line))
    Column(
        Modifier
            .fillMaxWidth()
            .background(palette.background)
            .padding(horizontal = 20.dp)
            .padding(top = 10.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // The error card sits ABOVE the field so its Retry is never scrolled
        // out of reach by a long transcript.
        model.errorMessage?.let { ErrorCard(it, model.errorRecovery, palette, model.isStreaming) { model.retry() } }

        if (model.exchanges.isEmpty() && !model.isStreaming) {
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                model.suggestions.forEachIndexed { index, suggestion ->
                    // A chip is a whole question, so a tap SENDS it: putting
                    // the words in the field and asking for a second tap was a
                    // step with nothing in it.
                    Text(
                        suggestion,
                        fontSize = 12.sp,
                        color = palette.iris,
                        maxLines = 1,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(palette.iris.copy(alpha = 0.10f))
                            .border(1.dp, palette.iris.copy(alpha = 0.25f), CircleShape)
                            .clickable { model.submit(suggestion) }
                            .padding(horizontal = 11.dp, vertical = 5.dp)
                            .testTag("ask.suggestion.$index"),
                    )
                }
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = question,
                onValueChange = { question = it },
                placeholder = {
                    Text(
                        if (model.exchanges.isEmpty()) "Ask a question about this book…" else "Ask a follow-up…",
                        fontSize = 13.sp,
                        color = palette.faint,
                    )
                },
                singleLine = false,
                maxLines = 4,
                modifier = Modifier.weight(1f).testTag("ask.field"),
            )
            val canSend = !model.isStreaming && question.isNotBlank()
            Text(
                "↑",
                fontSize = 20.sp,
                color = if (canSend) palette.iris else palette.faint,
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(enabled = canSend) {
                        val sent = question.trim()
                        question = ""
                        model.submit(sent)
                    }
                    .padding(10.dp)
                    .testTag("ask.send")
                    .semantics { contentDescription = "Send" },
                textAlign = TextAlign.Center,
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                groundingCaption(model),
                fontSize = 11.sp,
                color = palette.faint,
                modifier = Modifier.testTag("ask.grounding"),
            )
            model.tier?.let { tier ->
                Text(
                    when {
                        tier == AskTier.RETRIEVAL -> "Using relevant passages"
                        model.isScoped -> "Using everything you've read"
                        else -> "Using the whole book"
                    },
                    fontSize = 11.sp,
                    color = palette.faint,
                    modifier = Modifier.testTag("ask.tier"),
                )
            }
            if (model.indexing) {
                Text(
                    "Reading the book so it can be searched…",
                    fontSize = 11.sp,
                    color = palette.faint,
                    modifier = Modifier.testTag("ask.indexing"),
                )
            }
        }
    }
}

/**
 * The grounding promise, derived from the tier and the provider rather than
 * hardcoded: the whole-book tier returns no per-passage sources, so it must
 * not promise citations it cannot deliver, and a model running on the phone
 * has no wider knowledge to offer.
 */
private fun groundingCaption(model: AskViewModel): String {
    val grounding = when {
        model.isScoped -> "what you’ve read so far"
        model.tier == AskTier.WHOLE_BOOK -> "the whole book"
        else -> "this book"
    }
    if (model.answersFromBookOnly) return "Answers come from $grounding only."
    // Nothing has been routed yet: promise the grounding, which is true of
    // either tier, and say nothing about citations until the kit has said
    // whether this answer will have any.
    val cites = model.providesCitations ?: return "Grounded in $grounding."
    if (!cites) return "Grounded in $grounding — plus the model’s wider knowledge."
    return "Grounded in $grounding with citations — plus the model’s wider knowledge."
}

/** The cause, the step the kit suggests, and a Retry that re-sends the question. */
@Composable
private fun ErrorCard(
    message: String,
    recovery: String?,
    palette: ReadingPalette,
    streaming: Boolean,
    onRetry: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(palette.elevated)
            .border(1.dp, Color(0xFFB3261E), RoundedCornerShape(12.dp))
            .padding(13.dp)
            .testTag("ask.error"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(message, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = palette.ink)
        if (!recovery.isNullOrBlank()) {
            Text(recovery, fontSize = 12.sp, color = palette.muted)
        }
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(9.dp))
                .background(if (streaming) palette.faint else palette.ink)
                .clickable(enabled = !streaming, onClick = onRetry)
                .padding(vertical = 9.dp)
                .testTag("ask.retry")
                .semantics { contentDescription = "Retry" },
            contentAlignment = Alignment.Center,
        ) {
            Text("Retry", color = palette.background, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
        }
    }
}

/**
 * Three iris dots pulsing in a wave, as the Apple panel's are.
 *
 * The wave is a `delay` loop rather than an infinite animation on purpose:
 * an animation that never ends keeps Compose's clock busy forever, and a UI
 * test that waits for the screen to settle would wait for good.
 */
@Composable
private fun ThinkingDots(color: Color) {
    var lit by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(220)
            lit = (lit + 1) % 3
        }
    }
    Row(
        Modifier
            .testTag("ask.thinking")
            .semantics { contentDescription = "Thinking" },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (index in 0 until 3) {
            Box(
                Modifier
                    .size(5.dp)
                    .alpha(if (index == lit) 1f else 0.25f)
                    .background(color, CircleShape)
            )
        }
    }
}

/** An open book, drawn by the font rather than bundled as an icon. */
private const val BOOK_GLYPH = "📖"
