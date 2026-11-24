package com.readrai.readr

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.text.TextLayoutResult

/**
 * A point over the middle of a word on the drawn page, and the word it lands
 * in — taken from the page's own text layout, which semantics hands out,
 * rather than guessed as a fraction of the page box.
 *
 * Guessing does not work: which words are on the page depends on how the
 * chapter paginated at this font size on this screen, and a long-press aimed
 * at a fraction of the box can land in a margin, on a one-character mark three
 * pixels wide, or in the outer quarters that are the page-turn zones. A letter
 * with letters either side of it is a point both the press and the caret
 * resolve inside the same word; it is chosen from the middle of the page and
 * kept in the middle half of the line.
 *
 * Shared because both the reader's selection tests and Listen's want the same
 * point, and one of them also wants to know which word it aimed at.
 */
internal fun ComposeTestRule.wordOnThePage(): Pair<Offset, String> {
    val node = onNodeWithTag("reader.page").fetchSemanticsNode()
    val layouts = mutableListOf<TextLayoutResult>()
    node.config[SemanticsActions.GetTextLayoutResult].action?.invoke(layouts)
    val layout = layouts.firstOrNull() ?: error("the page has no text layout to aim at")
    val text = layout.layoutInput.text.text
    fun insideAWord(index: Int) = text[index].isLetter() &&
        index > 0 && text[index - 1].isLetter() &&
        index + 1 < text.length && text[index + 1].isLetter()
    val width = node.size.width
    val aimed = (text.indices.drop(text.length / 2) + text.indices).firstOrNull { index ->
        insideAWord(index) && layout.getBoundingBox(index).center.x in width * 0.35f..width * 0.65f
    } ?: error("no word in the middle of the page to aim at")
    var start = aimed
    while (start > 0 && text[start - 1].isLetter()) start -= 1
    var end = aimed
    while (end + 1 < text.length && text[end + 1].isLetter()) end += 1
    val box = layout.getBoundingBox(aimed)
    // Into the glyph rather than on its edge, so the caret the press rounds to
    // and the glyph the tap lands on are the same character.
    return Offset(box.left + box.width * 0.4f, box.center.y) to text.substring(start, end + 1)
}
