package com.readrai.readr.ui.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

/**
 * Apple's minimum, and Material's: nothing the reader taps is smaller than a
 * fingertip. One constant, because the reader's bar, the Listen card and the
 * annotation capsule sit within a thumb's reach of each other and a control
 * that is 40 dp beside one that is 44 reads as a mistake.
 */
val touchTarget = 44.dp

/**
 * A speaker with a wave — the Listen mark, wherever it appears: the reader's
 * bottom bar and the annotation capsule's "Listen from here". Drawn rather
 * than bundled, like the capsule's copy mark, because Material's core icon set
 * has no speaker. The size comes from `modifier`, so one shape serves both.
 */
@Composable
fun SpeakerGlyph(color: Color, modifier: Modifier = Modifier.size(16.dp)) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val cone = Path().apply {
            moveTo(w * 0.06f, h * 0.36f)
            lineTo(w * 0.26f, h * 0.36f)
            lineTo(w * 0.52f, h * 0.10f)
            lineTo(w * 0.52f, h * 0.90f)
            lineTo(w * 0.26f, h * 0.64f)
            lineTo(w * 0.06f, h * 0.64f)
            close()
        }
        drawPath(cone, color)
        drawArc(
            color,
            startAngle = -55f,
            sweepAngle = 110f,
            useCenter = false,
            topLeft = Offset(w * 0.34f, h * 0.20f),
            size = Size(w * 0.52f, h * 0.60f),
            style = Stroke(width = 1.4.dp.toPx()),
        )
    }
}
