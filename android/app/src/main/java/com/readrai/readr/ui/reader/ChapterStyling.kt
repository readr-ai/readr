package com.readrai.readr.ui.reader

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.LayoutSpan
import com.readrai.readr.ui.theme.ReadingPalette

/** The appearance fields that change layout. Colour is applied at draw time and never re-paginates. */
data class LayoutKey(val fontSize: Int, val font: ReaderFont, val spacing: LineSpacing, val justified: Boolean) {
    val lineHeightMultiplier: Float get() = 1.2f + spacing.extraLeading

    constructor(appearance: ReaderAppearance) : this(appearance.fontSize, appearance.font, appearance.spacing, appearance.justified)
}

/**
 * A chapter styled for one [LayoutKey]. `paragraphStarts` are the offsets
 * where the kit's paragraphs begin (ascending, starting at 0) — the one
 * source of paragraph boundaries for chunking, page slicing and indents,
 * since the string itself no longer carries newlines (see [ChapterStyling]).
 */
class StyledChapter(val text: AnnotatedString, val paragraphStarts: IntArray) {
    /** Whether `offset` begins a paragraph. */
    fun startsParagraph(offset: Int): Boolean = paragraphStarts.binarySearch(offset) >= 0

    /** The last paragraph start at or before `offset`. */
    fun paragraphStart(atOrBefore: Int): Int {
        val i = paragraphStarts.binarySearch(atOrBefore)
        return if (i >= 0) paragraphStarts[i] else paragraphStarts[(-i - 1) - 1]
    }
}

/**
 * Turns a chapter's text and format spans into what the page draws.
 *
 * Every kit paragraph (they are separated by a single `\n`) becomes one
 * Compose paragraph with its own `ParagraphStyle` — that is where first-line
 * indents, heading line heights and alignment live. Compose lays each
 * paragraph range out as its own text, verbatim, and Android's layout turns
 * a trailing newline into an extra empty line, so every newline is drawn as
 * a space. The string keeps its length: every UTF-16 offset still means
 * what it means in the kit's text.
 */
object ChapterStyling {
    private const val LINK_TAG = "link"

    /** Heading scale by level, as on iOS (`Theme.swift`): h1 1.6, h2 1.35, h3 1.2, else 1.05. */
    fun headingScale(level: Int?): Float = when (level) {
        1 -> 1.6f
        2 -> 1.35f
        3 -> 1.2f
        else -> 1.05f
    }

    /**
     * The page's base style. `LineBreak.Simple` is deliberate: greedy
     * breaking makes a line's break depend only on where the line starts, so
     * a page rendered from a line boundary breaks exactly as it measured.
     */
    fun pageTextStyle(layout: LayoutKey, palette: ReadingPalette): TextStyle = TextStyle(
        fontFamily = layout.font.family,
        fontSize = layout.fontSize.sp,
        lineHeight = (layout.fontSize * layout.lineHeightMultiplier).sp,
        color = palette.ink,
        textAlign = if (layout.justified) TextAlign.Justify else TextAlign.Start,
        hyphens = if (layout.justified) Hyphens.Auto else Hyphens.None,
        lineBreak = LineBreak.Simple,
        lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )

    private class ParagraphAttributes {
        var headingLevel: Int? = null
        var quote = false
        var align: TextAlign? = null
    }

    fun styled(text: String, spans: List<LayoutSpan>, layout: LayoutKey): StyledChapter {
        val length = text.length
        val starts = ArrayList<Int>().apply {
            add(0)
            var i = text.indexOf('\n')
            while (i >= 0) { add(i + 1); i = text.indexOf('\n', i + 1) }
        }
        val paragraphStarts = starts.toIntArray()
        if (length == 0) return StyledChapter(AnnotatedString(""), paragraphStarts)
        val fontSize = layout.fontSize
        val lineHeight = fontSize * layout.lineHeightMultiplier

        // Paragraph i covers [starts[i], starts[i + 1]) including its newline.
        fun paragraphIndex(offset: Int): Int {
            val i = paragraphStarts.binarySearch(offset)
            return if (i >= 0) i else (-i - 1) - 1
        }
        val attributes = HashMap<Int, ParagraphAttributes>()
        fun forEachParagraph(start: Int, end: Int, block: (ParagraphAttributes) -> Unit) {
            for (p in paragraphIndex(start)..paragraphIndex(end - 1)) block(attributes.getOrPut(p) { ParagraphAttributes() })
        }

        val clamped = spans.mapNotNull { span ->
            val s = span.start.coerceIn(0, length)
            val e = span.end.coerceIn(0, length)
            if (s < e) span.copy(start = s, end = e) else null
        }
        for (span in clamped) {
            when (span.kind) {
                "heading" -> forEachParagraph(span.start, span.end) { it.headingLevel = span.level ?: 4 }
                "blockquote" -> forEachParagraph(span.start, span.end) { it.quote = true }
                "alignment" -> {
                    val align = when (span.alignment) {
                        "center" -> TextAlign.Center
                        "right" -> TextAlign.End
                        "left" -> TextAlign.Start
                        else -> null
                    }
                    if (align != null) forEachParagraph(span.start, span.end) { it.align = align }
                }
            }
        }

        val bodyAlign = if (layout.justified) TextAlign.Justify else TextAlign.Start
        val annotated = buildAnnotatedString {
            append(text.replace('\n', ' '))
            for (p in paragraphStarts.indices) {
                val start = paragraphStarts[p]
                val end = if (p + 1 < paragraphStarts.size) paragraphStarts[p + 1] else length
                if (start >= end) continue
                val attrs = attributes[p]
                val heading = attrs?.headingLevel
                addStyle(
                    ParagraphStyle(
                        textAlign = attrs?.align ?: if (heading != null) TextAlign.Start else bodyAlign,
                        textIndent = when {
                            heading != null || attrs?.align == TextAlign.Center -> TextIndent.None
                            attrs?.quote == true -> TextIndent(firstLine = 1.5.em, restLine = 1.5.em)
                            else -> TextIndent(firstLine = 1.5.em)
                        },
                        lineHeight = if (heading != null) (fontSize * headingScale(heading) * layout.lineHeightMultiplier).sp else lineHeight.sp,
                    ),
                    start, end,
                )
            }
            for (span in clamped) {
                val style = when (span.kind) {
                    "heading" -> SpanStyle(fontSize = (fontSize * headingScale(span.level)).sp, fontWeight = FontWeight.Bold)
                    "bold" -> SpanStyle(fontWeight = FontWeight.Bold)
                    "italic", "blockquote" -> SpanStyle(fontStyle = FontStyle.Italic)
                    "superscript" -> SpanStyle(baselineShift = BaselineShift.Superscript, fontSize = (fontSize * 0.7f).sp)
                    "subscript" -> SpanStyle(baselineShift = BaselineShift.Subscript, fontSize = (fontSize * 0.7f).sp)
                    "smallCaps" -> SpanStyle(fontFeatureSettings = "smcp")
                    "link" -> { addStringAnnotation(LINK_TAG, span.url ?: "", span.start, span.end); null }
                    else -> null
                }
                if (style != null) addStyle(style, span.start, span.end)
            }
        }
        return StyledChapter(annotated, paragraphStarts)
    }

    /**
     * The slice of the styled chapter a page draws, coloured for the theme.
     * A page that opens in the middle of a paragraph must not indent its
     * first line differently from the line it was measured as — a
     * continuation line — so that paragraph's fragment takes its rest-line
     * indent for its first line too.
     */
    fun pageText(chapter: StyledChapter, textStart: Int, textEnd: Int, palette: ReadingPalette): AnnotatedString {
        val slice = chapter.text.subSequence(textStart, textEnd)
        val midParagraph = textStart > 0 && !chapter.startsParagraph(textStart)
        return buildAnnotatedString {
            append(slice.text)
            slice.spanStyles.forEach { addStyle(it.item, it.start, it.end) }
            slice.paragraphStyles.forEach {
                val item = if (midParagraph && it.start == 0) {
                    val rest = it.item.textIndent?.restLine ?: 0.sp
                    it.item.copy(textIndent = TextIndent(firstLine = rest, restLine = rest))
                } else it.item
                addStyle(item, it.start, it.end)
            }
            slice.getStringAnnotations(LINK_TAG, 0, slice.length).forEach { addStyle(SpanStyle(color = palette.iris), it.start, it.end) }
        }
    }
}
