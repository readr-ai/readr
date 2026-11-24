package com.readrai.readr.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.ui.theme.LocalReadingPalette

/**
 * The note being written and the highlight it belongs to — the Android half of
 * `NoteEditor.swift`'s contract. `createdForNote` marks a highlight this flow
 * made only so the note would have somewhere to live: cancelling takes it away
 * again, so a cancelled note never strands a mark the reader did not ask for.
 */
data class NoteDraft(
    val highlightId: String,
    val quotedText: String,
    val initialText: String,
    val createdForNote: Boolean,
)

/**
 * The note editor, Marginalia style: caps "NOTE", the quoted passage in italic
 * serif behind a muted rule, a paper field, then Cancel and an ink-filled Save.
 * The editor writes nothing itself — the host saves or cancels in the callbacks
 * and puts the sheet away by dropping the draft.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteEditor(draft: NoteDraft, onSave: (String) -> Unit, onCancel: () -> Unit) {
    val palette = LocalReadingPalette.current
    var text by rememberSaveable(draft.highlightId) { mutableStateOf(draft.initialText) }

    ModalBottomSheet(
        onDismissRequest = onCancel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = palette.elevated,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp)
                .testTag("note.editor"),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("NOTE", style = MaterialTheme.typography.labelSmall, color = palette.faint)

            if (draft.quotedText.isNotBlank()) {
                Row(Modifier.fillMaxWidth()) {
                    Box(Modifier.width(2.dp).heightIn(min = 18.dp).background(palette.muted))
                    Text(
                        "“${draft.quotedText}”",
                        fontFamily = FontFamily.Serif,
                        fontStyle = FontStyle.Italic,
                        fontSize = 13.sp,
                        lineHeight = 19.sp,
                        color = palette.muted,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
            }

            BasicTextField(
                value = text,
                onValueChange = { text = it },
                textStyle = TextStyle(fontFamily = FontFamily.SansSerif, fontSize = 14.sp, color = palette.ink),
                cursorBrush = SolidColor(palette.ink),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 88.dp, max = 160.dp)
                    .background(palette.page, RoundedCornerShape(8.dp))
                    .border(1.dp, palette.line, RoundedCornerShape(8.dp))
                    .padding(10.dp)
                    .testTag("note.field")
                    .semantics { contentDescription = "Note" },
            )

            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                TextButton(
                    onClick = onCancel,
                    modifier = Modifier.testTag("note.cancel").semantics { contentDescription = "Cancel" },
                ) { Text("Cancel", fontSize = 13.sp, color = palette.muted) }
                Box(
                    Modifier
                        .background(palette.ink, RoundedCornerShape(8.dp))
                        .testTag("note.save")
                        .semantics { contentDescription = "Save" }
                        .clickable { onSave(text) }
                        .padding(horizontal = 16.dp, vertical = 9.dp),
                ) {
                    Text("Save", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = palette.background)
                }
            }
        }
    }
}
