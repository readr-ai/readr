import Foundation

/// A static catalog of the models the user can select, expressed as
/// `ProviderInfo` values. This is the source of truth the `ProviderManager`
/// consults when resolving a `ProviderSelection` into a concrete `ProviderInfo`.
///
/// NEEDS-VERIFICATION: The exact model IDs and context-window (`contextBudget`)
/// values below should be confirmed against each vendor's current model list
/// before shipping — they drift as new models launch and older ones retire.
public enum ProviderCatalog {

    /// Anthropic (Claude) models. Prompt caching is supported across the line.
    public static let anthropicModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .anthropic,
            modelID: "claude-opus-4-8",
            contextBudget: 200_000,
            supportsPromptCaching: true,
            isLocal: false
        ),
        ProviderInfo(
            kind: .anthropic,
            modelID: "claude-sonnet-4-6",
            contextBudget: 200_000,
            supportsPromptCaching: true,
            isLocal: false
        ),
        ProviderInfo(
            kind: .anthropic,
            modelID: "claude-haiku-4-5",
            contextBudget: 200_000,
            supportsPromptCaching: true,
            isLocal: false
        ),
    ]

    /// OpenAI models. No prompt-caching support assumed here.
    public static let openAIModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .openAI,
            modelID: "gpt-4.1",
            contextBudget: 128_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .openAI,
            modelID: "gpt-4.1-mini",
            contextBudget: 128_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
    ]

    /// ChatGPT subscription models, served by ChatGPT's backend (not
    /// api.openai.com). The default slug is the one verified working in
    /// third-party wham clients (Muesli); NEEDS-VERIFICATION: confirm the full
    /// accepted slug list with a live subscription sign-in before shipping.
    public static let chatGPTModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .chatGPT,
            modelID: "gpt-5.4-mini",
            contextBudget: 128_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .chatGPT,
            modelID: "gpt-5.4",
            contextBudget: 128_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
    ]

    /// OpenRouter models (OpenAI-compatible API; slugs are namespaced).
    /// A deliberately small starter set: one strong default, one budget
    /// option, one free-tier model users can try before adding credits.
    /// NEEDS-VERIFICATION: slugs drift — especially the `:free` lineup.
    public static let openRouterModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .openRouter,
            modelID: "anthropic/claude-sonnet-4-6",
            contextBudget: 200_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .openRouter,
            modelID: "openai/gpt-4.1",
            contextBudget: 128_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .openRouter,
            modelID: "meta-llama/llama-3.3-70b-instruct:free",
            contextBudget: 65_536,
            supportsPromptCaching: false,
            isLocal: false
        ),
    ]

    /// On-device models — enable the zero-egress privacy mode.
    public static let localModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .local,
            modelID: "llama3",
            contextBudget: 8_192,
            supportsPromptCaching: false,
            isLocal: true
        ),
        ProviderInfo(
            kind: .local,
            modelID: "qwen2.5",
            contextBudget: 32_768,
            supportsPromptCaching: false,
            isLocal: true
        ),
    ]

    /// Every selectable model, across all kinds.
    public static let all: [ProviderInfo] =
        anthropicModels + openAIModels + chatGPTModels + openRouterModels + localModels

    /// The models available for a given provider kind.
    public static func models(for kind: ProviderInfo.Kind) -> [ProviderInfo] {
        switch kind {
        case .anthropic: return anthropicModels
        case .openAI: return openAIModels
        case .chatGPT: return chatGPTModels
        case .openRouter: return openRouterModels
        case .local: return localModels
        }
    }

    /// The default (first listed) model for a given provider kind.
    ///
    /// The per-kind lists above are non-empty by construction, so the
    /// force-unwrap is safe.
    public static func defaultModel(for kind: ProviderInfo.Kind) -> ProviderInfo {
        models(for: kind).first!
    }
}
