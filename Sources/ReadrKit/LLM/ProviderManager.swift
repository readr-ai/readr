import Foundation

/// A persisted (by the UI, elsewhere) choice of provider + model.
public struct ProviderSelection: Sendable, Equatable, Codable {
    public var kind: ProviderInfo.Kind
    public var modelID: String

    public init(kind: ProviderInfo.Kind, modelID: String) {
        self.kind = kind
        self.modelID = modelID
    }
}

/// Selects the active provider, resolves it against the `ProviderCatalog`, and
/// builds a concrete `LLMProvider` through an injected factory closure.
///
/// The factory indirection keeps this manager free of any dependency on the
/// concrete provider structs (`AnthropicProvider`, `OpenAIProvider`,
/// `LocalLLMProvider`), which are owned and wired up elsewhere.
///
/// Implemented as a `final class` guarded by an `NSLock` (rather than an actor)
/// because the UI calls into it synchronously on the main thread.
public final class ProviderManager: @unchecked Sendable {

    /// Builds a provider for a resolved `ProviderInfo`, given any stored
    /// credentials (nil for local providers, which need none).
    public typealias ProviderFactory =
        @Sendable (ProviderInfo, Credentials?) throws -> LLMProvider

    public enum ProviderError: Error, Equatable, LocalizedError {
        /// The selected kind requires credentials and none are stored.
        case notConfigured(ProviderInfo.Kind)
        /// A local selection produced a non-local provider — a wiring bug.
        case localMismatch

        // Rendered verbatim in error alerts, so both cases read as a sentence
        // that names the fix.
        public var errorDescription: String? {
            switch self {
            case .notConfigured(let kind):
                switch kind {
                case .anthropic:
                    return "Claude (Anthropic) isn't connected. Add an API key in Settings → AI Providers."
                case .openAI:
                    return "ChatGPT (OpenAI) isn't connected. Add an API key in Settings → AI Providers."
                case .local:
                    return "The local model isn't available. Make sure Ollama is running on this device."
                }
            case .localMismatch:
                return "The local model is misconfigured. Re-select a model in Settings → AI Providers."
            }
        }
    }

    /// Lifecycle of a provider kind's readiness.
    ///
    /// For **remote** kinds a stored API key is not trusted until a lightweight
    /// test call succeeds, so it moves `validating → active` (or `→ invalid`
    /// when the provider *rejects* the key, or `→ unavailable` when the check
    /// couldn't complete for a transient reason); before any check the state is
    /// simply `nil` (never checked). For **local** the state is derived from an
    /// Ollama `probe()` (`active` when ready, `unavailable` when the server is
    /// down or the model is missing).
    ///
    /// Only `invalid` (a proven-bad credential) blocks `activeProvider()`;
    /// `unavailable` is a soft, transient failure that leaves the provider
    /// optimistically usable so Ask/Article recover once the condition clears.
    public enum ValidationState: Sendable, Equatable {
        /// A validation request is in flight.
        case validating
        /// Verified usable — the key was accepted / the local model is ready.
        case active
        /// The provider rejected the credential (HTTP 401/403) or none is
        /// stored. Won't work without the user fixing the key, so this blocks
        /// `activeProvider()`. `reason` is a reader-facing sentence.
        case invalid(reason: String?)
        /// Readiness couldn't be confirmed right now for a *transient* reason:
        /// offline/timeout, rate-limit (429), a provider outage (5xx), or a
        /// local Ollama server that's momentarily down / missing the model.
        /// Surfaced in Settings, but left optimistic — `activeProvider()` still
        /// resolves so Ask works again once the condition clears. `reason` is a
        /// reader-facing sentence.
        case unavailable(reason: String?)
    }

    private let lock = NSLock()
    private let store: CredentialStore
    private let factory: ProviderFactory
    private let defaults: UserDefaults?
    private var _selection: ProviderSelection?
    /// Latest validation/readiness state per kind (nil == never checked).
    private var _validation: [ProviderInfo.Kind: ValidationState] = [:]
    /// Per-kind generation counter. Bumped whenever the credential/selection
    /// changes out from under an in-flight `validate(_:)` (save, sign-in,
    /// disconnect, model change). A validation captures the counter at entry
    /// and only commits its result if the counter still matches, so a stale
    /// request can't resurrect a replaced/deleted credential's state.
    private var _validationGeneration: [ProviderInfo.Kind: Int] = [:]

    /// UserDefaults key under which the active selection is persisted.
    static let selectionDefaultsKey = "readr.activeProviderSelection"

    /// The active selection, or nil if nothing has been chosen yet.
    public var selection: ProviderSelection? {
        lock.lock(); defer { lock.unlock() }
        return _selection
    }

    /// - Parameters:
    ///   - selection: an explicit starting selection; takes precedence over
    ///     anything persisted in `defaults`.
    ///   - defaults: when non-nil, the active selection is restored from and
    ///     persisted to this store, so it survives relaunch.
    public init(
        store: CredentialStore,
        factory: @escaping ProviderFactory,
        selection: ProviderSelection? = nil,
        persistingIn defaults: UserDefaults? = nil
    ) {
        self.store = store
        self.factory = factory
        self.defaults = defaults
        self._selection = selection ?? Self.loadSelection(from: defaults)
    }

    // MARK: - Selection

    /// Set the active provider. When `modelID` is omitted, the catalog default
    /// for `kind` is used.
    public func setActive(kind: ProviderInfo.Kind, modelID: String? = nil) {
        let resolvedModelID = modelID ?? ProviderCatalog.defaultModel(for: kind).modelID
        let selection = ProviderSelection(kind: kind, modelID: resolvedModelID)
        lock.lock(); defer { lock.unlock() }
        // A model change (or reselection) invalidates any in-flight check for
        // this kind — the result would describe the old model. Bump the
        // generation so that check is discarded, AND clear the cached state:
        // otherwise, if a `.validating` check was in flight, discarding it would
        // leave `.validating` stuck forever (nothing re-reads or replaces it),
        // freezing the Settings card on "Validating…" and dropping the kind out
        // of `isConfigured`. Reverting to nil keeps it optimistically usable.
        _validationGeneration[kind, default: 0] += 1
        _validation[kind] = nil
        _selection = selection
        Self.save(selection, to: defaults)
    }

    /// Called after a new credential for `kind` has been stored: decides
    /// whether the active selection moves to it now, or only after
    /// validation clears the key (`validateAndActivate(_:)`).
    ///
    /// Immediate takeover is allowed only when nothing usable holds the
    /// slot — no selection yet, the selected kind has lost its credential,
    /// or `kind` is already selected (a no-op that keeps the model choice).
    /// Otherwise the caller must follow up with `validateAndActivate(_:)`,
    /// so an unproven key can't displace a working provider and then strand
    /// the user on a rejected credential (issue #44).
    ///
    /// Returns `true` when `kind` is (now) the active selection.
    @discardableResult
    public func requestActivation(of kind: ProviderInfo.Kind) -> Bool {
        if let current = selection {
            if current.kind == kind { return true }
            if isConfigured(current.kind) { return false }
        }
        setActive(kind: kind)
        return true
    }

    /// Validate `kind` and, unless the credential was rejected, make it the
    /// active selection. Returns the settled validation state.
    ///
    /// `.active` and `.unavailable` both activate — a transient network
    /// failure must not condemn a key, matching `activeProvider()`'s
    /// optimism — while `.invalid` leaves the selection untouched so a bad
    /// key never displaces a working provider (issue #44). A `nil` settled
    /// state means the credential changed mid-flight (generation bump); the
    /// newer save's own flow owns activation, so this one stands down.
    ///
    /// Activation here bypasses `setActive` deliberately: `setActive` clears
    /// the kind's validation state (correct for a user-driven model change),
    /// but doing so now would discard the very result that authorized the
    /// takeover. An existing model choice for `kind` is kept.
    ///
    /// If the selection changed while validation was in flight — the user
    /// explicitly picked a provider/model in the meantime — the deferred
    /// takeover stands down: an async completion must not override a more
    /// recent explicit choice.
    @discardableResult
    public func validateAndActivate(_ kind: ProviderInfo.Kind) async -> ValidationState? {
        let selectionAtRequest = selection
        await validate(kind)
        guard let settled = validationState(kind) else { return nil }
        if case .invalid = settled { return settled }

        lock.lock()
        defer { lock.unlock() }
        guard _selection == selectionAtRequest else { return settled }
        if _selection?.kind != kind {
            let modelID = ProviderCatalog.defaultModel(for: kind).modelID
            let selection = ProviderSelection(kind: kind, modelID: modelID)
            _selection = selection
            Self.save(selection, to: defaults)
        }
        return settled
    }

    // MARK: - Selection persistence

    private static func loadSelection(from defaults: UserDefaults?) -> ProviderSelection? {
        guard let data = defaults?.data(forKey: selectionDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(ProviderSelection.self, from: data)
    }

    private static func save(_ selection: ProviderSelection, to defaults: UserDefaults?) {
        guard let defaults, let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: selectionDefaultsKey)
    }

    // MARK: - Validation state

    /// The last known validation/readiness state for a kind, or nil if it has
    /// never been validated/probed this session. See `validate(_:)`.
    public func validationState(_ kind: ProviderInfo.Kind) -> ValidationState? {
        lock.lock(); defer { lock.unlock() }
        return _validation[kind]
    }

    /// Whether a kind has been verified usable this session (its
    /// `validationState` is `.active`).
    public func isValidated(_ kind: ProviderInfo.Kind) -> Bool {
        validationState(kind) == .active
    }

    /// Mark a kind as `.validating` and capture the generation token a
    /// `validate(_:)` run must still hold to commit its result.
    private func beginValidation(for kind: ProviderInfo.Kind) -> Int {
        lock.lock(); defer { lock.unlock() }
        _validation[kind] = .validating
        return _validationGeneration[kind, default: 0]
    }

    /// Commit a validation result iff no credential/selection change has bumped
    /// the generation since `beginValidation`. Returns the state now in effect:
    /// the committed state on success, or the current (possibly cleared)
    /// authoritative state when the result is discarded as stale.
    private func commitValidation(
        _ state: ValidationState, for kind: ProviderInfo.Kind, token: Int
    ) -> ValidationState? {
        lock.lock(); defer { lock.unlock() }
        guard token == _validationGeneration[kind, default: 0] else {
            return _validation[kind]
        }
        _validation[kind] = state
        return state
    }

    /// Forget a kind's validation result, reverting it to "never checked".
    ///
    /// Called when the underlying credential changes out from under a cached
    /// result — on disconnect (so a deleted key can't stay `.active`) and when a
    /// new key/model is stored (so the stale result doesn't mask a re-check).
    /// Reverting to nil (rather than `.invalid`) keeps the optimistic
    /// "configured means usable until proven otherwise" behavior that lets Ask
    /// work at launch / offline before Settings has run a live validation.
    public func clearValidation(_ kind: ProviderInfo.Kind) {
        lock.lock(); defer { lock.unlock() }
        _validation[kind] = nil
        // Bump the generation so any validate() already in flight for this kind
        // (started against the old credential) discards its result instead of
        // overwriting the fresh "never checked" state.
        _validationGeneration[kind, default: 0] += 1
    }

    /// Verify that a kind is actually usable, updating its `validationState`.
    ///
    /// - **Remote** kinds (`.anthropic`, `.openAI`): loads the stored credential
    ///   and makes a lightweight authenticated test call. A stored key is not
    ///   treated as `.active` until that call succeeds. Only a genuine
    ///   *rejection* (HTTP 401/403) or a missing credential yields `.invalid`;
    ///   a transient failure (offline/timeout, 429, 5xx) yields `.unavailable`
    ///   so the stored key isn't condemned by a network blip.
    /// - **Local** (`.local`): probes the Ollama server and maps
    ///   `.ready → .active`; `.notRunning`/`.modelMissing → .unavailable`, since
    ///   both recover once the server is started / the model is pulled.
    ///
    /// The state moves through `.validating` while the request is in flight so
    /// the UI can show a spinner. If the credential/selection changes while the
    /// check is running (generation bump), the result is discarded — it is NOT
    /// written to the stored state. The returned value is best-effort in that
    /// case; callers that must reflect the committed state should re-read
    /// `validationState(_:)` after awaiting (as `SettingsModel.validate` does).
    @discardableResult
    public func validate(_ kind: ProviderInfo.Kind) async -> ValidationState {
        let token = beginValidation(for: kind)

        let info = ProviderCatalog.resolve(modelID: selection?.modelID, for: kind)

        func commit(_ state: ValidationState) -> ValidationState {
            commitValidation(state, for: kind, token: token) ?? state
        }

        // Load credentials for remote kinds; local needs none.
        let credentials: Credentials?
        if info.isLocal {
            credentials = nil
        } else {
            guard let stored = (try? store.load(for: kind)) ?? nil else {
                return commit(.invalid(
                    reason: ProviderError.notConfigured(kind).errorDescription
                ))
            }
            credentials = stored
        }

        let provider: LLMProvider
        do {
            provider = try factory(info, credentials)
        } catch {
            return commit(.invalid(
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            ))
        }

        let state: ValidationState
        if let local = provider as? LocalReadinessProbing {
            switch await local.probe() {
            case .ready:
                state = .active
            case .notRunning:
                state = .unavailable(
                    reason: "The local model isn't available. Make sure Ollama is running on this device."
                )
            case let .modelMissing(requested, _):
                state = .unavailable(
                    reason: "The model \"\(requested)\" isn't installed in Ollama. Pull it, or pick a different local model."
                )
            }
        } else if let remote = provider as? CredentialValidating {
            do {
                try await remote.validateCredential()
                state = .active
            } catch {
                state = Self.remoteValidationState(for: error)
            }
        } else {
            // No validation capability: fall back to "configured means active".
            state = .active
        }

        return commit(state)
    }

    /// Classify a remote `validateCredential()` failure: an authenticated
    /// rejection (HTTP 401/403) is a proven-bad key → `.invalid`; anything else
    /// (transport error, 429, 5xx, unexpected response) is transient →
    /// `.unavailable`, so a network blip or provider outage doesn't condemn a
    /// key that may still be valid.
    private static func remoteValidationState(for error: Error) -> ValidationState {
        let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        if case let HTTPError.status(code, _) = error, code == 401 || code == 403 {
            return .invalid(reason: reason)
        }
        return .unavailable(reason: reason)
    }

    // MARK: - Configuration

    /// Whether a kind is ready to use.
    ///
    /// Once a kind has been checked via `validate(_:)` this session, that result
    /// is authoritative (`.active → true`, anything else — including the
    /// transient `.unavailable` — → false, since it isn't verified ready right
    /// now). Before any check, the prior best-effort heuristic is used: local
    /// providers need no credentials and are assumed configured; remote kinds
    /// require a stored credential. This is deliberately stricter than
    /// `activeProvider()`, which stays optimistic and only refuses a proven-bad
    /// `.invalid`: this drives Settings/the picker's "verified ready" display,
    /// while `activeProvider()` governs whether Ask may optimistically try.
    /// Callers that need a verified-usable signal should prefer
    /// `isValidated(_:)`, which is only true after a successful `validate(_:)`.
    public func isConfigured(_ kind: ProviderInfo.Kind) -> Bool {
        if let state = validationState(kind) {
            return state == .active
        }
        if kind == .local { return true }
        // `try?` yields `Credentials??`; flatten and test for a stored value.
        let stored = (try? store.load(for: kind)) ?? nil
        return stored != nil
    }

    /// The kinds that are currently usable. Local is always included.
    public func availableKinds() -> [ProviderInfo.Kind] {
        let allKinds: [ProviderInfo.Kind] = [.anthropic, .openAI, .local]
        return allKinds.filter { isConfigured($0) }
    }

    // MARK: - Resolution

    /// Build the active provider, or return nil if no selection has been made.
    ///
    /// Resolves the selection's `modelID` against the catalog (falling back to
    /// the kind's default model), loads credentials (nil for local), and hands
    /// both to the factory.
    public func activeProvider() throws -> LLMProvider? {
        guard let selection = self.selection else { return nil }

        // If the selected kind was checked this session and the provider
        // actually rejected it (or a local model's probe failed), refuse to
        // resolve — otherwise Ask/Article would keep using a credential we know
        // is bad. Every other state stays optimistically usable: `nil` (never
        // checked) and `.validating` (a re-check in flight) mean "unproven, not
        // disproven", matching the cold-launch/offline behavior that lets Ask
        // work before Settings has run a live validation.
        if case .invalid = validationState(selection.kind) {
            throw ProviderError.notConfigured(selection.kind)
        }

        // Resolve the concrete model: exact match, then the same-tier legacy
        // replacement for retired IDs, then the catalog default for the kind.
        let info = ProviderCatalog.resolve(
            modelID: selection.modelID, for: selection.kind
        )

        // Local providers need no credentials; remote kinds require them.
        let credentials: Credentials?
        if info.isLocal {
            credentials = nil
        } else {
            guard let stored = try store.load(for: selection.kind) else {
                throw ProviderError.notConfigured(selection.kind)
            }
            credentials = stored
        }

        let provider = try factory(info, credentials)

        // Guard against a wiring bug: a local selection must yield a local provider.
        if info.isLocal && provider.info.isLocal == false {
            throw ProviderError.localMismatch
        }

        return provider
    }
}
