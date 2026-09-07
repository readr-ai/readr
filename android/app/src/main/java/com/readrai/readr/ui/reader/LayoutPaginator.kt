package com.readrai.readr.ui.reader

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints

/**
 * One rendered page. Offsets are UTF-16 into the chapter text. `rangeStart`
 * is where the previous page's range ended, so ranges tile the chapter;
 * `textStart` is the first drawn character — whitespace folded at the page
 * boundary lies between the two. Map page-local offsets to chapter offsets
 * with `textStart`, never `rangeStart` (the same rule as the kit's
 * `Page.textStartOffset`).
 */
data class Page(val rangeStart: Int, val rangeEnd: Int, val textStart: Int, val textEnd: Int, val wordCount: Int) {
    operator fun contains(offset: Int): Boolean = offset >= rangeStart && offset < rangeEnd
}

/** A chapter's pages plus the per-page suffix sums the page label reads. */
class Pagination(val pages: List<Page>) {
    /** Words on this page and every page after it. */
    val wordsRemaining: IntArray = IntArray(pages.size).also { sums ->
        var total = 0
        for (i in pages.indices.reversed()) { total += pages[i].wordCount; sums[i] = total }
    }

    private val rangeStarts = IntArray(pages.size) { pages[it].rangeStart }

    /** Index of the page containing `offset`; clamps out-of-range offsets to the first or last page. */
    fun pageIndex(containing: Int): Int {
        if (pages.isEmpty()) return 0
        val i = rangeStarts.binarySearch(containing)
        return (if (i >= 0) i else (-i - 1) - 1).coerceIn(0, pages.size - 1)
    }
}

/**
 * Layout-accurate pagination: the chapter is laid out once at the page width
 * (in paragraph-aligned chunks, so a 1.2 MB single-chapter text stays cheap
 * and bounded), and pages are consecutive runs of whole lines that fit the
 * page height. Rendering a page draws the same styled text from a line
 * boundary at the same width, so what was measured is what is drawn.
 */
object LayoutPaginator {
    /** Characters per measurement chunk; the cut snaps back to a paragraph boundary. */
    const val CHUNK = 24_000

    private class Line(val start: Int, val end: Int, val height: Float)

    /**
     * The chapter cut into pieces at paragraph boundaries — the same rule
     * [paginate] measures by, and for the same reason: a piece of bounded
     * length that no line is ever laid out across. The scroll layout draws
     * these as the rows of its list, so a long chapter is composed a screenful
     * at a time instead of as one enormous `Text`; nothing here measures
     * anything, so a scroll costs no layout pass at all.
     *
     * Each piece is a [Page] whose range and text are the same span — there is
     * no page boundary to fold whitespace at — so everything written for a cut
     * page (offsets through `textStart`, highlights, links, the capsule) works
     * on a chunk unchanged.
     */
    fun chunks(chapter: StyledChapter): List<Page> {
        val raw = chapter.text.text
        val length = raw.length
        if (length == 0) return emptyList()
        val pieces = ArrayList<Page>(length / CHUNK + 1)
        var start = 0
        while (start < length) {
            var end = minOf(start + CHUNK, length)
            if (end < length) {
                val boundary = chapter.paragraphStart(atOrBefore = end)
                if (boundary >= start + CHUNK / 2) end = boundary
            }
            pieces.add(Page(start, end, start, end, wordCount(raw, start, end)))
            start = end
        }
        return pieces
    }

    fun paginate(chapter: StyledChapter, style: TextStyle, widthPx: Int, heightPx: Int, measurer: TextMeasurer): List<Page> {
        val text = chapter.text
        val length = text.length
        if (length == 0 || widthPx <= 8 || heightPx <= 0) return emptyList()
        val raw = text.text

        val lines = ArrayList<Line>(length / 40 + 8)
        var chunkStart = 0
        while (chunkStart < length) {
            var chunkEnd = minOf(chunkStart + CHUNK, length)
            if (chunkEnd < length) {
                // Cut at a paragraph start so no line is measured across a seam
                // (the styled string has no newlines; the starts are the source).
                val boundary = chapter.paragraphStart(atOrBefore = chunkEnd)
                if (boundary >= chunkStart + CHUNK / 2) chunkEnd = boundary
            }
            val result = measurer.measure(
                text = text.subSequence(chunkStart, chunkEnd),
                style = style,
                overflow = TextOverflow.Clip,
                softWrap = true,
                // The chapter's inline images, rebased to this chunk. A page is
                // drawn from the same styled text with the same pictures in it,
                // so a line holding one is as tall when it is shown as it was
                // when it was measured — and, being a whole line, is never cut
                // away from the picture it holds.
                placeholders = chapter.placeholdersIn(chunkStart, chunkEnd),
                constraints = Constraints(maxWidth = widthPx),
            )
            for (i in 0 until result.lineCount) {
                val start = chunkStart + result.getLineStart(i)
                val end = chunkStart + result.getLineEnd(i, visibleEnd = false)
                if (start == end && end == chunkEnd) continue // a phantom empty last line
                lines.add(Line(start, end, result.getLineBottom(i) - result.getLineTop(i)))
            }
            chunkStart = chunkEnd
        }
        if (lines.isEmpty()) return emptyList()

        fun isBlank(line: Line): Boolean {
            for (i in line.start until line.end) if (!raw[i].isWhitespace()) return false
            return true
        }

        val pages = ArrayList<Page>()
        var rangeStart = 0
        var i = 0
        while (i < lines.size) {
            var first = i
            while (first < lines.size && isBlank(lines[first])) first++
            if (first == lines.size) {
                // Only whitespace remains: fold it into the last page's range.
                if (pages.isNotEmpty()) {
                    val last = pages.removeAt(pages.size - 1)
                    pages.add(last.copy(rangeEnd = length))
                } else {
                    pages.add(Page(0, length, 0, 0, 0))
                }
                break
            }
            var height = 0f
            var last = first
            while (last < lines.size && (last == first || height + lines[last].height <= heightPx)) {
                height += lines[last].height
                last++
            }
            val end = lines[last - 1].end
            val textStart = lines[first].start
            var textEnd = end
            while (textEnd > textStart && raw[textEnd - 1].isWhitespace()) textEnd--
            pages.add(Page(rangeStart, end, textStart, textEnd, wordCount(raw, textStart, textEnd)))
            rangeStart = end
            i = last
        }
        return pages
    }

    /** Whitespace-separated words in `text[start, end)` — the kit's `ReadingTimeEstimator.wordCount` rule. */
    fun wordCount(text: String, start: Int, end: Int): Int {
        var count = 0
        var inWord = false
        for (i in start until end) {
            if (text[i].isWhitespace()) inWord = false
            else if (!inWord) { inWord = true; count++ }
        }
        return count
    }

    /** Average adult silent-reading speed, as in the kit. */
    const val WORDS_PER_MINUTE = 240.0

    /** Whole minutes, rounded up, minimum 1 for any words. */
    fun minutes(words: Int): Int = if (words <= 0) 0 else maxOf(1, Math.ceil(words / WORDS_PER_MINUTE).toInt())
}
