package com.readrai.readr.ui.ask

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import com.readrai.readr.data.kitJson
import kotlinx.serialization.Serializable

/**
 * One block of a model's answer — the kit's `AnswerBlock`, as it crosses the
 * bridge.
 *
 * Models answer in Markdown whether or not you ask them to, and a raw `Text`
 * shows the punctuation instead of the formatting: asterisks around every
 * bold phrase, a `-` in front of every bullet. Block structure is what a
 * plain string loses, and recovering it is the kit's job — `AnswerMarkdown`
 * in `Sources/ReadrKit` — so an answer is cut into blocks by the same parser
 * on both platforms rather than by a second, smaller one written here.
 */
@Immutable
sealed interface AnswerBlock {
    /** Body text. Soft-wrapped source lines are already joined. */
    data class Paragraph(val text: String) : AnswerBlock

    data class Heading(val level: Int, val text: String) : AnswerBlock

    /** A `>` quotation. One entry per paragraph inside the quote. */
    data class Quote(val paragraphs: List<String>) : AnswerBlock

    /** A fenced code block, verbatim — no inline markup inside. */
    data class Code(val language: String?, val text: String) : AnswerBlock

    /** A list, ordered or not. Each item's marker is already rendered ("2."). */
    data class Items(val ordered: Boolean, val items: List<Item>) : AnswerBlock

    /** A thematic break. */
    data object Rule : AnswerBlock

    data class Item(val marker: String, val text: String)
}

/** Mirrors ReadrAndroid's `AnswerBlockWire`. */
@Serializable
private data class BlockWire(
    val kind: String,
    val text: String? = null,
    val level: Int? = null,
    val language: String? = null,
    val paragraphs: List<String>? = null,
    val ordered: Boolean? = null,
    val items: List<ItemWire>? = null,
)

@Serializable
private data class ItemWire(val marker: String, val text: String)

/**
 * The answer renderer's Kotlin half: the kit's blocks decoded, and `**bold**`
 * turned into a span.
 *
 * Inline markup stays this side on purpose — the kit leaves it in the block
 * text, because it is the platform's own job to draw. Everything structural
 * (headings, lists, quotes, code, rules) comes from the kit, which is
 * tolerant of PARTIAL input because it runs on every streamed token.
 */
object AnswerMarkdown {

    /**
     * Decodes `AndroidLibrary.answerBlocksJSON`. A payload that will not
     * decode renders as the text itself rather than as nothing at all.
     */
    fun blocks(json: String, fallback: String): List<AnswerBlock> {
        val wire = runCatching { kitJson.decodeFromString<List<BlockWire>>(json) }.getOrNull()
            ?: return listOf(AnswerBlock.Paragraph(fallback))
        return wire.mapNotNull { block ->
            when (block.kind) {
                "paragraph" -> block.text?.let { AnswerBlock.Paragraph(it) }
                "heading" -> block.text?.let { AnswerBlock.Heading(block.level ?: 1, it) }
                "quote" -> block.paragraphs?.let { AnswerBlock.Quote(it) }
                "code" -> block.text?.let { AnswerBlock.Code(block.language, it) }
                "list" -> AnswerBlock.Items(
                    ordered = block.ordered ?: false,
                    items = block.items.orEmpty().map { AnswerBlock.Item(it.marker, it.text) },
                )
                "rule" -> AnswerBlock.Rule
                else -> null
            }
        }
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
