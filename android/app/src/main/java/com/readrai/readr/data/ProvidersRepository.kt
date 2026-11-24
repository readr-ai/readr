package com.readrai.readr.data

import com.readrai.readr.kit.Kit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.future.await
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable

/** Mirrors ReadrAndroid's `ProviderSettingsPayload`: one settings screen. */
@Serializable
data class ProviderSettings(
    /** "Ask uses Claude Opus 5 · Claude (Anthropic)", or why it uses nothing. */
    val askUsesLine: String,
    /** What Ask will use: the reader's choice, else the phone's own model. */
    val selection: ProviderSelection? = null,
    /** What the reader actually chose — null while nothing has been picked. */
    val explicitSelection: ProviderSelection? = null,
    val vendors: List<ProviderVendorCard> = emptyList(),
)

/** Mirrors the kit's `ProviderSelection`: what Ask puts a question to. */
@Serializable
data class ProviderSelection(val kind: String, val modelID: String)

/** Mirrors ReadrAndroid's `ProviderVendorCard`: one company's card. */
@Serializable
data class ProviderVendorCard(
    val id: String,
    val title: String,
    val badge: String,
    /** What to do here while nothing is connected; null once something is. */
    val hint: String? = null,
    val kinds: List<ProviderKindCard> = emptyList(),
)

/** Mirrors ReadrAndroid's `ProviderKindCard`: one way into a vendor. */
@Serializable
data class ProviderKindCard(
    val kind: String,
    val displayName: String,
    val usesAPIKey: Boolean,
    val isOnDevice: Boolean,
    val hasCredential: Boolean,
    val isActive: Boolean,
    val status: ValidationStatus,
    /** The line under the card's title, written by the kit. */
    val statusLine: String = "",
    /** What that line reads while a check started here is still running. */
    val checkingLine: String = "",
    val models: List<ModelChoice> = emptyList(),
    val activeModelID: String,
)

/** Mirrors ReadrAndroid's `ProviderModelRow`. */
@Serializable
data class ModelChoice(val id: String, val name: String, val contextBudget: Int)

/**
 * Mirrors ReadrAndroid's `ProviderStatusSummary`. `state` is one of
 * `validating`, `active`, `invalid`, `unavailable`, `unknown`; `reason` is
 * the kit's own sentence, and the only text this side ever shows for a
 * failure.
 */
@Serializable
data class ValidationStatus(val state: String = UNKNOWN, val reason: String? = null) {
    val isActive: Boolean get() = state == ACTIVE
    val isValidating: Boolean get() = state == VALIDATING

    companion object {
        const val VALIDATING = "validating"
        const val ACTIVE = "active"
        const val INVALID = "invalid"
        const val UNAVAILABLE = "unavailable"
        const val UNKNOWN = "unknown"
    }
}

/**
 * AI provider settings, as the kit holds them: which models this phone can
 * reach, which one Ask uses, and the keys that unlock them.
 *
 * Every sentence on the screen comes from here — the kit writes the copy once
 * and both platforms show the same words. Keys go straight into the Android
 * Keystore through the facade's credential store; nothing in this class ever
 * holds one.
 */
class ProvidersRepository(private val kit: Kit) {

    suspend fun settings(): ProviderSettings = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.providers.providersJSON())
    }

    /** Stores a key and forgets the last check — the new key is unproven. */
    suspend fun saveAPIKey(kind: String, apiKey: String) = withContext(Dispatchers.IO) {
        kit.providers.saveAPIKey(kind, apiKey)
    }

    /**
     * Prove a stored key and let it take the active slot if the kit's rule
     * allows. The whole activation policy lives there — an unproven key may
     * take a slot nothing usable holds, an accepted one may take it from a
     * working provider, a rejected one never does — so nothing on this side
     * decides who Ask points at.
     */
    suspend fun connect(kind: String): ValidationStatus = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.providers.connect(kind).await())
    }

    /**
     * Check a kind again unless a *successful* check is younger than
     * [maxAgeSeconds]. The screen's on-open sweep: a credential check posts a
     * one-token completion, and repeating it every visit would spend the
     * reader's money to learn nothing.
     */
    suspend fun validateIfStale(kind: String, maxAgeSeconds: Long): ValidationStatus =
        withContext(Dispatchers.IO) {
            kitJson.decodeFromString(kit.providers.validateIfStale(kind, maxAgeSeconds).await())
        }

    /**
     * Take a key away — and, when it was the model Ask had been pointed at,
     * the selection with it.
     */
    suspend fun disconnect(kind: String) = withContext(Dispatchers.IO) {
        kit.providers.disconnect(kind)
    }

    /**
     * A live check: a one-token authenticated call for a cloud key, the
     * phone's own probe for the on-device model. Slow by nature — it is a
     * network round trip — so callers show the `validating` state first.
     */
    suspend fun validate(kind: String): ValidationStatus = withContext(Dispatchers.IO) {
        kitJson.decodeFromString(kit.providers.validate(kind).await())
    }

    suspend fun setActive(kind: String, modelID: String) = withContext(Dispatchers.IO) {
        kit.providers.setActive(kind, modelID)
    }

    /**
     * OpenRouter's catalogue: the disk copy, the network, or the curated
     * slice. The rows come back on the next [settings] read — there is one
     * place the screen gets its model list from, and this is not it.
     */
    suspend fun refreshOpenRouterModels() = withContext(Dispatchers.IO) {
        kit.providers.refreshOpenRouterModels().await()
    }

    /**
     * The kit's sentence for an empty state: the ways this build can be
     * connected on THIS phone — an API key, and the phone's own model where
     * it is one this phone can actually run — joined into one line ending in
     * [toDo]. It names no door that is not there, so what it says differs
     * from phone to phone.
     */
    suspend fun setupGuidance(toDo: String): String = withContext(Dispatchers.IO) {
        kit.providers.setupGuidance(toDo)
    }

    /** Whether Ask has a model to put a question to at all. */
    suspend fun hasAnyProvider(): Boolean = withContext(Dispatchers.IO) {
        kit.providers.hasAnyProvider()
    }
}
