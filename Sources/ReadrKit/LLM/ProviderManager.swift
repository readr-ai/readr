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

    private let lock = NSLock()
    private let store: CredentialStore
    private let factory: ProviderFactory
    private let defaults: UserDefaults?
    private var _selection: ProviderSelection?

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

    // MARK: - Configuration

    /// Whether a kind is ready to use. Local providers need no credentials and
    /// are always considered configured; remote kinds require stored credentials.
    public func isConfigured(_ kind: ProviderInfo.Kind) -> Bool {
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
