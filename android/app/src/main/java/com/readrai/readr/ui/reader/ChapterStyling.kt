package com.readrai.readr.ui.reader

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.material3.Text
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.BaselineShift
import androidx.compose.ui.text.style.Hyphens
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.readrai.readr.data.Highlight
import com.readrai.readr.data.InlineImage
import com.readrai.readr.data.LayoutSpan
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.ReadingPalette

/**
 * The pictures that have arrived so far, by placeholder id. Deliberately a
 * composition local and not part of [StyledChapter]: a bitmap landing must
 * change nothing that was measured — the box on the page is already the size
 * the header said, and only what is drawn inside it changes — so this must
 * never reach a [PageKey].
 */
val LocalInlineBitmaps = compositionLocalOf<Map<String, ImageBitmap>> { emptyMap() }

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
 *
 * `placeholders` and `inlineContent` are the chapter's inline images, and are
 * two halves of one fact: the placeholders are what the text is *measured*
 * with and the map is what fills them when it is *drawn*, so a page can only
 * be the page that was measured if both are used. `images` are those same
 * pictures as they were placed, kept so the surface can go and fetch their
 * bytes once the pages exist. `links` are the link spans, in chapter offsets,
 * which the page hit-tests a tap against.
 */
class StyledChapter(
    val text: AnnotatedString,
    val paragraphStarts: IntArray,
    val placeholders: List<AnnotatedString.Range<Placeholder>> = emptyList(),
    val inlineContent: Map<String, InlineTextContent> = emptyMap(),
    val images: List<InlineImage> = emptyList(),
    val links: List<ChapterLink> = emptyList(),
) {
    /** Whether `offset` begins a paragraph. */
    fun startsParagraph(offset: Int): Boolean = paragraphStarts.binarySearch(offset) >= 0

    /** The last paragraph start at or before `offset`. */
    fun paragraphStart(atOrBefore: Int): Int {
        val i = paragraphStarts.binarySearch(atOrBefore)
        return if (i >= 0) paragraphStarts[i] else paragraphStarts[(-i - 1) - 1]
    }

    /**
     * The placeholders lying wholly inside `[start, end)`, rebased to that
     * slice — what a measurement of `text.subSequence(start, end)` needs. A
     * placeholder is one character wide and a slice never cuts a character,
     * so no image is ever half-measured.
     */
    fun placeholdersIn(start: Int, end: Int): List<AnnotatedString.Range<Placeholder>> {
        if (placeholders.isEmpty()) return emptyList()
        return placeholders
            .filter { it.start >= start && it.end <= end }
            .map { AnnotatedString.Range(it.item, it.start - start, it.end - start) }
    }

    /** The link under a chapter offset, or null where there is none. */
    fun linkAt(offset: Int): ChapterLink? = links.firstOrNull { offset >= it.start && offset < it.end }
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
    /**
     * The tag Compose's own inline-content mechanism reads. `Text` resolves a
     * string annotation under this tag against the `inlineContent` map it is
     * given, and draws the entry it finds in place of the annotated
     * characters — here, the single U+FFFC the kit left where the image was.
     * It is spelled out rather than imported because the constant Compose
     * uses for it is internal to that library.
     */
    const val INLINE_CONTENT_TAG = "androidx.compose.foundation.text.inlineContent"

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

    /**
     * `images` are the chapter's inline pictures, already sized for this
     * page's geometry ([com.readrai.readr.data.ChapterImages.place]). Each one
     * covers the single U+FFFC the kit left in the text at its offset, so the
     * string keeps its length and every offset still means what it means to
     * the kit — a picture, like a highlight, never moves a line break.
     */
    fun styled(
        text: String,
        spans: List<LayoutSpan>,
        layout: LayoutKey,
        images: List<InlineImage> = emptyList(),
    ): StyledChapter {
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

        // An image whose placeholder is no longer in the text belongs to a
        // chapter that has since changed; it is dropped rather than drawn over
        // a character that means something else.
        val placed = images.filter { it.utf16Offset in 0 until length }.sortedBy { it.utf16Offset }
        // Compose forces a line to the height its paragraph declares, so the
        // paragraph an image sits in declares the picture's own height. The
        // tallest image in a paragraph wins it.
        val imageLineHeights = HashMap<Int, Float>()
        for (image in placed) {
            val p = paragraphIndex(image.utf16Offset)
            imageLineHeights[p] = maxOf(imageLineHeights[p] ?: 0f, image.lineHeight.value)
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
        val links = ArrayList<ChapterLink>()
        val annotated = buildAnnotatedString {
            append(text.replace('\n', ' '))
            for (p in paragraphStarts.indices) {
                val start = paragraphStarts[p]
                val end = if (p + 1 < paragraphStarts.size) paragraphStarts[p + 1] else length
                if (start >= end) continue
                val attrs = attributes[p]
                val heading = attrs?.headingLevel
                val picture = imageLineHeights[p]
                addStyle(
                    ParagraphStyle(
                        textAlign = attrs?.align ?: when {
                            heading != null -> TextAlign.Start
                            picture != null -> TextAlign.Center
                            else -> bodyAlign
                        },
                        textIndent = when {
                            heading != null || picture != null || attrs?.align == TextAlign.Center -> TextIndent.None
                            attrs?.quote == true -> TextIndent(firstLine = 1.5.em, restLine = 1.5.em)
                            else -> TextIndent(firstLine = 1.5.em)
                        },
                        lineHeight = when {
                            picture != null -> maxOf(picture, lineHeight).sp
                            heading != null -> (fontSize * headingScale(heading) * layout.lineHeightMultiplier).sp
                            else -> lineHeight.sp
                        },
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
                    "link" -> {
                        links.add(ChapterLink(span.start, span.end, span.url, span.linkPath, span.linkFragment))
                        null
                    }
                    else -> null
                }
                if (style != null) addStyle(style, span.start, span.end)
            }
            // The annotation Compose's inline content reads; the placeholder
            // below is the same range, and the two are handed to the same
            // measurement and the same draw.
            for (image in placed) {
                addStringAnnotation(INLINE_CONTENT_TAG, image.id, image.utf16Offset, image.utf16Offset + 1)
            }
        }
        return StyledChapter(
            text = annotated,
            paragraphStarts = paragraphStarts,
            placeholders = placed.map { AnnotatedString.Range(it.placeholder, it.utf16Offset, it.utf16Offset + 1) },
            inlineContent = placed.associate { it.id to inlineContent(it) },
            images = placed,
            links = links,
        )
    }

    /**
     * What fills an image's placeholder: the picture, scaled to fit the box
     * that was measured; or, when the entry could not be read, its alt text in
     * a muted serif — a line of the book saying what is missing rather than a
     * blank. An image with neither bytes nor alt text leaves a hairline, so
     * the gap on the page is legible as a gap.
     *
     * The bitmap is read from [LocalInlineBitmaps] at draw time, not held on
     * the image: the box was sized from the archive's header long before the
     * pixels were decoded, and it does not move when they land. Until they do,
     * a picture that is coming leaves its box empty rather than flashing the
     * alt text at it.
     */
    private fun inlineContent(image: InlineImage): InlineTextContent = InlineTextContent(image.placeholder) {
        val palette = LocalReadingPalette.current
        val bitmap = LocalInlineBitmaps.current[image.id]
        when {
            bitmap != null -> Image(
                bitmap = bitmap,
                contentDescription = image.alt.ifBlank { null },
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize().testTag("reader.image.${image.utf16Offset}"),
            )
            image.hasPicture -> Box(Modifier.fillMaxSize().testTag("reader.imagePending.${image.utf16Offset}"))
            image.alt.isNotBlank() -> Box(
                Modifier.fillMaxSize().testTag("reader.imageAlt.${image.utf16Offset}"),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    image.alt,
                    fontFamily = FontFamily.Serif,
                    fontStyle = FontStyle.Italic,
                    color = palette.muted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            else -> Box(
                Modifier.fillMaxSize().testTag("reader.imageAlt.${image.utf16Offset}"),
                contentAlignment = Alignment.Center,
            ) { Box(Modifier.fillMaxWidth().height(1.dp).background(palette.line)) }
        }
    }

    /**
     * The slice of the styled chapter a page draws, coloured for the theme
     * and with its highlights drawn on it. A page that opens in the middle of
     * a paragraph must not indent its first line differently from the line it
     * was measured as — a continuation line — so that paragraph's fragment
     * takes its rest-line indent for its first line too.
     *
     * A highlight is a background field over its glyphs — and an underline
     * when it carries a note — never an inserted glyph, so marking a passage
     * cannot move a line break and the page stays the page that was measured.
     * `highlights` are the ones for this chapter (offsets are chapter-wide
     * UTF-16); ones that miss the page contribute nothing, and ones that
     * straddle its edges are clipped.
     */
    fun pageText(
        chapter: StyledChapter,
        textStart: Int,
        textEnd: Int,
        palette: ReadingPalette,
        highlights: List<Highlight> = emptyList(),
    ): AnnotatedString {
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
            // The inline-image annotations travel with the slice: they are what
            // makes the page draw the picture that the page was measured with.
            slice.getStringAnnotations(INLINE_CONTENT_TAG, 0, slice.length).forEach {
                addStringAnnotation(INLINE_CONTENT_TAG, it.item, it.start, it.end)
            }
            // Links are iris in either direction; only one that leaves the book
            // is underlined, so "this goes somewhere else" is visible before the tap.
            for (link in chapter.links) {
                val start = maxOf(link.start, textStart)
                val end = minOf(link.end, textEnd)
                if (start >= end) continue
                addStyle(
                    SpanStyle(
                        color = palette.iris,
                        textDecoration = if (link.isExternal) TextDecoration.Underline else null,
                    ),
                    start - textStart, end - textStart,
                )
            }
            for (highlight in highlights) {
                val start = maxOf(highlight.utf16Start, textStart)
                val end = minOf(highlight.utf16End, textEnd)
                if (start >= end) continue
                addStyle(
                    SpanStyle(
                        background = palette.marker(highlight.markerColor),
                        textDecoration = if (highlight.note.isNullOrBlank()) null else TextDecoration.Underline,
                    ),
                    start - textStart, end - textStart,
                )
            }
        }
    }
}
