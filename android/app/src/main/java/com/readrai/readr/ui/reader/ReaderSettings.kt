package com.readrai.readr.ui.reader

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.ui.text.font.FontFamily
import com.readrai.readr.data.HighlightColor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The three reading themes, keyed as the iOS app persists them. */
enum class ReadingTheme(val key: String, val displayName: String) {
    Paper("paper", "Paper"), Sepia("sepia", "Sepia"), Night("night", "Dark");

    companion object {
        fun fromKey(key: String?): ReadingTheme = entries.firstOrNull { it.key == key } ?: Paper
    }
}

/**
 * Android ships no New York or Charter, so the choice is the platform serif
 * (Noto Serif) or sans. Persisted under the iOS key; an iOS value that isn't
 * one of ours reads as Serif unless it names the system sans.
 */
enum class ReaderFont(val key: String, val displayName: String, val family: FontFamily) {
    Serif("serif", "Serif", FontFamily.Serif), Sans("sans", "Sans", FontFamily.SansSerif);

    companion object {
        fun fromKey(key: String?): ReaderFont = when (key) {
            Sans.key, "sanFrancisco" -> Sans
            else -> Serif
        }
    }
}

/**
 * How the chapter is laid out, keyed as the iOS app persists it
 * (`Paginator.PageLayout`): a continuous scroll, one page, or two facing
 * pages. An unknown stored value reads as a single page, which is the
 * first-run default on both platforms.
 */
enum class PageLayout(val key: String, val displayName: String) {
    Scroll("scroll", "Scroll"), SinglePage("singlePage", "Single page"), DoublePage("doublePage", "Two pages");

    /** Text columns in one spread — the kit's `pagesPerSpread`. */
    val pagesPerSpread: Int get() = if (this == DoublePage) 2 else 1

    /**
     * What this layout means on a surface of this width. A facing-page spread
     * needs a wide window; on a narrow one a stored `doublePage` reads as a
     * single page — the *preference* is untouched, so a phone plugged into a
     * larger screen (or turned) gets its two pages back.
     */
    fun on(wide: Boolean): PageLayout = if (this == DoublePage && !wide) SinglePage else this

    companion object {
        fun fromKey(key: String?): PageLayout = entries.firstOrNull { it.key == key } ?: SinglePage
    }
}

/** Extra leading as a fraction of the font size, the same steps as iOS. */
enum class LineSpacing(val key: String, val displayName: String, val extraLeading: Float) {
    Compact("compact", "Compact", 0.10f), Normal("normal", "Normal", 0.24f), Relaxed("relaxed", "Relaxed", 0.52f);

    companion object {
        fun fromKey(key: String?): LineSpacing = entries.firstOrNull { it.key == key } ?: Normal
    }
}

data class ReaderAppearance(
    val theme: ReadingTheme = ReadingTheme.Paper,
    val fontSize: Int = DEFAULT_FONT_SIZE,
    val font: ReaderFont = ReaderFont.Serif,
    val spacing: LineSpacing = LineSpacing.Normal,
    val justified: Boolean = true,
    val layout: PageLayout = PageLayout.SinglePage,
) {
    /** Line height as a multiple of the font size: a 1.2 em line box plus the extra leading. */
    val lineHeightMultiplier: Float get() = 1.2f + spacing.extraLeading

    companion object {
        const val DEFAULT_FONT_SIZE = 18
        val fontSizeRange = 13..30
    }
}

/**
 * Reader appearance, persisted in plain SharedPreferences (nothing here is a
 * secret) under the keys the iOS app uses, so the values mean the same thing
 * on both platforms. One instance per process; the flow is what the UI reads.
 */
class ReaderSettings(context: Context, name: String = PREFERENCES) {
    private val prefs: SharedPreferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)
    private val _appearance = MutableStateFlow(load())
    val appearance: StateFlow<ReaderAppearance> = _appearance.asStateFlow()

    /**
     * The colour the reader last highlighted with, under the iOS key. It is
     * deliberately not part of [ReaderAppearance]: nothing about it changes
     * layout, so it must never reach a `LayoutKey` and re-paginate a chapter.
     */
    private val _lastHighlightColor = MutableStateFlow(HighlightColor.fromKey(prefs.getString(KEY_LAST_HIGHLIGHT_COLOR, null).orEmpty()))
    val lastHighlightColor: StateFlow<HighlightColor> = _lastHighlightColor.asStateFlow()

    fun rememberHighlightColor(color: HighlightColor) {
        _lastHighlightColor.value = color
        prefs.edit().putString(KEY_LAST_HIGHLIGHT_COLOR, color.key).apply()
    }

    /**
     * The speaking speed, under the iOS key, so a reader who listens on both
     * gets the same pace. Kept outside [ReaderAppearance] for the same reason
     * the last highlight colour is: nothing about it changes layout, so it
     * must never reach a `LayoutKey` and re-paginate a chapter.
     */
    var narrationRate: Double
        get() = prefs.getFloat(KEY_NARRATION_RATE, 1f).toDouble()
        set(value) { prefs.edit().putFloat(KEY_NARRATION_RATE, value.toFloat()).apply() }

    /**
     * The chosen voice, under the iOS key — versioned there (`…ID2`) because
     * the first build's choices could land on a novelty voice. Android has no
     * novelty voices, but sharing the key keeps one preference file meaning
     * one thing.
     */
    var narrationVoiceID: String?
        get() = prefs.getString(KEY_NARRATION_VOICE, null)
        set(value) {
            prefs.edit().apply {
                if (value == null) remove(KEY_NARRATION_VOICE) else putString(KEY_NARRATION_VOICE, value)
            }.apply()
        }

    fun update(transform: (ReaderAppearance) -> ReaderAppearance) {
        val next = transform(_appearance.value).let { it.copy(fontSize = it.fontSize.coerceIn(ReaderAppearance.fontSizeRange)) }
        _appearance.value = next
        prefs.edit()
            .putString(KEY_THEME, next.theme.key)
            .putFloat(KEY_FONT_SIZE, next.fontSize.toFloat())
            .putString(KEY_FONT, next.font.key)
            .putString(KEY_SPACING, next.spacing.key)
            .putBoolean(KEY_JUSTIFIED, next.justified)
            .putString(KEY_LAYOUT, next.layout.key)
            .apply()
    }

    private fun load(): ReaderAppearance = ReaderAppearance(
        theme = ReadingTheme.fromKey(prefs.getString(KEY_THEME, null)),
        fontSize = prefs.getFloat(KEY_FONT_SIZE, ReaderAppearance.DEFAULT_FONT_SIZE.toFloat()).toInt().coerceIn(ReaderAppearance.fontSizeRange),
        font = ReaderFont.fromKey(prefs.getString(KEY_FONT, null)),
        spacing = LineSpacing.fromKey(prefs.getString(KEY_SPACING, null)),
        justified = prefs.getBoolean(KEY_JUSTIFIED, true),
        layout = PageLayout.fromKey(prefs.getString(KEY_LAYOUT, null)),
    )

    companion object {
        const val PREFERENCES = "reader"
        const val KEY_THEME = "readingTheme"
        const val KEY_FONT_SIZE = "readingFontSize"
        const val KEY_FONT = "readingFont"
        const val KEY_SPACING = "readingLineSpacing"
        const val KEY_JUSTIFIED = "readingJustified"
        const val KEY_LAYOUT = "readerLayout"
        const val KEY_LAST_HIGHLIGHT_COLOR = "lastHighlightColor"
        const val KEY_NARRATION_RATE = "narrationRate"
        const val KEY_NARRATION_VOICE = "narrationVoiceID2"
    }
}
