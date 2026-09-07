package com.readrai.readr.ui.reader

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.Marginalia
import com.readrai.readr.ui.theme.ReadingPalette

/** What the capsule is acting on: a fresh selection, or a highlight the reader tapped. */
sealed interface AnnotationTarget {
    val chapterIndex: Int
    val utf16Start: Int
    val utf16End: Int
    val quotedText: String

    /** A selection on the page; a colour creates the highlight. */
    data class Selected(
        override val chapterIndex: Int,
        override val utf16Start: Int,
        override val utf16End: Int,
        override val quotedText: String,
    ) : AnnotationTarget

    /** A highlight already in the book; a colour recolours it. */
    data class Existing(val highlight: Highlight) : AnnotationTarget {
        override val chapterIndex: Int get() = highlight.chapterIndex
        override val utf16Start: Int get() = highlight.utf16Start
        override val utf16End: Int get() = highlight.utf16End
        override val quotedText: String get() = highlight.quotedText
    }
}

/** Apple's minimum, and Material's: nothing here is smaller than a fingertip. */
private val touchTarget = 44.dp

/** The note button never grows past this; the row scrolls before it does. */
private val noteButtonWidth = 72.dp

/**
 * One marker dot in a fingertip-sized target: the swatch, ringed when it is
 * the colour in play. The capsule's picker and the Highlights sheet's filter
 * chips are the same control at two sizes, and the sheet fades the colours it
 * is filtering out — that is the only difference, so it is the only parameter.
 */
@Composable
fun MarkerDot(
    color: HighlightColor,
    selected: Boolean,
    size: Dp,
    onClick: () -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    fadeWhenOff: Boolean = false,
) {
    val palette = LocalReadingPalette.current
    val swatch = Marginalia.markerSwatch(color).copy(alpha = if (selected || !fadeWhenOff) 1f else 0.3f)
    Box(
        modifier
            .size(touchTarget)
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = label
                this.selected = selected
            },
        contentAlignment = Alignment.Center,
    ) {
        if (selected) Box(Modifier.size(size + 6.dp).border(1.5.dp, palette.ink.copy(alpha = 0.65f), CircleShape))
        Box(
            Modifier
                .size(size)
                .background(swatch, CircleShape)
                .border(1.dp, Color.Black.copy(alpha = 0.12f), CircleShape),
        )
    }
}

/**
 * The annotation capsule, as `AnnotationMenuView` is on iOS: four muted
 * colour dots that highlight in one tap, then copy. On a highlight the reader
 * tapped, the current colour wears a ring, the dots recolour it, and a ✕
 * removes it. The capsule decides nothing — the host acts in the callbacks
 * and dismisses.
 */
@Composable
fun AnnotationCapsule(
    target: AnnotationTarget,
    palette: ReadingPalette,
    onHighlight: (HighlightColor) -> Unit,
    onCopy: () -> Unit,
    modifier: Modifier = Modifier,
    onRemove: (() -> Unit)? = null,
    /** Opens the note editor: "Note" on a selection, "Edit note" on a highlight that has one. */
    onNote: ((AnnotationTarget) -> Unit)? = null,
    /** Opens Ask on this passage — the ✦ of the iOS selection menu. */
    onAsk: ((AnnotationTarget) -> Unit)? = null,
) {
    val editing = target as? AnnotationTarget.Existing
    Row(
        modifier
            .testTag("annotation.capsule")
            .shadow(6.dp, RoundedCornerShape(50))
            .background(palette.elevated, RoundedCornerShape(50))
            .border(1.dp, palette.line, RoundedCornerShape(50))
            // Seven controls at a large font scale outgrow a 360 dp screen;
            // the row scrolls rather than pushing the last of them off it.
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(0.dp),
    ) {
        Marginalia.pickerColors.forEach { color ->
            MarkerDot(
                color = color,
                selected = editing?.highlight?.markerColor == color,
                size = 20.dp,
                onClick = { onHighlight(color) },
                label = "Highlight ${color.displayName}",
                modifier = Modifier.testTag("annotation.color.${color.key}"),
            )
        }
        if (editing != null && onRemove != null) {
            IconButton(
                onClick = onRemove,
                modifier = Modifier
                    .size(touchTarget)
                    .testTag("annotation.remove")
                    .semantics { contentDescription = "Remove highlight" },
            ) { Text("✕", fontSize = 13.sp, color = palette.faint) }
        }
        Box(Modifier.width(1.dp).height(16.dp).background(palette.line))
        if (onAsk != null) {
            // Iris, and the ✦ leading: the one AI moment on the page, and the
            // only control here that leaves the book behind for a moment.
            Row(
                Modifier
                    .height(touchTarget)
                    .widthIn(min = touchTarget, max = noteButtonWidth)
                    .clip(RoundedCornerShape(50))
                    .clickable { onAsk(target) }
                    .padding(horizontal = 6.dp)
                    .testTag("annotation.ask")
                    .semantics { contentDescription = "Ask the book" },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterHorizontally),
            ) {
                Text(Marginalia.aiGlyph, fontSize = 13.sp, color = palette.iris)
                if (LocalDensity.current.fontScale <= 1.25f) {
                    Text(
                        "Ask",
                        fontSize = 13.sp,
                        color = palette.ink,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        if (onNote != null) {
            // The note glyph carries the meaning and the word confirms it, so
            // the button stays a thumb wide however large the reader's type is
            // — and past the point where the word would fit beside the glyph,
            // the glyph goes on alone rather than the word being cut in half.
            // What a screen reader is told does not change either way.
            val spelledOut = LocalDensity.current.fontScale <= 1.25f
            Row(
                Modifier
                    .height(touchTarget)
                    .widthIn(min = touchTarget, max = noteButtonWidth)
                    .clip(RoundedCornerShape(50))
                    .clickable { onNote(target) }
                    .padding(horizontal = 6.dp)
                    .testTag("annotation.note")
                    .semantics { contentDescription = if (target.hasNote) "Edit note" else "Note" },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterHorizontally),
            ) {
                Text(Marginalia.noteGlyph, fontSize = 13.sp, color = palette.muted)
                if (spelledOut) {
                    Text(
                        if (target.hasNote) "Edit" else "Note",
                        fontSize = 13.sp,
                        color = palette.ink,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        IconButton(
            onClick = onCopy,
            modifier = Modifier
                .size(touchTarget)
                .testTag("annotation.copy")
                .semantics { contentDescription = "Copy" },
        ) { CopyGlyph(palette.muted) }
    }
}

private val AnnotationTarget.hasNote: Boolean
    get() = (this as? AnnotationTarget.Existing)?.highlight?.note.isNullOrBlank().not()

/** Two stacked sheets — the copy mark, drawn rather than bundled (Material's core icon set has none). */
@Composable
private fun CopyGlyph(color: Color) {
    Canvas(Modifier.size(18.dp)) {
        val side = size.minDimension * 0.72f
        val inset = size.minDimension - side
        val stroke = Stroke(width = 1.4.dp.toPx())
        val radius = CornerRadius(2.dp.toPx(), 2.dp.toPx())
        drawRoundRect(color, Offset(0f, inset), Size(side, side), radius, style = stroke)
        drawRoundRect(color, Offset(inset, 0f), Size(side, side), radius, style = stroke)
    }
}

/** "Yellow", "Green" … — the label the capsule reads out, as `HighlightColor.displayName` does on iOS. */
val HighlightColor.displayName: String
    get() = key.replaceFirstChar { it.uppercase() }
