package com.readrai.readr.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * "Marginalia" — the same tokens as `App/Design/Theme.swift`: warm paper
 * surfaces, serif for the page, sans for chrome, and one reserved iris accent
 * for AI moments (✦). Keep the two files in step.
 */
object Marginalia {
    val iris = Color(0xFF5B57C7)
    val irisOnDark = Color(0xFF938EE9)
    const val aiGlyph = "✦"

    // Reading themes (raw names kept for parity with persisted iOS values)
    object Paper { val background = Color(0xFFEFEBE1); val page = Color(0xFFFAF7F0); val ink = Color(0xFF26221C); val secondary = Color(0xFF7E7669); val tertiary = Color(0xFFA89F8F) }
    object Sepia { val background = Color(0xFFE4D8BD); val page = Color(0xFFF3E9D0); val ink = Color(0xFF3B3020); val secondary = Color(0xFF83745B); val tertiary = Color(0xFFA29170) }
    object Night { val background = Color(0xFF131109); val page = Color(0xFF1E1B14); val ink = Color(0xFFE7E0D1); val secondary = Color(0xFF9C9483); val tertiary = Color(0xFF6F6857) }

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

private val lightScheme: ColorScheme = lightColorScheme(
    primary = Marginalia.iris,
    background = Marginalia.Paper.background,
    surface = Marginalia.Paper.page,
    onBackground = Marginalia.Paper.ink,
    onSurface = Marginalia.Paper.ink,
    onSurfaceVariant = Marginalia.Paper.secondary,
    outline = Marginalia.Paper.tertiary,
)

private val darkScheme: ColorScheme = darkColorScheme(
    primary = Marginalia.irisOnDark,
    background = Marginalia.Night.background,
    surface = Marginalia.Night.page,
    onBackground = Marginalia.Night.ink,
    onSurface = Marginalia.Night.ink,
    onSurfaceVariant = Marginalia.Night.secondary,
    outline = Marginalia.Night.tertiary,
)

val readrTypography = Typography(
    titleLarge = TextStyle(fontFamily = FontFamily.Serif, fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.Serif, fontWeight = FontWeight.Medium, fontSize = 17.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.Serif, fontSize = 18.sp, lineHeight = 31.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp),
    labelSmall = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 11.sp, letterSpacing = 1.sp),
)

@Composable
fun ReadrTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (dark) darkScheme else lightScheme, typography = readrTypography, content = content)
}
