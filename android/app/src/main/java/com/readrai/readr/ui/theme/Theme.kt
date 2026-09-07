package com.readrai.readr.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.HighlightColor
import com.readrai.readr.ui.reader.ReadingTheme

/** The colour roles of one reading theme — the same roles as `ReadingTheme` in `App/Design/Theme.swift`. */
data class ReadingPalette(
    val background: Color,
    val page: Color,
    val elevated: Color,
    val ink: Color,
    val muted: Color,
    val faint: Color,
    val line: Color,
    val iris: Color,
    val markers: Map<HighlightColor, Color>,
    val isDark: Boolean,
) {
    /**
     * The field a highlight of `color` is drawn on in this theme — the iOS
     * `marker(_:)` table. A colour the kit adds later falls back to yellow,
     * as `Highlight.markerColor` does.
     */
    fun marker(color: HighlightColor): Color = markers[color] ?: markers.getValue(HighlightColor.YELLOW)
}

/**
 * "Marginalia" — the same tokens as `App/Design/Theme.swift`: warm paper
 * surfaces, serif for the page, sans for chrome, and one reserved iris accent
 * for AI moments (✦). Keep the two files in step.
 */
object Marginalia {
    val iris = Color(0xFF5B57C7)
    val irisOnDark = Color(0xFF938EE9)
    const val aiGlyph = "✦"

    /** The mark a note wears, wherever one is shown — `AppTheme.noteGlyph` on iOS. */
    const val noteGlyph = "❋"

    /**
     * Highlight fields, the "muted literary" palette of `App/Design/Theme.swift`.
     * Paper and sepia use opaque fields; night washes the same hues over the
     * dark page so the text stays luminous.
     */
    private val paperMarkers = mapOf(
        HighlightColor.YELLOW to Color(0xFFEAD8A2), // amber
        HighlightColor.GREEN to Color(0xFFCBD6B2),  // sage
        HighlightColor.BLUE to Color(0xFFC2D3E0),   // slate
        HighlightColor.PINK to Color(0xFFE9C8B8),   // clay
        HighlightColor.PURPLE to Color(0xFFD8CCE4), // lavender
    )
    private val sepiaMarkers = mapOf(
        HighlightColor.YELLOW to Color(0xFFE4CE8F),
        HighlightColor.GREEN to Color(0xFFC4CFA3),
        HighlightColor.BLUE to Color(0xFFBCCAD2),
        HighlightColor.PINK to Color(0xFFE3BFA9),
        HighlightColor.PURPLE to Color(0xFFCFC2DC),
    )
    private val nightMarkers = mapOf(
        HighlightColor.YELLOW to Color(0xFFE2BC68).copy(alpha = 0.32f),
        HighlightColor.GREEN to Color(0xFFA3C078).copy(alpha = 0.30f),
        HighlightColor.BLUE to Color(0xFF7AA8CC).copy(alpha = 0.30f),
        HighlightColor.PINK to Color(0xFFE29876).copy(alpha = 0.30f),
        HighlightColor.PURPLE to Color(0xFFB296DC).copy(alpha = 0.30f),
    )

    /** The solid dot a colour is offered as, in any theme — iOS's `markerSwatch`. */
    fun markerSwatch(color: HighlightColor): Color = paperMarkers.getValue(color)

    /** The four colours the annotation capsule offers; purple stays renderable for older highlights. */
    val pickerColors = listOf(HighlightColor.YELLOW, HighlightColor.GREEN, HighlightColor.BLUE, HighlightColor.PINK)

    val paper = ReadingPalette(
        background = Color(0xFFEFEBE1), page = Color(0xFFFAF7F0), elevated = Color(0xFFFFFFFF),
        ink = Color(0xFF26221C), muted = Color(0xFF7E7669), faint = Color(0xFFA89F8F),
        line = Color(0xFF26221C).copy(alpha = 0.14f), iris = iris, markers = paperMarkers, isDark = false,
    )
    val sepia = ReadingPalette(
        background = Color(0xFFE4D8BD), page = Color(0xFFF3E9D0), elevated = Color(0xFFFAF2DD),
        ink = Color(0xFF3B3020), muted = Color(0xFF83745B), faint = Color(0xFFA29170),
        line = Color(0xFF3B3020).copy(alpha = 0.17f), iris = iris, markers = sepiaMarkers, isDark = false,
    )
    val night = ReadingPalette(
        background = Color(0xFF131109), page = Color(0xFF1E1B14), elevated = Color(0xFF282419),
        ink = Color(0xFFE7E0D1), muted = Color(0xFF9C9483), faint = Color(0xFF6F6857),
        line = Color(0xFFE7E0D1).copy(alpha = 0.15f), iris = irisOnDark, markers = nightMarkers, isDark = true,
    )

    fun palette(theme: ReadingTheme): ReadingPalette = when (theme) {
        ReadingTheme.Paper -> paper
        ReadingTheme.Sepia -> sepia
        ReadingTheme.Night -> night
    }

    /** Placeholder cover tints (field, ink), picked by an FNV-1a hash of the title — same table as iOS. */
    val coverTints = listOf(
        Color(0xFF2F4356) to Color(0xFFEDE6D6),
        Color(0xFF584434) to Color(0xFFF0E7D4),
        Color(0xFF3E4A33) to Color(0xFFEAE8D5),
        Color(0xFF5A3B3B) to Color(0xFFF1E4DA),
        Color(0xFF3B3B55) to Color(0xFFE8E6F0),
        Color(0xFF6B5A2E) to Color(0xFFF3EBD3),
    )

    fun coverTint(title: String): Pair<Color, Color> {
        var hash = 0xcbf29ce484222325uL
        for (byte in title.encodeToByteArray()) { hash = (hash xor byte.toUByte().toULong()) * 0x100000001b3uL }
        return coverTints[(hash % coverTints.size.toULong()).toInt()]
    }
}

val LocalReadingPalette = staticCompositionLocalOf { Marginalia.paper }

private fun ReadingPalette.colorScheme(): ColorScheme {
    val base = if (isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = iris,
        background = background,
        surface = page,
        surfaceContainer = elevated,
        surfaceContainerLow = elevated,
        surfaceContainerHigh = elevated,
        onBackground = ink,
        onSurface = ink,
        onSurfaceVariant = muted,
        outline = faint,
        outlineVariant = line,
    )
}

val readrTypography = Typography(
    titleLarge = TextStyle(fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.Serif, fontWeight = FontWeight.Medium, fontSize = 17.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.Serif, fontSize = 18.sp, lineHeight = 31.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp),
    labelSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 11.sp, letterSpacing = 1.sp),
)

/** The reading theme drives the whole app, as on iOS, so the shelf and sheets match the page. */
@Composable
fun ReadrTheme(theme: ReadingTheme = ReadingTheme.Paper, content: @Composable () -> Unit) {
    val palette = Marginalia.palette(theme)
    CompositionLocalProvider(LocalReadingPalette provides palette) {
        MaterialTheme(colorScheme = palette.colorScheme(), typography = readrTypography, content = content)
    }
}
