package com.readrai.readr.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.readrai.readr.data.ProviderKindCard
import com.readrai.readr.data.ProviderVendorCard
import com.readrai.readr.data.ValidationStatus
import com.readrai.readr.ui.theme.LocalReadingPalette

/**
 * AI provider settings — the Android side of `App/Settings/ProviderSettingsView`.
 *
 * A MODEL section led by the one line naming what Ask uses, then a card per
 * company: a status dot, the vendor's name and how it connects, what to do
 * while it is disconnected, and inside it each way in with its own key field,
 * status, model picker and Active badge. A PRIVACY section closes it.
 *
 * Every sentence on this screen is the kit's. The colours are the reading
 * palette's, so Settings matches the page the reader just came from.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProvidersScreen(model: ProvidersViewModel, onBack: () -> Unit) {
    val palette = LocalReadingPalette.current
    val settings by model.settings.collectAsState()
    val checking by model.checking.collectAsState()
    val refreshing by model.refreshingModels.collectAsState()
    val message by model.message.collectAsState()
    val snackbar = remember { SnackbarHostState() }

    LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it); model.clearMessage() } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings", style = MaterialTheme.typography.titleLarge) },
                navigationIcon = {
                    IconButton(onClick = onBack, modifier = Modifier.testTag("settings.back")) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = palette.background),
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
        containerColor = palette.background,
    ) { padding ->
        val current = settings
        if (current == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Scaffold
        }
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(padding)
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionLabel("MODEL")
            Text(
                current.askUsesLine,
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
                modifier = Modifier.testTag("settings.askUses"),
            )
            for (vendor in current.vendors) {
                VendorCard(vendor, model, checking, refreshing)
            }
            Spacer(Modifier.size(6.dp))
            SectionLabel("PRIVACY")
            Text(
                "Keys are kept in the Android Keystore on this phone, and never leave it except to the provider you chose.",
                style = MaterialTheme.typography.bodyMedium,
                color = palette.faint,
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        color = LocalReadingPalette.current.faint,
        modifier = Modifier.padding(top = 10.dp),
    )
}

@Composable
private fun VendorCard(
    vendor: ProviderVendorCard,
    model: ProvidersViewModel,
    checking: Set<String>,
    refreshing: Boolean,
) {
    val palette = LocalReadingPalette.current
    Column(
        Modifier
            .fillMaxWidth()
            .background(palette.elevated, RoundedCornerShape(12.dp))
            .border(1.dp, palette.line, RoundedCornerShape(12.dp))
            .padding(15.dp)
            .testTag("settings.card.${vendor.id}"),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(8.dp).background(dotColor(vendor, checking), CircleShape))
            Text(vendor.title, style = MaterialTheme.typography.titleMedium, color = palette.ink)
            Badge(vendor.badge, Modifier.testTag("settings.badge.${vendor.id}"))
        }
        vendor.hint?.let { hint ->
            Text(
                hint,
                style = MaterialTheme.typography.bodyMedium,
                color = palette.muted,
                modifier = Modifier.testTag("settings.hint.${vendor.id}"),
            )
        }
        for (kind in vendor.kinds) {
            KindRow(kind, vendor, model, checking, refreshing)
        }
    }
}

@Composable
private fun Badge(text: String, modifier: Modifier = Modifier) {
    val palette = LocalReadingPalette.current
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = palette.muted,
        modifier = modifier
            .background(palette.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun KindRow(
    kind: ProviderKindCard,
    vendor: ProviderVendorCard,
    model: ProvidersViewModel,
    checking: Set<String>,
    refreshing: Boolean,
) {
    val palette = LocalReadingPalette.current
    val busy = kind.kind in checking
    // The model this row is showing. On the card Ask already uses, a pick
    // applies at once — that is the reader changing the model Ask uses. On any
    // other card it stays here until "Make active" commits it, so browsing a
    // list cannot quietly redirect Ask. Keyed on the kit's own answer, so an
    // activation anywhere resets the row to what actually happened.
    var picked by remember(kind.kind, kind.activeModelID) { mutableStateOf(kind.activeModelID) }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // Only when the card offers a choice — a lone way in needs no label to
        // tell it apart from itself.
        if (vendor.kinds.size > 1) {
            Text(kind.displayName, style = MaterialTheme.typography.labelSmall, color = palette.faint)
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                statusText(kind, busy),
                style = MaterialTheme.typography.bodyMedium,
                color = statusColor(kind, busy),
                modifier = Modifier.weight(1f).testTag("settings.status.${kind.kind}"),
            )
            if (kind.isActive) {
                Badge("Active", Modifier.testTag("settings.activeBadge.${kind.kind}"))
            } else if (canBeMadeActive(kind)) {
                // The explicit "use this one" control: the status dot reads as
                // a radio button but is decorative, and the model picker alone
                // is undiscoverable.
                TextButton(
                    onClick = { model.makeActive(kind.kind, picked) },
                    modifier = Modifier.testTag("settings.makeActive.${kind.kind}"),
                ) { Text("Make active") }
            }
        }

        if (kind.isOnDevice) {
            // A manual re-check for when the phone has just finished fetching
            // the model — the mockup's "Check again".
            TextButton(
                onClick = { model.recheck(kind.kind) },
                enabled = !busy,
                modifier = Modifier.testTag("settings.recheck.${kind.kind}"),
            ) { Text("Check again") }
        } else if (kind.usesAPIKey) {
            APIKeyField(kind, model)
            if (kind.hasCredential) {
                TextButton(
                    onClick = { model.removeKey(kind.kind) },
                    modifier = Modifier.testTag("settings.removeKey.${kind.kind}"),
                ) { Text("Remove key", color = MaterialTheme.colorScheme.error) }
            }
        }

        // The on-device model is whatever the phone ships — one entry, nothing
        // to pick, and its id is not a name anyone chose.
        if (!kind.isOnDevice) {
            ModelPicker(kind, picked) { id ->
                picked = id
                if (kind.isActive) model.makeActive(kind.kind, id)
            }
            if (kind.kind == OPEN_ROUTER) {
                TextButton(
                    onClick = { model.refreshOpenRouterModels() },
                    enabled = !refreshing,
                    modifier = Modifier.testTag("settings.refreshModels.${kind.kind}"),
                ) { Text(if (refreshing) "Loading models…" else "Refresh models") }
            }
        }
    }
}

/**
 * The key field. Masked as it is typed — a pasted key is long enough that a
 * shoulder is a real threat — and emptied the moment it is saved, so the
 * screen never keeps a secret it no longer needs.
 */
@Composable
private fun APIKeyField(kind: ProviderKindCard, model: ProvidersViewModel) {
    var key by remember(kind.kind) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = key,
            onValueChange = { key = it },
            label = { Text(if (kind.hasCredential) "Replace API key" else "API key") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            // A key is not prose: no autocorrect to "fix" it, no suggestion
            // strip holding it, and the keyboard's own Done rather than a
            // newline it cannot use.
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Password,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Done,
            ),
            modifier = Modifier.fillMaxWidth().testTag("settings.apiKey.${kind.kind}"),
        )
        Button(
            onClick = { model.saveKey(kind.kind, key); key = "" },
            enabled = key.isNotBlank(),
            modifier = Modifier.testTag("settings.saveKey.${kind.kind}"),
        ) { Text("Save") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelPicker(kind: ProviderKindCard, selectedID: String, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val name = kind.models.firstOrNull { it.id == selectedID }?.name ?: selectedID
    ExposedDropdownMenuBox(
        expanded = open,
        onExpandedChange = { open = it },
        modifier = Modifier.testTag("settings.model.${kind.kind}"),
    ) {
        OutlinedTextField(
            value = name,
            onValueChange = {},
            readOnly = true,
            label = { Text("Model") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (choice in kind.models) {
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(choice.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                contextLabel(choice.contextBudget),
                                style = MaterialTheme.typography.labelSmall,
                                color = LocalReadingPalette.current.faint,
                            )
                        }
                    },
                    onClick = { open = false; onPick(choice.id) },
                    modifier = Modifier.widthIn(min = 220.dp).testTag("settings.modelRow.${choice.id}"),
                )
            }
        }
    }
}

/** "200K context" — the budget the router will actually spend, not the ceiling. */
private fun contextLabel(budget: Int): String =
    if (budget >= 1_000_000) "${budget / 1_000_000}M context" else "${(budget + 500) / 1_000}K context"

/**
 * The status line under a card's title. Both sentences are the kit's: the
 * settled one it wrote into the card, and the one it wrote for a check this
 * screen has started and the kit does not know about yet.
 */
private fun statusText(kind: ProviderKindCard, busy: Boolean): String =
    if (busy || kind.status.isValidating) kind.checkingLine else kind.statusLine

/**
 * Whether this card can be pointed at at all. A stored key can: even one the
 * provider just rejected is the reader's to replace, and choosing it is a
 * choice they are allowed to make. The phone's own model can only be offered
 * once a check says it is *ready* — there is no key to fix, and every other
 * state (never checked, still checking, unsupported) would put Ask on a
 * provider that can only refuse.
 */
private fun canBeMadeActive(kind: ProviderKindCard): Boolean =
    if (kind.isOnDevice) kind.status.isActive else kind.hasCredential

/** A rejected key is red; a transient failure is amber — it may still be good. */
@Composable
private fun statusColor(kind: ProviderKindCard, busy: Boolean): Color {
    val palette = LocalReadingPalette.current
    if (busy || kind.status.isValidating) return palette.muted
    return when (kind.status.state) {
        ValidationStatus.INVALID -> MaterialTheme.colorScheme.error
        ValidationStatus.UNAVAILABLE -> UNAVAILABLE_AMBER
        else -> palette.muted
    }
}

/** Green once any way into the vendor is usable; amber or red for the unhappy one. */
@Composable
private fun dotColor(vendor: ProviderVendorCard, checking: Set<String>): Color {
    val palette = LocalReadingPalette.current
    if (vendor.kinds.any { it.status.isActive }) return CONNECTED_GREEN
    if (vendor.kinds.any { it.kind in checking || it.status.isValidating }) return palette.faint
    val unhappy = vendor.kinds.firstOrNull { it.status.state == ValidationStatus.INVALID }
        ?: vendor.kinds.firstOrNull { it.status.state == ValidationStatus.UNAVAILABLE }
    return when (unhappy?.status?.state) {
        ValidationStatus.INVALID -> MaterialTheme.colorScheme.error
        ValidationStatus.UNAVAILABLE -> UNAVAILABLE_AMBER
        else -> if (vendor.kinds.any { it.hasCredential }) CONNECTED_GREEN else palette.faint
    }
}

private const val OPEN_ROUTER = "openRouter"
private val CONNECTED_GREEN = Color(0xFF4C9A5B)
private val UNAVAILABLE_AMBER = Color(0xFFC07A22)
