package com.readrai.readr.ui.ask

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle

/**
 * One block of a model's answer — the Android half of the kit's
 * `AnswerBlock`, cut to what this sheet draws.
 *
 * Models answer in Markdown whether or not you ask them to, and a raw `Text`
 * shows the punctuation instead of the formatting: asterisks around every
 * bold phrase, a `-` in front of every bullet. Block structure is what a
 * plain string loses, so it is recovered here and the sheet draws each block
 * in its own style.
 */
sealed interface AnswerBlock {
    /** Body text. Soft-wrapped source lines are already joined. */
    data class Paragraph(val text: String) : AnswerBlock

    /** A `-` list. One entry per item. */
    data class Bullets(val items: List<String>) : AnswerBlock

    /** A `>` quotation — the one thing the kit's prompt asks a model to quote with. */
    data class Quote(val paragraphs: List<String>) : AnswerBlock
}

/**
 * Splits a Markdown answer into the blocks the sheet draws, and turns
 * `**bold**` into a span.
 *
 * Deliberately small — paragraphs, `- ` bullets and `>` quotes, which is what
 * an answer to a question about a book actually contains (the kit's system
 * prompt asks for no headings, no code, and at most one blockquote). It runs
 * on every streamed token, so PARTIAL input is the normal case: a half-typed
 * `**` renders as the text so far rather than swallowing the rest of the
 * answer.
 */
object AnswerMarkdown {

    fun blocks(markdown: String): List<AnswerBlock> {
        val blocks = mutableListOf<AnswerBlock>()
        val paragraph = mutableListOf<String>()
        val bullets = mutableListOf<String>()
        val quote = mutableListOf<String>()

        fun flushParagraph() {
            if (paragraph.isNotEmpty()) {
                blocks += AnswerBlock.Paragraph(paragraph.joinToString(" "))
                paragraph.clear()
            }
        }

        fun flushBullets() {
            if (bullets.isNotEmpty()) {
                blocks += AnswerBlock.Bullets(bullets.toList())
                bullets.clear()
            }
        }

        fun flushQuote() {
            if (quote.isNotEmpty()) {
                blocks += AnswerBlock.Quote(quote.toList())
                quote.clear()
            }
        }

        fun flush() {
            flushParagraph(); flushBullets(); flushQuote()
        }

        for (raw in markdown.replace("\r\n", "\n").split('\n')) {
            val line = raw.trim()
            when {
                line.isEmpty() -> flush()

                line.startsWith(">") -> {
                    flushParagraph(); flushBullets()
                    val text = line.trimStart('>').trim()
                    if (text.isNotEmpty()) quote += text
                }

                bulletText(line) != null -> {
                    flushParagraph(); flushQuote()
                    bullets += bulletText(line)!!
                }

                // A heading is not something the prompt asks for, but a model
                // may still emit one; it reads as a line of body text rather
                // than as its own punctuation.
                line.startsWith("#") -> {
                    flush()
                    val text = line.trimStart('#').trim()
                    if (text.isNotEmpty()) blocks += AnswerBlock.Paragraph(text)
                }

                else -> {
                    flushBullets(); flushQuote()
                    paragraph += line
                }
            }
        }
        flush()
        return blocks
    }

    /** `-`, `*` or `+` followed by a space; null for anything else. */
    private fun bulletText(line: String): String? {
        val marker = line.firstOrNull() ?: return null
        if (marker !in "-*+") return null
        if (line.getOrNull(1) != ' ') return null
        return line.drop(2).trim().ifEmpty { null }
    }

    /**
     * `**bold**` as a span, everything else as written. An unclosed `**` is
     * the half-streamed case and stays literal until its partner arrives.
     */
    fun inline(text: String): AnnotatedString = buildAnnotatedString {
        var index = 0
        while (index < text.length) {
            val open = text.indexOf(MARK, index)
            if (open < 0) {
                append(text.substring(index))
                return@buildAnnotatedString
            }
            val close = text.indexOf(MARK, open + MARK.length)
            if (close < 0) {
                append(text.substring(index))
                return@buildAnnotatedString
            }
            append(text.substring(index, open))
            val bold = text.substring(open + MARK.length, close)
            if (bold.isEmpty()) {
                // `****` is not emphasis; keep it as the characters it is.
                append(MARK + MARK)
            } else {
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(bold) }
            }
            index = close + MARK.length
        }
    }

    private const val MARK = "**"
}
