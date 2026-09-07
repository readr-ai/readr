package com.readrai.readr.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.readrai.readr.ui.theme.LocalReadingPalette
import com.readrai.readr.ui.theme.Marginalia

/**
 * The "Aa" sheet: text size and theme, font, spacing, justification, and the
 * reading layout — the iOS Appearance popover's sections that apply on
 * Android. Changes preview live behind the sheet; picking a *layout* closes
 * it instead, as the popover does, since a layout is a one-shot choice the
 * reader wants to see rather than compare.
 *
 * `offersDoublePage` is the reader's own width test: a facing-page spread is
 * offered only on a wide window (the surface reports it — see `ReaderScreen`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppearanceSheet(
    appearance: ReaderAppearance,
    onChange: ((ReaderAppearance) -> ReaderAppearance) -> Unit,
    onDismiss: () -> Unit,
    offersDoublePage: Boolean = false,
) {
    val palette = LocalReadingPalette.current
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = palette.elevated) {
        // Five sections outgrow a landscape phone's height — the sheet scrolls
        // rather than cutting the last one off where nothing can reach it.
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Section("TEXT & THEME") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(
                        onClick = { onChange { it.copy(fontSize = it.fontSize - 1) } },
                        enabled = appearance.fontSize > ReaderAppearance.fontSizeRange.first,
                        modifier = Modifier.testTag("appearance.textSmaller").semantics { contentDescription = "Smaller text" },
                    ) { Text("A", fontFamily = FontFamily.Serif, fontSize = 15.sp, color = palette.ink) }
                    Text("${appearance.fontSize}", style = MaterialTheme.typography.bodyMedium, color = palette.muted, modifier = Modifier.testTag("appearance.fontSize"))
                    IconButton(
                        onClick = { onChange { it.copy(fontSize = it.fontSize + 1) } },
                        enabled = appearance.fontSize < ReaderAppearance.fontSizeRange.last,
                        modifier = Modifier.testTag("appearance.textLarger").semantics { contentDescription = "Larger text" },
                    ) { Text("A", fontFamily = FontFamily.Serif, fontSize = 22.sp, color = palette.ink) }
                    Spacer(Modifier.weight(1f))
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        ReadingTheme.entries.forEach { theme ->
                            val swatch = Marginalia.palette(theme)
                            val selected = theme == appearance.theme
                            Box(
                                Modifier
                                    .size(28.dp)
                                    .border(if (selected) 2.dp else 1.dp, if (selected) palette.ink else palette.line, CircleShape)
                                    .padding(4.dp)
                                    .background(swatch.page, CircleShape)
                                    .clickable { onChange { it.copy(theme = theme) } }
                                    .semantics { contentDescription = theme.displayName; this.selected = selected }
                                    .testTag("appearance.theme.${theme.key}"),
                            )
                        }
                    }
                }
            }
            Section("FONT") {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    ReaderFont.entries.forEachIndexed { index, font ->
                        SegmentedButton(
                            selected = font == appearance.font,
                            onClick = { onChange { it.copy(font = font) } },
                            shape = SegmentedButtonDefaults.itemShape(index, ReaderFont.entries.size),
                            modifier = Modifier.testTag("appearance.font.${font.key}"),
                        ) { Text(font.displayName, fontFamily = font.family) }
                    }
                }
            }
            Section("SPACING") {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    LineSpacing.entries.forEachIndexed { index, spacing ->
                        SegmentedButton(
                            selected = spacing == appearance.spacing,
                            onClick = { onChange { it.copy(spacing = spacing) } },
                            shape = SegmentedButtonDefaults.itemShape(index, LineSpacing.entries.size),
                            modifier = Modifier.testTag("appearance.spacing.${spacing.key}"),
                        ) { Text(spacing.displayName) }
                    }
                }
                Spacer(Modifier.height(6.dp))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Justify text", style = MaterialTheme.typography.bodyMedium, color = palette.ink)
                    Spacer(Modifier.weight(1f))
                    Switch(checked = appearance.justified, onCheckedChange = { on -> onChange { it.copy(justified = on) } }, modifier = Modifier.testTag("appearance.justify"))
                }
            }
            Section("LAYOUT") {
                // A narrow window is offered scroll and single page only, and a
                // stored `doublePage` shows as single page there — the reader
                // is told what they are getting, and the preference survives.
                val offered = PageLayout.entries.filter { it != PageLayout.DoublePage || offersDoublePage }
                val current = appearance.layout.on(offersDoublePage)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    offered.forEachIndexed { index, layout ->
                        SegmentedButton(
                            selected = layout == current,
                            onClick = { onChange { it.copy(layout = layout) }; onDismiss() },
                            shape = SegmentedButtonDefaults.itemShape(index, offered.size),
                            modifier = Modifier.testTag("appearance.layout.${layout.key}"),
                        ) { Text(layout.displayName, maxLines = 1) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    val palette = LocalReadingPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.labelSmall, color = palette.muted)
        content()
    }
}
