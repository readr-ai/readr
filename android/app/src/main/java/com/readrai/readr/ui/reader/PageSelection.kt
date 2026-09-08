package com.readrai.readr.ui.reader

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.readrai.readr.ui.theme.ReadingPalette
import kotlin.math.hypot

/** The visible dot at each end of a selection, and how far a finger may miss it. */
private val handleRadius = 7.dp
private val handleGrab: Dp = 24.dp

/** Iris at a quarter strength: the passage stays readable under the wash. */
private const val SELECTION_ALPHA = 0.25f

/** Which end of the selection a finger has hold of. */
enum class SelectionHandle { Start, End }

/**
 * The live selection on the drawn page. Offsets are page-local UTF-16 — what
 * [TextLayoutResult] reports — so a caller turns them into chapter offsets
 * with the page's `textStart` (never `rangeStart`; see [Page]).
 *
 * The page owns this, not the ViewModel: a selection belongs to the glyphs on
 * screen and dies with them, so a turn, a re-pagination or an appearance
 * change simply drops it.
 */
class PageSelectionState {
    var layout by mutableStateOf<TextLayoutResult?>(null)
    var range by mutableStateOf<TextRange?>(null)
        private set

    val isActive: Boolean get() = range?.collapsed == false

    fun clear() { range = null }

    /**
     * Long press: take the word under the finger, expanded from the glyph the
     * finger is actually **on**.
     *
     * The pixel is resolved the way a tap resolves it ([characterUnder]), not
     * to the nearest caret. `getOffsetForPosition` answers with an insertion
     * point, and a press on the right half of a letter rounds to the caret
     * *after* it — on a word's last letter that is the boundary between the
     * word and whatever follows, and the word iterator there hands back the
     * following run. So a press on the "t" of "Light," selected the comma,
     * while the tap meant to reopen that mark resolved the very same pixel to
     * the "t": one place on the page, two different characters.
     *
     * A press on something that is not a word — a comma, the space between
     * two words, the white past a short line — walks out to the nearest word
     * character on either side and takes whichever the finger is closer to.
     * A long press therefore always yields a word, never a blank, and never
     * punctuation while there is a word to be had. Returns the anchor a drag
     * then extends from.
     */
    fun selectWord(layout: TextLayoutResult, position: Offset): TextRange {
        val picked = wordUnder(layout, position)
        range = picked
        return picked
    }

    /** Dragging on after the long press: the word stays in, the far end follows the finger. */
    fun extend(layout: TextLayoutResult, anchor: TextRange, position: Offset) {
        val offset = layout.getOffsetForPosition(position).coerceIn(0, layout.layoutInput.text.length)
        range = TextRange(minOf(anchor.min, offset), maxOf(anchor.max, offset))
    }

    /**
     * Dragging a handle. The ends never cross: the selection keeps at least
     * one character. The finger's y is taken back through the same half-radius
     * the handle is drawn below the line ([handleCenters]) — and a hair
     * further, since a y sitting exactly on a line's foot belongs to the line
     * *below* it — then clamped into the laid-out text. So grabbing a handle
     * where it is drawn resolves to the character it was already on, on the
     * last line and on every line before it.
     */
    fun moveHandle(handle: SelectionHandle, position: Offset, radiusPx: Float) {
        val layout = layout ?: return
        val current = range ?: return
        val length = layout.layoutInput.text.length
        val y = (position.y - radiusPx * HANDLE_DROP - 1f).coerceIn(0f, maxOf(0f, layout.size.height - 1f))
        val offset = layout.getOffsetForPosition(Offset(position.x, y))
        range = when (handle) {
            SelectionHandle.Start -> TextRange(offset.coerceIn(0, current.max - 1), current.max)
            SelectionHandle.End -> TextRange(current.min, offset.coerceIn(current.min + 1, length))
        }
    }

    /**
     * Where the two handles sit: half a radius below the line's foot, so the
     * dot hangs off the text rather than over it. Only the *drawn* position is
     * clamped into the page — [moveHandle] undoes the same half radius, so
     * what is drawn and what a finger maps back to stay one and the same.
     */
    fun handleCenters(radiusPx: Float, heightPx: Float): Pair<Offset, Offset>? {
        val layout = layout ?: return null
        val range = range?.takeIf { !it.collapsed } ?: return null
        fun center(offset: Int): Offset {
            val rect = layout.getCursorRect(offset)
            val y = rect.bottom + radiusPx * HANDLE_DROP
            return Offset(rect.left, y.coerceIn(radiusPx, maxOf(radiusPx, heightPx - radiusPx)))
        }
        return center(range.min) to center(range.max)
    }

    companion object {
        /** How far below the line's foot the handle's centre sits, in radii. */
        const val HANDLE_DROP = 0.5f
    }
}

/**
 * Selecting on the page: long-press for the word under the finger, drag on to
 * extend, and two handles to adjust. Taps are offered to `onTap` with the
 * page-local offset under the finger — [NO_CHARACTER] when the finger was over
 * no glyph at all — and where the finger landed; only a tap it claims is
 * consumed, so an ordinary tap still reaches the reader's page-turn zones
 * behind this.
 */
@Composable
fun Modifier.pageSelection(
    key: Any?,
    state: PageSelectionState,
    palette: ReadingPalette,
    onTap: (Int, Offset) -> Boolean,
): Modifier {
    val tap by rememberUpdatedState(onTap)
    val density = LocalDensity.current
    val radiusPx = with(density) { handleRadius.toPx() }
    val grabPx = with(density) { handleGrab.toPx() }
    return this
        .drawWithContent {
            val layout = state.layout
            val range = state.range
            if (layout != null && range != null && !range.collapsed) {
                drawPath(layout.getPathForRange(range.min, range.max), palette.iris.copy(alpha = SELECTION_ALPHA))
            }
            drawContent()
            state.handleCenters(radiusPx, size.height)?.let { (start, end) ->
                drawCircle(palette.iris, radiusPx, start)
                drawCircle(palette.iris, radiusPx, end)
            }
        }
        .pointerInput(key) {
            awaitEachGesture {
                val down = awaitFirstDown()
                val layout = state.layout ?: return@awaitEachGesture
                val handle = grabbedHandle(state, down.position, radiusPx, grabPx, size.height.toFloat())
                if (handle != null) {
                    down.consume()
                    trackUntilUp(down.id) { position -> state.moveHandle(handle, position, radiusPx) }
                    return@awaitEachGesture
                }
                // A press that is neither released nor moved before the long-press
                // timeout selects; a release is a tap; movement is the reader's swipe.
                val longPressed = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                    var settled = false
                    while (!settled) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                        if (change == null) {
                            settled = true
                        } else if (!change.pressed) {
                            if (tap(characterUnder(layout, change.position), change.position)) change.consume()
                            settled = true
                        } else if ((change.position - down.position).getDistance() > viewConfiguration.touchSlop) {
                            settled = true
                        }
                    }
                } == null
                if (longPressed) {
                    down.consume()
                    val anchor = state.selectWord(layout, down.position)
                    trackUntilUp(down.id) { position -> state.extend(layout, anchor, position) }
                }
            }
        }
}

/**
 * Follows one pointer to its release, consuming every change on the way —
 * including the release, so the page-turn tap behind this never fires at the
 * end of a selection.
 */
private suspend fun AwaitPointerEventScope.trackUntilUp(id: PointerId, onMove: (Offset) -> Unit) {
    while (true) {
        val change = awaitPointerEvent().changes.firstOrNull { it.id == id } ?: return
        change.consume()
        if (!change.pressed) return
        onMove(change.position)
    }
}

/**
 * The word a long press at [position] means, in page-local offsets.
 *
 * The glyph under the finger first — the same resolution a tap makes, so the
 * two gestures never disagree about one pixel. A press over no glyph at all
 * (the margin, the white past a short line) has no glyph to start from, and
 * falls back to the nearest caret: it still has to select something, and the
 * walk below turns that into the word beside the finger.
 */
private fun wordUnder(layout: TextLayoutResult, position: Offset): TextRange {
    val text = layout.layoutInput.text.text
    if (text.isEmpty()) return TextRange(0, 0)
    val pressed = characterUnder(layout, position).takeIf { it != NO_CHARACTER }
        ?: layout.getOffsetForPosition(position).coerceIn(0, text.lastIndex)
    val letter = if (isWordCharacter(text, pressed)) {
        pressed
    } else {
        nearestWordCharacter(layout, text, pressed, position)
    }
    // A page with no word on it at all — a picture, a rule — still answers a
    // press with the one character under it rather than with nothing.
    if (letter == NO_CHARACTER) return TextRange(pressed, pressed + 1)
    var start = letter
    while (start > 0 && isWordCharacter(text, start - 1)) start--
    var end = letter + 1
    while (end < text.length && isWordCharacter(text, end)) end++
    return TextRange(start, end)
}

/**
 * Whether the character at [index] is part of a word. Letters and digits are;
 * so is an apostrophe with one on each side, because "don't" is one word and
 * Android's own iterator reads it as one. A hyphen is not: "well-known" is
 * selected a half at a time there too.
 */
private fun isWordCharacter(text: String, index: Int): Boolean {
    val char = text[index]
    if (char.isLetterOrDigit()) return true
    if (char != '\'' && char != '’') return false
    return index > 0 && text[index - 1].isLetterOrDigit() &&
        index + 1 < text.length && text[index + 1].isLetterOrDigit()
}

/**
 * The word character nearest the finger, on either side of [from], or
 * [NO_CHARACTER] when the page holds none.
 *
 * Measured where the reader can see it — the distance from the finger to each
 * candidate's glyph box — rather than counted in characters, which would make
 * every space a tie. A press in the gap between two words is a pixel from one
 * and a space's width from the other; a press past the end of a short line is
 * beside the word that ends it, not beside the one that starts the next.
 * A true tie goes to the word before, as Android's own selection does.
 */
private fun nearestWordCharacter(
    layout: TextLayoutResult,
    text: String,
    from: Int,
    position: Offset,
): Int {
    val before = (from - 1 downTo 0).firstOrNull { isWordCharacter(text, it) }
    val after = (from + 1 until text.length).firstOrNull { isWordCharacter(text, it) }
    return when {
        before == null -> after ?: NO_CHARACTER
        after == null -> before
        distanceTo(layout, before, position) <= distanceTo(layout, after, position) -> before
        else -> after
    }
}

/** How far the finger is from the glyph at [index], in pixels, zero when on it. */
private fun distanceTo(layout: TextLayoutResult, index: Int, position: Offset): Float {
    val box = layout.getBoundingBox(index)
    val dx = maxOf(box.left - position.x, position.x - box.right, 0f)
    val dy = maxOf(box.top - position.y, position.y - box.bottom, 0f)
    return hypot(dx, dy)
}

/**
 * The character the finger is over, or [NO_CHARACTER] where it is over none —
 * the white past the end of a short line, the margin below the last one, the
 * air beside a centred picture. `getOffsetForPosition` answers with a caret,
 * which is never "nowhere": it names the nearest insertion point however far
 * away the glyphs are, so a tap in a blank corner would resolve to whatever
 * happened to be closest and could follow a link the finger never touched.
 * The glyph boxes decide instead — and a tap on the last letter of a highlight
 * still lands inside it rather than just past its end.
 *
 * The long press comes through here too ([wordUnder]), so both gestures read
 * one pixel as one character.
 */
private fun characterUnder(layout: TextLayoutResult, position: Offset): Int {
    val length = layout.layoutInput.text.length
    val caret = layout.getOffsetForPosition(position).coerceIn(0, length)
    if (caret < length && layout.getBoundingBox(caret).contains(position)) return caret
    if (caret > 0 && layout.getBoundingBox(caret - 1).contains(position)) return caret - 1
    return NO_CHARACTER
}

/** What [characterUnder] reports for a tap that landed on no glyph at all. */
const val NO_CHARACTER = -1

private fun grabbedHandle(
    state: PageSelectionState,
    position: Offset,
    radiusPx: Float,
    grabPx: Float,
    heightPx: Float,
): SelectionHandle? {
    val (start, end) = state.handleCenters(radiusPx, heightPx) ?: return null
    val toStart = (position - start).getDistance()
    val toEnd = (position - end).getDistance()
    return when {
        toStart > grabPx && toEnd > grabPx -> null
        toStart <= toEnd -> SelectionHandle.Start
        else -> SelectionHandle.End
    }
}
