import Foundation

/// A static catalog of the models the user can select, expressed as
/// `ProviderInfo` values. This is the source of truth the `ProviderManager`
/// consults when resolving a `ProviderSelection` into a concrete `ProviderInfo`.
///
/// Last verified against vendor model lists: 2026-07-23 (#46). This list
/// drifts as models launch and retire — re-verify on each release, or
/// replace with a live `/v1/models` fetch (tracked follow-up in #46).
///
/// `contextBudget` is the ROUTER budget (drives whole-book vs retrieval in
/// `AdaptiveContextStrategy`), deliberately capped below some models' real
/// context windows (Opus 4.8 / Sonnet 5 / GPT-5.6 all offer ~1M): a 1M
/// budget would route nearly every book whole-book, multiplying per-question
/// cost. Raising the caps is a product decision, not a data fix.
public enum ProviderCatalog {

    /// Anthropic (Claude) models. Prompt caching is supported across the line,
    /// which is what makes Tier-1 whole-book context affordable to re-ask.
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
            modelID: "claude-sonnet-5",
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

    /// OpenAI models (GPT-5.6 family: Sol = flagship, Terra = balanced,
    /// Luna = cost-efficient). No prompt-caching support assumed here.
    public static let openAIModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .openAI,
            modelID: "gpt-5.6-sol",
            contextBudget: 200_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .openAI,
            modelID: "gpt-5.6-terra",
            contextBudget: 200_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .openAI,
            modelID: "gpt-5.6-luna",
            contextBudget: 200_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
    ]

    /// ChatGPT subscription models, served by ChatGPT's backend (not
    /// api.openai.com). These slugs track what ChatGPT itself offers, which
    /// is a *different* list from the API's — so they deliberately lag the
    /// `openAIModels` line above rather than matching it. The default is the
    /// slug verified working in third-party wham clients (Muesli);
    /// NEEDS-VERIFICATION: confirm the accepted list with a live sign-in.
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
            modelID: "anthropic/claude-sonnet-5",
            contextBudget: 200_000,
            supportsPromptCaching: false,
            isLocal: false
        ),
        ProviderInfo(
            kind: .openRouter,
            modelID: "openai/gpt-5.6",
            contextBudget: 200_000,
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

    /// Retired model IDs mapped to their same-tier successors, so a persisted
    /// selection survives a catalog refresh without silently jumping pricing
    /// tiers (a stored mid-tier sonnet-4-6 must not resolve to flagship Opus).
    static let legacyReplacements: [String: String] = [
        "claude-sonnet-4-6": "claude-sonnet-5",
        "gpt-4.1": "gpt-5.6-sol",
        "gpt-4.1-mini": "gpt-5.6-luna",
    ]

    /// Resolve a (possibly retired) model ID for `kind`: exact catalog match
    /// first, then the same-tier legacy replacement, then the kind's default.
    public static func resolve(modelID: String?, for kind: ProviderInfo.Kind) -> ProviderInfo {
        let catalog = models(for: kind)
        if let id = modelID {
            if let exact = catalog.first(where: { $0.modelID == id }) { return exact }
            if let replacement = legacyReplacements[id],
               let mapped = catalog.first(where: { $0.modelID == replacement }) {
                return mapped
            }
        }
        return defaultModel(for: kind)
    }

    /// The default (first listed) model for a given provider kind.
    ///
    /// The per-kind lists above are non-empty by construction, so the
    /// force-unwrap is safe.
    public static func defaultModel(for kind: ProviderInfo.Kind) -> ProviderInfo {
        models(for: kind).first!
    }
}
