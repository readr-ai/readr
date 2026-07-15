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
    /// test call succeeds, so it moves `stored → validating → active` (or
    /// `→ invalid` when the provider rejects it). For **local** the state is
    /// derived from an Ollama `probe()` (`active` when ready, `invalid` when the
    /// server is down or the model is missing).
    public enum ValidationState: Sendable, Equatable {
        /// A validation request is in flight.
        case validating
        /// Verified usable — the key was accepted / the local model is ready.
        case active
        /// Not usable; `reason` is a reader-facing sentence when available.
        case invalid(reason: String?)
    }

    private let lock = NSLock()
    private let store: CredentialStore
    private let factory: ProviderFactory
    private let defaults: UserDefaults?
    private var _selection: ProviderSelection?
    /// Latest validation/readiness state per kind (nil == never checked).
    private var _validation: [ProviderInfo.Kind: ValidationState] = [:]

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
        _selection = selection
        Self.save(selection, to: defaults)
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

    private func setValidation(_ state: ValidationState, for kind: ProviderInfo.Kind) {
        lock.lock(); defer { lock.unlock() }
        _validation[kind] = state
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
    }

    /// Verify that a kind is actually usable, updating its `validationState`.
    ///
    /// - **Remote** kinds (`.anthropic`, `.openAI`): loads the stored credential
    ///   and makes a lightweight authenticated test call. A stored key is not
    ///   treated as `.active` until that call succeeds; a 401/403 rejection
    ///   yields `.invalid`. Missing credentials yield `.invalid` immediately.
    /// - **Local** (`.local`): probes the Ollama server and maps
    ///   `.ready → .active`, `.notRunning`/`.modelMissing → .invalid`.
    ///
    /// The state moves through `.validating` while the request is in flight so
    /// the UI can show a spinner. Returns the resulting `ValidationState`.
    @discardableResult
    public func validate(_ kind: ProviderInfo.Kind) async -> ValidationState {
        setValidation(.validating, for: kind)

        let info = ProviderCatalog.models(for: kind)
            .first { $0.modelID == selection?.modelID }
            ?? ProviderCatalog.defaultModel(for: kind)

        // Load credentials for remote kinds; local needs none.
        let credentials: Credentials?
        if info.isLocal {
            credentials = nil
        } else {
            guard let stored = (try? store.load(for: kind)) ?? nil else {
                let state = ValidationState.invalid(
                    reason: ProviderError.notConfigured(kind).errorDescription
                )
                setValidation(state, for: kind)
                return state
            }
            credentials = stored
        }

        let provider: LLMProvider
        do {
            provider = try factory(info, credentials)
        } catch {
            let state = ValidationState.invalid(
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
            setValidation(state, for: kind)
            return state
        }

        let state: ValidationState
        if let local = provider as? LocalReadinessProbing {
            switch await local.probe() {
            case .ready:
                state = .active
            case .notRunning:
                state = .invalid(
                    reason: "The local model isn't available. Make sure Ollama is running on this device."
                )
            case let .modelMissing(requested, _):
                state = .invalid(
                    reason: "The model \"\(requested)\" isn't installed in Ollama. Pull it, or pick a different local model."
                )
            }
        } else if let remote = provider as? CredentialValidating {
            do {
                try await remote.validateCredential()
                state = .active
            } catch {
                state = .invalid(
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        } else {
            // No validation capability: fall back to "configured means active".
            state = .active
        }

        setValidation(state, for: kind)
        return state
    }

    // MARK: - Configuration

    /// Whether a kind is ready to use.
    ///
    /// Once a kind has been checked via `validate(_:)` this session, that result
    /// is authoritative (`.active → true`, anything else → false). Before any
    /// check, the prior best-effort heuristic is used: local providers need no
    /// credentials and are assumed configured; remote kinds require a stored
    /// credential. Callers that need a verified-usable signal should prefer
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

        // Resolve the concrete model: prefer an exact modelID match, else the
        // catalog default for the kind.
        let info = ProviderCatalog.models(for: selection.kind)
            .first { $0.modelID == selection.modelID }
            ?? ProviderCatalog.defaultModel(for: selection.kind)

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
