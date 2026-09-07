package com.readrai.readr.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.data.ProviderSettings
import com.readrai.readr.data.ProvidersRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Backs the AI provider settings screen: connect with an API key, see what
 * each provider says about itself, and choose the model Ask uses.
 *
 * Every reader-facing sentence comes from the kit through
 * [ProvidersRepository], and so does every decision about who Ask points at —
 * saving a key hands off to the facade's `connect`, which applies the kit's
 * activation rule. What this class owns is the *in-flight* state the kit has
 * no opinion about: which checks are running.
 */
class ProvidersViewModel(private val open: suspend () -> ProvidersRepository) : ViewModel() {
    private val _settings = MutableStateFlow<ProviderSettings?>(null)
    val settings: StateFlow<ProviderSettings?> = _settings.asStateFlow()

    /** Kinds with a check in flight, so a card can say so before it settles. */
    private val _checking = MutableStateFlow<Set<String>>(emptySet())
    val checking: StateFlow<Set<String>> = _checking.asStateFlow()

    private val _refreshingModels = MutableStateFlow(false)
    val refreshingModels: StateFlow<Boolean> = _refreshingModels.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    private var repository: ProvidersRepository? = null

    init {
        viewModelScope.launch {
            try {
                val repo = open() // opens the kit off the main thread on first use
                repository = repo
                _settings.value = repo.settings()
                sweep()
            } catch (e: Exception) {
                _message.value = failure(e, "Couldn't open your AI settings.")
            }
        }
    }

    /**
     * Verify what there is to verify when the screen opens: a stored key is
     * not trusted until a live call accepts it, and the phone's own model is
     * a probe rather than a fact. Stale-only, so walking in and out of
     * Settings does not post a paid completion each time; the kit decides
     * what counts as stale, and a check that failed is never fresh.
     */
    private suspend fun sweep() {
        val kinds = _settings.value?.vendors.orEmpty()
            .flatMap { it.kinds }
            .filter { it.isOnDevice || it.hasCredential }
            .map { it.kind }
        for (kind in kinds) check(kind) { repo -> repo.validateIfStale(kind, RECHECK_AFTER_SECONDS) }
    }

    /** A live check for one kind, with the card saying so while it runs. */
    private suspend fun check(kind: String, run: suspend (ProvidersRepository) -> Unit) {
        val repo = repository ?: return
        _checking.value = _checking.value + kind
        try {
            run(repo)
        } catch (e: Exception) {
            _message.value = failure(e, "Couldn't check that provider.")
        } finally {
            _checking.value = _checking.value - kind
            reload()
        }
    }

    /** "Check again": never skipped, because it is the reader disputing the last answer. */
    fun recheck(kind: String) {
        viewModelScope.launch { check(kind) { repo -> repo.validate(kind) } }
    }

    /**
     * Store a key, then let the kit decide what it means: `connect` proves the
     * credential and applies the activation rule the Apple app uses — an
     * unproven key may take a slot nothing usable holds, an accepted one may
     * take it from a working provider, a rejected one never does. Nothing is
     * re-derived here; the reloaded settings say where it landed.
     */
    fun saveKey(kind: String, apiKey: String) {
        val repo = repository ?: return
        viewModelScope.launch {
            try {
                repo.saveAPIKey(kind, apiKey)
            } catch (e: Exception) {
                // The kit's sentence already says what went wrong and what to
                // do; a prefix here would only repeat it.
                _message.value = failure(e, "Couldn't save that key.")
                return@launch
            }
            reload()
            check(kind) { it.connect(kind) }
        }
    }

    /** Take the key away — and the selection with it, if it named this card. */
    fun removeKey(kind: String) {
        val repo = repository ?: return
        viewModelScope.launch {
            try {
                repo.disconnect(kind)
            } catch (e: Exception) {
                _message.value = failure(e, "Couldn't remove that key.")
            }
            reload()
        }
    }

    /**
     * Point Ask at this card and this model. Both doors lead here: "Make
     * active" on a card that is not the active one (committing whatever its
     * picker is showing), and the picker itself on the card that already is.
     */
    fun makeActive(kind: String, modelID: String) {
        viewModelScope.launch { activate(kind, modelID) }
    }

    /** OpenRouter's catalogue is live and hundreds long; bring it in on demand. */
    fun refreshOpenRouterModels() {
        val repo = repository ?: return
        if (_refreshingModels.value) return
        viewModelScope.launch {
            _refreshingModels.value = true
            try {
                repo.refreshOpenRouterModels()
                reload()
            } catch (e: Exception) {
                _message.value = failure(e, "Couldn't load OpenRouter's model list.")
            } finally {
                _refreshingModels.value = false
            }
        }
    }

    fun clearMessage() { _message.value = null }

    private suspend fun activate(kind: String, modelID: String) {
        val repo = repository ?: return
        try {
            repo.setActive(kind, modelID)
        } catch (e: Exception) {
            _message.value = failure(e, "Couldn't switch to that model.")
        }
        reload()
        // The on-device model's readiness is a probe, and it is the selection
        // that decides whether the card wears the Active badge — so ask again.
        if (card(kind)?.isOnDevice == true) check(kind) { it.validate(kind) }
    }

    private suspend fun reload() {
        val repo = repository ?: return
        try {
            _settings.value = repo.settings()
        } catch (e: Exception) {
            _message.value = failure(e, "Couldn't read your AI settings.")
        }
    }

    private fun card(kind: String) =
        _settings.value?.vendors.orEmpty().flatMap { it.kinds }.firstOrNull { it.kind == kind }

    /** Kit errors arrive carrying ReadrKit's own reader-facing sentence. */
    private fun failure(e: Exception, fallback: String): String =
        e.message?.takeIf { it.isNotBlank() } ?: fallback

    private companion object {
        /** Five minutes: long enough that a trip to Ask and back is free. */
        const val RECHECK_AFTER_SECONDS = 300L
    }
}
