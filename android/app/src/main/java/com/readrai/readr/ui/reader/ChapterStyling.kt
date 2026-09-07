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

/**
 * Turns a chapter's text and format spans into what the page draws.
 *
 * Every kit paragraph (they are separated by a single `\n`) becomes one
 * Compose paragraph with its own `ParagraphStyle` — that is where first-line
 * indents, heading line heights and alignment live. Compose lays each
 * paragraph range out as its own text, verbatim, and Android's layout turns
 * a trailing newline into an extra empty line, so the newline that closes a
 * styled paragraph is drawn as a space. The string keeps its length: every
 * UTF-16 offset still means what it means in the kit's text.
 */
object ChapterStyling {
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
    fun pageTextStyle(appearance: ReaderAppearance, palette: ReadingPalette): TextStyle = TextStyle(
        fontFamily = appearance.font.family,
        fontSize = appearance.fontSize.sp,
        lineHeight = (appearance.fontSize * appearance.lineHeightMultiplier).sp,
        color = palette.ink,
        textAlign = if (appearance.justified) TextAlign.Justify else TextAlign.Start,
        hyphens = if (appearance.justified) Hyphens.Auto else Hyphens.None,
        lineBreak = LineBreak.Simple,
        lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )

    private class ParagraphAttributes {
        var headingLevel: Int? = null
        var quote = false
        var align: TextAlign? = null
    }

    fun styled(text: String, spans: List<LayoutSpan>, appearance: ReaderAppearance, palette: ReadingPalette): AnnotatedString {
        val length = text.length
        if (length == 0) return AnnotatedString("")
        val chars = text.toCharArray()
        val fontSize = appearance.fontSize
        val lineHeight = fontSize * appearance.lineHeightMultiplier

        // Paragraph starts, in order, and the attributes spans give them.
        val starts = ArrayList<Int>()
        run {
            var p = 0
            while (p <= length) {
                starts.add(p)
                val nl = text.indexOf('\n', p)
                if (nl < 0) break
                p = nl + 1
            }
        }
        val attributes = HashMap<Int, ParagraphAttributes>()
        fun paragraphStart(offset: Int): Int = if (offset <= 0) 0 else text.lastIndexOf('\n', offset - 1) + 1
        fun paragraphEnd(start: Int): Int = text.indexOf('\n', start).let { if (it < 0) length else it }
        fun forEachParagraph(start: Int, end: Int, block: (ParagraphAttributes) -> Unit) {
            var p = paragraphStart(start)
            while (p < end) {
                block(attributes.getOrPut(p) { ParagraphAttributes() })
                p = paragraphEnd(p) + 1
            }
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

        // The newline closing each paragraph is drawn as a space (see above).
        for (start in starts) {
            val end = paragraphEnd(start)
            if (end < length) chars[end] = ' '
        }

        return buildAnnotatedString {
            append(String(chars))
            for (start in starts) {
                val end = minOf(paragraphEnd(start) + 1, length)
                if (start >= end) continue
                val attrs = attributes[start]
                val heading = attrs?.headingLevel
                val style = ParagraphStyle(
                    textAlign = attrs?.align ?: if (heading != null) TextAlign.Start else if (appearance.justified) TextAlign.Justify else TextAlign.Start,
                    textIndent = when {
                        heading != null || attrs?.align == TextAlign.Center -> TextIndent.None
                        attrs?.quote == true -> TextIndent(firstLine = 1.5.em, restLine = 1.5.em)
                        else -> TextIndent(firstLine = 1.5.em)
                    },
                    lineHeight = if (heading != null) (fontSize * headingScale(heading) * appearance.lineHeightMultiplier).sp else lineHeight.sp,
                )
                addStyle(style, start, end)
            }
            for (span in clamped) {
                val style = when (span.kind) {
                    "heading" -> SpanStyle(fontSize = (fontSize * headingScale(span.level)).sp, fontWeight = FontWeight.Bold)
                    "bold" -> SpanStyle(fontWeight = FontWeight.Bold)
                    "italic", "blockquote" -> SpanStyle(fontStyle = FontStyle.Italic)
                    "superscript" -> SpanStyle(baselineShift = BaselineShift.Superscript, fontSize = (fontSize * 0.7f).sp)
                    "subscript" -> SpanStyle(baselineShift = BaselineShift.Subscript, fontSize = (fontSize * 0.7f).sp)
                    "smallCaps" -> SpanStyle(fontFeatureSettings = "smcp")
                    "link" -> SpanStyle(color = palette.iris)
                    else -> null
                }
                if (style != null) addStyle(style, span.start, span.end)
            }
        }
    }

    /**
     * The slice of the styled chapter a page draws. A page that opens in the
     * middle of a paragraph must not indent its first line — the layout that
     * measured it didn't — so that paragraph's fragment loses its indent.
     */
    fun pageText(chapter: AnnotatedString, textStart: Int, textEnd: Int): AnnotatedString {
        val slice = chapter.subSequence(textStart, textEnd)
        if (textStart == 0 || startsParagraph(chapter, textStart)) return slice
        return buildAnnotatedString {
            append(slice.text)
            slice.spanStyles.forEach { addStyle(it.item, it.start, it.end) }
            slice.paragraphStyles.forEach {
                val item = if (it.start == 0) it.item.copy(textIndent = it.item.textIndent?.let { indent -> TextIndent(firstLine = 0.sp, restLine = indent.restLine) }) else it.item
                addStyle(item, it.start, it.end)
            }
        }
    }

    /** Whether `offset` begins a paragraph range of `chapter` (paragraph boundaries survive the newline swap as range starts). */
    private fun startsParagraph(chapter: AnnotatedString, offset: Int): Boolean =
        chapter.paragraphStyles.any { it.start == offset }
}
