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
        anthropicModels + openAIModels + localModels

    /// The models available for a given provider kind.
    public static func models(for kind: ProviderInfo.Kind) -> [ProviderInfo] {
        switch kind {
        case .anthropic: return anthropicModels
        case .openAI: return openAIModels
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
