package com.readrai.readr.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.readrai.readr.data.ProviderKindCard
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
 * [ProvidersRepository] — nothing here writes copy. What this class owns is
 * the *in-flight* state the kit has no opinion about: which checks are
 * running, and which model a card is offering before "Make active" commits it.
 */
class ProvidersViewModel(private val open: suspend () -> ProvidersRepository) : ViewModel() {
    private val _settings = MutableStateFlow<ProviderSettings?>(null)
    val settings: StateFlow<ProviderSettings?> = _settings.asStateFlow()

    /** Kinds with a check in flight, so a card can say so before it settles. */
    private val _checking = MutableStateFlow<Set<String>>(emptySet())
    val checking: StateFlow<Set<String>> = _checking.asStateFlow()

    /**
     * The model a card is showing but has not activated, per kind. A picker
     * on the *active* card applies at once (that is the reader changing the
     * model Ask uses); on any other card it waits for "Make active", so
     * browsing a list cannot quietly redirect Ask.
     */
    private val _chosenModels = MutableStateFlow<Map<String, String>>(emptyMap())
    val chosenModels: StateFlow<Map<String, String>> = _chosenModels.asStateFlow()

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
                checkEverythingWorthChecking()
            } catch (e: Exception) {
                _message.value = failure(e, "Couldn't open your AI settings.")
            }
        }
    }

    /**
     * Verify what there is to verify when the screen opens: a stored key is
     * not trusted until a live call accepts it, and the phone's own model is
     * a probe rather than a fact. Keys off *stored* credentials, so a card
     * whose last check failed is asked again rather than staying stuck on it.
     */
    private suspend fun checkEverythingWorthChecking() {
        val kinds = _settings.value?.vendors.orEmpty()
            .flatMap { it.kinds }
            .filter { it.isOnDevice || it.hasCredential }
            .map { it.kind }
        for (kind in kinds) check(kind)
    }

    /** A live check for one kind, with the card saying so while it runs. */
    private suspend fun check(kind: String) {
        val repo = repository ?: return
        _checking.value = _checking.value + kind
        try {
            repo.validate(kind)
        } catch (e: Exception) {
            _message.value = failure(e, "Couldn't check that provider.")
        } finally {
            _checking.value = _checking.value - kind
            reload()
        }
    }

    /** "Check again" on the on-device card, and the same path after a save. */
    fun recheck(kind: String) {
        viewModelScope.launch { check(kind) }
    }

    /**
     * Store a key, then prove it. A provider that checks out takes the active
     * slot when nothing usable holds it — the reader's next step is asking
     * the book, not hunting for a second control.
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
            check(kind)
            val card = card(kind)
            if (card != null && card.status.isActive && _settings.value?.selection == null) {
                activate(kind, modelFor(card))
            }
        }
    }

    fun removeKey(kind: String) {
        val repo = repository ?: return
        viewModelScope.launch {
            try {
                repo.deleteCredential(kind)
            } catch (e: Exception) {
                _message.value = failure(e, "Couldn't remove that key.")
            }
            reload()
        }
    }

    /** Point Ask at this card's model. */
    fun makeActive(kind: String) {
        val card = card(kind) ?: return
        viewModelScope.launch { activate(kind, modelFor(card)) }
    }

    /**
     * The reader picked a model. On the card Ask already uses this applies
     * now; anywhere else it is only what "Make active" will commit.
     */
    fun chooseModel(kind: String, modelID: String) {
        _chosenModels.value = _chosenModels.value + (kind to modelID)
        if (card(kind)?.isActive == true) {
            viewModelScope.launch { activate(kind, modelID) }
        }
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
        if (card(kind)?.isOnDevice == true) check(kind)
    }

    private suspend fun reload() {
        val repo = repository ?: return
        try {
            _settings.value = repo.settings()
        } catch (e: Exception) {
            _message.value = failure(e, "Couldn't read your AI settings.")
        }
    }

    private fun card(kind: String): ProviderKindCard? =
        _settings.value?.vendors.orEmpty().flatMap { it.kinds }.firstOrNull { it.kind == kind }

    /** What this card would activate: the reader's pick, else the kit's. */
    private fun modelFor(card: ProviderKindCard): String =
        _chosenModels.value[card.kind] ?: card.activeModelID

    /** Kit errors arrive carrying ReadrKit's own reader-facing sentence. */
    private fun failure(e: Exception, fallback: String): String = e.message?.takeIf { it.isNotBlank() } ?: fallback
}
