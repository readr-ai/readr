package com.readrai.readr.ui.listen

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.ui.theme.ReadingPalette
import com.readrai.readr.ui.theme.touchTarget

/**
 * The now-reading card: what the reader sees while the book is read aloud.
 *
 * One card, insetting the page from the bottom rather than floating over it —
 * the page turns itself to follow the voice, so nothing may cover the words.
 * The chapter in caps, the sentence being read, a hairline of the chapter's
 * progress, and one row of controls: speed on the left, ◀ ● ▶ in the middle,
 * the sleep timer on the right, ✕ in the corner. That is the whole of it,
 * exactly as `ListenBar` is on iOS after the September 2026 UX review.
 *
 * The card decides nothing: every control calls the model, which calls the
 * kit.
 */
@Composable
fun ListenCard(
    narration: NarrationModel,
    palette: ReadingPalette,
    /** The chapter the voice is in, for the card's kicker. */
    chapterTitle: String?,
    /**
     * ✕. The reader's, not the card's: stopping the voice also hands the
     * reader's own page back as the place to save, and that is the screen's
     * business — so the bar's Listen toggle and this go through one lambda
     * rather than each remembering half of it.
     */
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .fillMaxWidth()
            .background(palette.page)
            .padding(horizontal = 14.dp)
            .padding(top = 8.dp, bottom = 10.dp)
            .testTag("listen.bar")
            .semantics { contentDescription = "Narration controls" },
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .background(palette.elevated, RoundedCornerShape(16.dp))
                .border(1.dp, palette.line, RoundedCornerShape(16.dp))
                .padding(top = 12.dp, start = 14.dp, end = 14.dp, bottom = 6.dp),
        ) {
            Column(
                // Room for the ✕, which sits in the card's corner (an overlay,
                // not a row member) so its 44 dp target can reach the edge
                // without the text running under it.
                Modifier.fillMaxWidth().padding(end = 36.dp),
            ) {
                if (!chapterTitle.isNullOrBlank()) {
                    Text(
                        chapterTitle.uppercase(),
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = 1.5.sp,
                        color = palette.faint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.height(4.dp))
                StatusLine(narration, palette)
            }
            Spacer(Modifier.height(10.dp))
            ProgressTrack(narration.chapterProgress.toFloat(), palette)
            Spacer(Modifier.height(2.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                SpeedMenu(narration, palette)
                Spacer(Modifier.weight(1f))
                Transport(narration, palette)
                Spacer(Modifier.weight(1f))
                SleepMenu(narration, palette)
            }
        }
        CloseButton(palette, Modifier.align(Alignment.TopEnd), onStop)
    }
}

/**
 * What the card says under the kicker: the reason narration stopped by itself
 * — in the facade's words, never Kotlin's — or, nearly always, the sentence
 * being read.
 */
@Composable
private fun StatusLine(narration: NarrationModel, palette: ReadingPalette) {
    val hold = narration.holdText
    if (hold != null) {
        Text(
            hold,
            fontSize = 13.sp,
            color = palette.muted,
            // Two lines either way, so the card is the same height whether it
            // is showing a sentence or explaining itself — a card that grew
            // and shrank under the page would re-inset (and re-paginate) it.
            minLines = 2,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("listen.hold")
                .semantics { contentDescription = hold },
        )
        return
    }
    val sentence = narration.sentence
    Text(
        sentence,
        fontFamily = FontFamily.Serif,
        fontStyle = FontStyle.Italic,
        fontSize = 14.sp,
        color = palette.ink,
        minLines = 2,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("listen.sentence")
            .semantics { contentDescription = "Now reading: $sentence" },
    )
}

@Composable
private fun ProgressTrack(progress: Float, palette: ReadingPalette) {
    Box(Modifier.fillMaxWidth().height(2.dp).background(palette.line)) {
        Box(
            Modifier
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .height(2.dp)
                .background(palette.iris),
        )
    }
}

@Composable
private fun Transport(narration: NarrationModel, palette: ReadingPalette) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        TransportButton(
            tag = "listen.previous",
            label = "Previous sentence",
            onClick = { narration.skipToPreviousSentence() },
        ) { SkipGlyph(palette.ink, forward = false) }
        Spacer(Modifier.size(6.dp))
        // Preparing shows Pause too: the voice is on its way and the control
        // pauses the wait, the way it pauses speech.
        val playing = narration.isUnderway
        Box(
            Modifier
                .size(touchTarget)
                .clip(CircleShape)
                .background(palette.ink, CircleShape)
                .clickable { narration.togglePlayPause() }
                .testTag("listen.playPause")
                .semantics { contentDescription = if (playing) "Pause" else "Play" },
            contentAlignment = Alignment.Center,
        ) {
            if (playing) PauseGlyph(palette.background) else PlayGlyph(palette.background)
        }
        Spacer(Modifier.size(6.dp))
        TransportButton(
            tag = "listen.next",
            label = "Next sentence",
            onClick = { narration.skipToNextSentence() },
        ) { SkipGlyph(palette.ink, forward = true) }
    }
}

@Composable
private fun TransportButton(
    tag: String,
    label: String,
    onClick: () -> Unit,
    glyph: @Composable () -> Unit,
) {
    Box(
        Modifier
            .size(touchTarget)
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .testTag(tag)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { glyph() }
}

@Composable
private fun SpeedMenu(narration: NarrationModel, palette: ReadingPalette) {
    var open by remember { mutableStateOf(false) }
    val options = NarrationOptions.current
    Box {
        Box(
            Modifier
                .widthIn(min = touchTarget)
                .height(touchTarget)
                .clip(RoundedCornerShape(50))
                .clickable { open = true }
                .padding(horizontal = 6.dp)
                .testTag("listen.speed")
                .semantics { contentDescription = "Speaking speed" },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                options.rateLabel(narration.rate),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = palette.ink,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.rateSteps.forEach { step ->
                val label = options.rateLabel(step)
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = { open = false; narration.chooseRate(step) },
                    modifier = Modifier.testTag("listen.speed.$label"),
                )
            }
        }
    }
}

@Composable
private fun SleepMenu(narration: NarrationModel, palette: ReadingPalette) {
    var open by remember { mutableStateOf(false) }
    val sleep = narration.sleep
    val options = NarrationOptions.current
    Box {
        Row(
            Modifier
                .height(touchTarget)
                .clip(RoundedCornerShape(50))
                .clickable { open = true }
                .padding(horizontal = 6.dp)
                .testTag("listen.sleep")
                .semantics { contentDescription = "Sleep timer" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text("☽", fontSize = 13.sp, color = if (sleep.isOn) palette.iris else palette.ink)
            Text(
                sleep.countdown ?: "Sleep",
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = if (sleep.isOn) palette.iris else palette.ink,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text(options.offLabel) },
                onClick = { open = false; narration.setSleepTimer(NarrationSleep.OFF) },
            )
            HorizontalDivider()
            options.sleepMinutes.forEach { minutes ->
                DropdownMenuItem(
                    text = { Text(options.sleepMinuteLabel(minutes)) },
                    onClick = { open = false; narration.setSleepTimer(NarrationSleep.AFTER, minutes) },
                )
            }
            DropdownMenuItem(
                text = { Text(options.endOfChapterLabel) },
                onClick = { open = false; narration.setSleepTimer(NarrationSleep.END_OF_CHAPTER) },
            )
        }
    }
}

/** ✕ in the card's corner: a 44 dp target drawn as a small glyph. */
@Composable
private fun CloseButton(palette: ReadingPalette, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .padding(top = 10.dp, end = 16.dp)
            .size(touchTarget)
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .testTag("listen.close")
            .semantics { contentDescription = "Stop listening" },
        contentAlignment = Alignment.Center,
    ) {
        Text("✕", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = palette.muted)
    }
}

// Material's core icon set has no pause or skip marks, so the transport is
// drawn — the same choice `AnnotationCapsule`'s copy glyph makes.

@Composable
private fun PlayGlyph(color: Color) {
    Canvas(Modifier.size(16.dp)) {
        val path = Path().apply {
            moveTo(size.width * 0.15f, 0f)
            lineTo(size.width, size.height / 2f)
            lineTo(size.width * 0.15f, size.height)
            close()
        }
        drawPath(path, color)
    }
}

@Composable
private fun PauseGlyph(color: Color) {
    Canvas(Modifier.size(14.dp)) {
        val bar = size.width * 0.32f
        drawRect(color, topLeft = Offset(0f, 0f), size = Size(bar, size.height))
        drawRect(color, topLeft = Offset(size.width - bar, 0f), size = Size(bar, size.height))
    }
}

@Composable
private fun SkipGlyph(color: Color, forward: Boolean) {
    Canvas(Modifier.size(14.dp)) {
        val path = Path().apply {
            if (forward) {
                moveTo(0f, 0f)
                lineTo(size.width, size.height / 2f)
                lineTo(0f, size.height)
            } else {
                moveTo(size.width, 0f)
                lineTo(0f, size.height / 2f)
                lineTo(size.width, size.height)
            }
            close()
        }
        drawPath(path, color)
    }
}
