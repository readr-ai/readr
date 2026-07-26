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

public struct ProviderInfo: Sendable, Hashable {
    /// `openAI` is the API-key path against api.openai.com; `chatGPT` is the
    /// separate subscription-OAuth path against ChatGPT's backend — distinct
    /// kinds because their credentials, catalogs, and endpoints all differ.
    public enum Kind: String, Sendable, Hashable, Codable {
        case anthropic, openAI, chatGPT, openRouter, local
    }
    public var kind: Kind
    public var modelID: String
    /// Usable context budget in tokens (after reserving room for the reply).
    public var contextBudget: Int
    /// Whether the provider supports prompt caching (cheap whole-book reuse).
    public var supportsPromptCaching: Bool
    /// True for on-device models — enables the zero-egress privacy mode.
    public var isLocal: Bool

    public init(
        kind: Kind,
        modelID: String,
        contextBudget: Int,
        supportsPromptCaching: Bool,
        isLocal: Bool
    ) {
        self.kind = kind
        self.modelID = modelID
        self.contextBudget = contextBudget
        self.supportsPromptCaching = supportsPromptCaching
        self.isLocal = isLocal
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
