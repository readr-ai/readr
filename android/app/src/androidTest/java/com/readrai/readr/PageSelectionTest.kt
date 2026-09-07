package com.readrai.readr

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.readrai.readr.ui.reader.ChapterStyling
import com.readrai.readr.ui.reader.LayoutKey
import com.readrai.readr.ui.reader.PageSelectionState
import com.readrai.readr.ui.reader.ReaderAppearance
import com.readrai.readr.ui.reader.SelectionHandle
import com.readrai.readr.ui.theme.Marginalia
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The selection's geometry, against a real multi-line layout: what the page
 * draws and what a finger maps back to have to be the same place, or a handle
 * jumps a line the moment it is touched.
 */
@RunWith(AndroidJUnit4::class)
class PageSelectionTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val density by lazy { Density(context) }
    private val measurer by lazy { TextMeasurer(createFontFamilyResolver(context), density, LayoutDirection.Ltr, cacheSize = 0) }
    private val style by lazy { ChapterStyling.pageTextStyle(LayoutKey(ReaderAppearance()), Marginalia.paper) }

    /** The handle radius the reader draws with. */
    private val radiusPx by lazy { with(density) { 7.dp.toPx() } }

    private val prose = "It was the best of times, it was the worst of times, it was the age of wisdom, " +
        "it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity, " +
        "it was the season of Light, it was the season of Darkness, and a last line to hold the anchor."

    private fun layout(): TextLayoutResult = measurer.measure(
        AnnotatedString(prose),
        style,
        TextOverflow.Clip,
        softWrap = true,
        constraints = Constraints(maxWidth = with(density) { 240.dp.roundToPx() }),
    )

    /** Somewhere inside the last word of the last line, in layout coordinates. */
    private fun lastWord(result: TextLayoutResult): Offset {
        val end = result.getLineEnd(result.lineCount - 1, visibleEnd = true)
        var start = end
        while (start > 0 && !prose[start - 1].isWhitespace()) start--
        return result.getBoundingBox((start + end - 1) / 2).center
    }

    @Test
    fun aHandleTouchedWhereItIsDrawnLeavesTheSelectionAlone() {
        val result = layout()
        assertTrue("the fixture wraps onto several lines", result.lineCount > 2)
        val state = PageSelectionState()
        state.layout = result
        val picked = state.selectWord(result, lastWord(result))
        assertTrue("a word, not a blank: '${prose.substring(picked.min, picked.max)}'", picked.min < picked.max)
        assertEquals(
            "the last line is where the selection sits",
            result.lineCount - 1,
            result.getLineForOffset(picked.max - 1),
        )

        // The page is exactly as tall as the text, so the last line's handle is
        // drawn against the clamp — the case the two halves used to disagree on.
        val height = result.size.height.toFloat()
        val (startHandle, endHandle) = state.handleCenters(radiusPx, height)!!

        state.moveHandle(SelectionHandle.End, endHandle, radiusPx)
        assertEquals("touching the end handle where it is drawn moves nothing", picked, state.range)

        state.moveHandle(SelectionHandle.Start, startHandle, radiusPx)
        assertEquals("nor does touching the start handle", picked, state.range)
    }

    @Test
    fun bothHandlesRoundTripOnEveryLine() {
        val result = layout()
        val state = PageSelectionState()
        state.layout = result
        val height = result.size.height.toFloat()
        for (line in 0 until result.lineCount) {
            val start = result.getLineStart(line)
            val end = result.getLineEnd(line, visibleEnd = true)
            if (end - start < 4) continue
            state.selectWord(result, result.getBoundingBox((start + end) / 2).center)
            val before: TextRange = state.range!!
            val (startHandle, endHandle) = state.handleCenters(radiusPx, height)!!
            state.moveHandle(SelectionHandle.Start, startHandle, radiusPx)
            state.moveHandle(SelectionHandle.End, endHandle, radiusPx)
            assertEquals("line $line", before, state.range)
        }
    }
}
