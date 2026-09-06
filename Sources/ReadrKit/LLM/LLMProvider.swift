import Foundation

/// A chat-capable LLM, regardless of vendor or whether it runs locally.
///
/// Concrete implementations: `AnthropicProvider`, `OpenAIProvider`,
/// `LocalLLMProvider`. The reader UI only ever sees this protocol.
public protocol LLMProvider: Sendable {
    var info: ProviderInfo { get }

    /// Stream a completion for the assembled messages.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error>

    /// Best-effort token count for routing decisions (Tier 1 vs Tier 2).
    func countTokens(_ text: String) throws -> Int
}

/// A remote provider whose stored credential can be verified with a cheap
/// test call before the app treats the key as usable. Implemented by
/// `AnthropicProvider` and `OpenAIProvider`; consumed by `ProviderManager`.
public protocol CredentialValidating: Sendable {
    /// Perform a lightweight authenticated request. Returns normally when the
    /// credential is accepted, and throws when it is rejected
    /// (`HTTPError.status(401/403, …)`) or the network fails.
    func validateCredential() async throws
}

/// A local provider whose backing server can be probed for readiness (running
/// and hosting the requested model). Implemented by `LocalLLMProvider`;
/// consumed by `ProviderManager`.
public protocol LocalReadinessProbing: Sendable {
    /// Probe the local server and classify its readiness.
    func probe() async -> LocalLLMProvider.ProbeResult
}

/// Where a model that runs inside the app itself stands — the system's
/// on-device model (`.appleIntelligence`), or a bundled runtime later.
/// Reported by the app's provider, consumed by `ProviderManager.validate`.
public enum OnDeviceReadiness: Sendable, Equatable {
    /// Loaded, or loadable on the first request.
    case ready
    /// Not usable right now for a reason the reader can fix or wait out:
    /// Apple Intelligence switched off, the model still downloading. Maps to
    /// `ValidationState.unavailable` — the selection stays optimistic.
    case unavailable(reason: String)
    /// This device or OS can never run it. Maps to `ValidationState.invalid`,
    /// so the selection refuses to resolve to a provider that can only fail.
    case unsupported(reason: String)
}

/// A provider that runs inside the app and can say whether it is usable.
/// Implemented by the app's Foundation Models provider; consumed by
/// `ProviderManager`.
public protocol OnDeviceReadinessReporting: Sendable {
    func readiness() async -> OnDeviceReadiness
}

public struct ProviderInfo: Sendable, Hashable {
    /// `openAI` is the API-key path against api.openai.com; `chatGPT` is the
    /// separate subscription-OAuth path against ChatGPT's backend — distinct
    /// kinds because their credentials, catalogs, and endpoints all differ.
    /// `appleIntelligence` is the system's on-device model (Apple's
    /// FoundationModels framework, iOS/macOS 26+): no key, no account, no
    /// server. `local` is a loopback Ollama server the reader runs
    /// themselves. Both are `isLocal`; see `isOnDevice`.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case anthropic, openAI, chatGPT, openRouter, local, appleIntelligence

        /// Runs without credentials: nothing to store, validate, or revoke.
        public var isOnDevice: Bool {
            self == .local || self == .appleIntelligence
        }
    }
    public var kind: Kind
    public var modelID: String
    /// Usable context budget in tokens (after reserving room for the reply).
    public var contextBudget: Int
    /// Whether the provider supports prompt caching (cheap whole-book reuse).
    public var supportsPromptCaching: Bool
    /// True for on-device models — enables the zero-egress privacy mode.
    public var isLocal: Bool
    /// The name Settings shows for this model, when the catalogue has one
    /// ("Claude Opus 5"); see `name` for the fallback.
    public var displayName: String?

    /// What the reader sees: the catalogue's name, or one derived from the
    /// id for a model the catalogue has no row for. Never the bare id.
    public var name: String {
        displayName ?? ModelDisplayName.name(for: modelID)
    }

    public init(
        kind: Kind,
        modelID: String,
        contextBudget: Int,
        supportsPromptCaching: Bool,
        isLocal: Bool,
        displayName: String? = nil
    ) {
        self.kind = kind
        self.modelID = modelID
        self.contextBudget = contextBudget
        self.supportsPromptCaching = supportsPromptCaching
        self.isLocal = isLocal
        self.displayName = displayName
    }
}

public struct ChatRequest: Sendable {
    public var messages: [ChatMessage]
    /// Marks large, stable content (e.g. a whole book) as cacheable.
    public var cacheableSystemPrefix: String?
    public var maxOutputTokens: Int

    public init(
        messages: [ChatMessage],
        cacheableSystemPrefix: String? = nil,
        maxOutputTokens: Int = 1024
    ) {
        self.messages = messages
        self.cacheableSystemPrefix = cacheableSystemPrefix
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ChatMessage: Sendable, Hashable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatChunk: Sendable {
    public var textDelta: String
    public init(textDelta: String) { self.textDelta = textDelta }
}
