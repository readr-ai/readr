package com.readrai.readr.ui.listen

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.touchTarget

/**
 * The narrator, chosen in the Appearance sheet rather than on the Listen card
 * — the same place the Apple app puts it (the Aa popover's Voice row), and for
 * the same reason: it is a decision a reader makes once, not a control they
 * reach for mid-sentence.
 *
 * Everything shown here comes from the facade: the order is the kit's
 * `VoiceSelector`, the split between the book's own language and "Other
 * voices" is the kit's rule over what the phone has installed, and the
 * sentence shown when the phone has no voice data at all is the facade's.
 * Kotlin ranks nothing and words nothing.
 */
@Composable
fun VoiceRow(narration: NarrationModel) {
    val palette = LocalReadingPalette.current
    var picking by remember { mutableStateOf(false) }
    val voices = narration.voices
    // The phone cannot say which voices it has until its synthesizer has
    // started, so the row asks for the list when it appears rather than
    // waiting for the first Listen.
    LaunchedEffect(Unit) { narration.prepareVoices() }

    if (voices.isEmpty) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = touchTarget)
                .testTag("appearance.voice")
                // Merged so the sentence is read as one line — there is no
                // control here, only the phone's answer.
                .semantics(mergeDescendants = true) { },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                voices.emptyText,
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
            )
        }
        return
    }

    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = touchTarget)
            .clickable { picking = true }
            .testTag("appearance.voice"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Voice", style = MaterialTheme.typography.bodyMedium, color = palette.ink)
        Spacer(Modifier.weight(1f))
        Text(
            voices.selectedName.orEmpty(),
            style = MaterialTheme.typography.bodyMedium,
            color = palette.muted,
            maxLines = 1,
        )
        Spacer(Modifier.width(8.dp))
        Text("⌄", fontSize = 13.sp, color = palette.muted)
    }

    if (picking) VoiceDialog(narration, voices) { picking = false }
}

@Composable
private fun VoiceDialog(
    narration: NarrationModel,
    voices: NarrationVoices,
    onDismiss: () -> Unit,
) {
    val palette = LocalReadingPalette.current
    // The book's own language is the list; everything else is behind one more
    // tap, exactly as the Apple picker's "Other voices…" is — a phone with
    // every language installed would otherwise open on a wall of rows.
    var showsOthers by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = palette.elevated,
        title = { Text("Voice", color = palette.ink) },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Done", color = palette.iris) }
        },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                voices.voices.forEach { voice ->
                    VoiceOption(voice, voices.checkedID) { narration.chooseVoice(voice.id); onDismiss() }
                }
                if (voices.otherVoices.isEmpty()) return@Column
                HorizontalDivider(Modifier.padding(vertical = 6.dp), color = palette.line)
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = touchTarget)
                        .clickable { showsOthers = !showsOthers }
                        .testTag("appearance.otherVoices"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Other voices",
                        style = MaterialTheme.typography.bodyMedium,
                        color = palette.ink,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(if (showsOthers) "⌃" else "⌄", fontSize = 13.sp, color = palette.muted)
                }
                if (!showsOthers) return@Column
                voices.otherVoices.forEach { voice ->
                    VoiceOption(voice, voices.checkedID) { narration.chooseVoice(voice.id); onDismiss() }
                }
            }
        },
    )
}

/**
 * One row. The check is what is reading; the "Recommended" mark is what the
 * kit would pick for this book on its own — which is only the same thing
 * until the reader chooses otherwise.
 */
@Composable
private fun VoiceOption(voice: NarrationVoice, selectedID: String?, onPick: () -> Unit) {
    val palette = LocalReadingPalette.current
    val chosen = voice.id == selectedID
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = touchTarget)
            .clickable(onClick = onPick)
            .testTag("voice.${voice.id}")
            .semantics { contentDescription = voice.name; selected = chosen },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(22.dp)) {
            if (chosen) Text("✓", fontSize = 13.sp, color = palette.iris)
        }
        Column(Modifier.weight(1f)) {
            Text(
                voice.name,
                style = MaterialTheme.typography.bodyMedium,
                color = palette.ink,
                maxLines = 1,
            )
            if (voice.isRecommended) {
                Text(
                    "Recommended",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.sp,
                    color = palette.faint,
                )
            }
        }
        Text(voice.language, fontSize = 11.sp, color = palette.faint)
    }
}
