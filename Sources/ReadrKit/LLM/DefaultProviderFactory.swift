import Foundation

/// Builds a concrete `LLMProvider` from a `ProviderInfo` + optional credentials.
/// This is the default `ProviderManager.ProviderFactory`; it lives here because
/// all concrete providers are part of `ReadrKit`, keeping it unit-testable.
public enum DefaultProviderFactory {

    public static func make(
        info: ProviderInfo,
        credentials: Credentials?,
        http: HTTPClient = URLSessionHTTPClient()
    ) throws -> LLMProvider {
        switch info.kind {
        case .anthropic:
            guard let credentials else { throw ProviderManager.ProviderError.notConfigured(.anthropic) }
            return AnthropicProvider(
                credentials: credentials, model: info.modelID,
                http: http, contextBudget: info.contextBudget
            )
        case .openAI:
            guard let credentials else { throw ProviderManager.ProviderError.notConfigured(.openAI) }
            return OpenAIProvider(
                credentials: credentials, model: info.modelID,
                http: http, contextBudget: info.contextBudget
            )
        case .local:
            return LocalLLMProvider(
                model: info.modelID, http: http, contextBudget: info.contextBudget
            )
        }
    }

    /// A `ProviderManager.ProviderFactory` bound to the given transport.
    public static func factory(http: HTTPClient = URLSessionHTTPClient()) -> ProviderManager.ProviderFactory {
        { info, credentials in try make(info: info, credentials: credentials, http: http) }
    }
}
