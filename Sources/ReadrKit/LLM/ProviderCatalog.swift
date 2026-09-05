import Foundation

/// A static catalog of the models the user can select, expressed as
/// `ProviderInfo` values. This is the source of truth the `ProviderManager`
/// consults when resolving a `ProviderSelection` into a concrete `ProviderInfo`.
///
/// Last verified against vendor model lists: 2026-07-23 (#46); the OpenRouter
/// rows on 2026-09-03. The vendor lists drift as models launch and retire —
/// re-verify on each release. OpenRouter alone is live: `OpenRouterModelStore`
/// fetches `/api/v1/models`, and the static rows here are only its curated
/// "Recommended" slice.
///
/// `contextBudget` is the ROUTER budget (drives whole-book vs retrieval in
/// `AdaptiveContextStrategy`), deliberately capped below some models' real
/// context windows (Opus 5 / Sonnet 5 / GPT-5.6 all offer ~1M): a 1M
/// budget would route nearly every book whole-book, multiplying per-question
/// cost. Raising the caps is a product decision, not a data fix.
///
/// Two consequences worth knowing before changing it: Tier 1 sends no
/// citations (Tier 2 does), so a higher budget silently drops citations for
/// more books; and long-context recall is not monotonic — targeted retrieval
/// often beats stuffing a whole book for a specific question.
public enum ProviderCatalog {

    /// Anthropic (Claude) models — flagship, balanced, and cheap/fast tiers.
    /// Prompt caching is supported across the line, which is what makes Tier-1
    /// whole-book context affordable to re-ask within a cache window.
    ///
    /// Note the budgets below are the router policy, not the models' ceilings:
    /// Opus 5 and Sonnet 5 both offer ~1M, while Haiku 4.5's real maximum is
    /// 200K — so Haiku is the only row where budget and ceiling coincide.
    public static let anthropicModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .anthropic,
            modelID: "claude-opus-5",
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

    /// The curated OpenRouter rows: the recommended set the picker leads
    /// with, and the only list the app has before the live catalogue arrives
    /// (offline, first launch, UI tests). Names, context windows and prices
    /// verified against `GET /api/v1/models` on 2026-09-03; prices are USD
    /// per million tokens and are what the picker shows offline. The order
    /// is the picker's "Recommended" order — strong defaults first, then the
    /// cheap fast tiers, then the `:free` rows.
    public static let openRouterCurated: [OpenRouterModel] = [
        OpenRouterModel(id: "anthropic/claude-sonnet-5", name: "Anthropic: Claude Sonnet 5",
                        contextLength: 1_000_000, promptUSDPerMillion: 2, completionUSDPerMillion: 10),
        OpenRouterModel(id: "anthropic/claude-haiku-4.5", name: "Anthropic: Claude Haiku 4.5",
                        contextLength: 200_000, promptUSDPerMillion: 1, completionUSDPerMillion: 5),
        OpenRouterModel(id: "openai/gpt-5.6-sol", name: "OpenAI: GPT-5.6 Sol",
                        contextLength: 1_050_000, promptUSDPerMillion: 2, completionUSDPerMillion: 10),
        OpenRouterModel(id: "openai/gpt-5.6-luna", name: "OpenAI: GPT-5.6 Luna",
                        contextLength: 1_050_000, promptUSDPerMillion: 0.20, completionUSDPerMillion: 1.20),
        OpenRouterModel(id: "google/gemini-3.8-flash", name: "Google: Gemini 3.8 Flash",
                        contextLength: 1_048_576, promptUSDPerMillion: 0.75, completionUSDPerMillion: 3.75),
        OpenRouterModel(id: "google/gemini-3.1-flash-lite", name: "Google: Gemini 3.1 Flash Lite",
                        contextLength: 1_048_576, promptUSDPerMillion: 0.25, completionUSDPerMillion: 1.50),
        OpenRouterModel(id: "moonshotai/kimi-k3", name: "MoonshotAI: Kimi K3",
                        contextLength: 1_048_576, promptUSDPerMillion: 3, completionUSDPerMillion: 15),
        OpenRouterModel(id: "moonshotai/kimi-k2.6", name: "MoonshotAI: Kimi K2.6",
                        contextLength: 262_144, promptUSDPerMillion: 0.95, completionUSDPerMillion: 4),
        OpenRouterModel(id: "meta/muse-spark-1.3", name: "Meta: Muse Spark 1.3",
                        contextLength: 1_048_576, promptUSDPerMillion: 1.25, completionUSDPerMillion: 4.25),
        OpenRouterModel(id: "meta/muse-glimmer-30b", name: "Meta: Muse Glimmer 30B",
                        contextLength: 131_072, promptUSDPerMillion: 0.30, completionUSDPerMillion: 1.10),
        OpenRouterModel(id: "deepseek/deepseek-v4-pro", name: "DeepSeek: DeepSeek V4 Pro",
                        contextLength: 1_048_576, promptUSDPerMillion: 1.04, completionUSDPerMillion: 2.07),
        OpenRouterModel(id: "deepseek/deepseek-v4-flash", name: "DeepSeek: DeepSeek V4 Flash",
                        contextLength: 1_048_576, promptUSDPerMillion: 0.08, completionUSDPerMillion: 0.17),
        OpenRouterModel(id: "qwen/qwen3.8-flash", name: "Qwen: Qwen3.8 Flash",
                        contextLength: 1_000_000, promptUSDPerMillion: 0.15, completionUSDPerMillion: 0.47),
        OpenRouterModel(id: "z-ai/glm-5.3-flash", name: "Z.ai: GLM 5.3 Flash",
                        contextLength: 1_310_720, promptUSDPerMillion: 0.07, completionUSDPerMillion: 0.25),
        OpenRouterModel(id: "x-ai/grok-4.6", name: "xAI: Grok 4.6",
                        contextLength: 500_000, promptUSDPerMillion: 2, completionUSDPerMillion: 6),
        OpenRouterModel(id: "minimax/minimax-m3:free", name: "MiniMax: MiniMax M3 (free)",
                        contextLength: 1_048_576, promptUSDPerMillion: 0, completionUSDPerMillion: 0),
        OpenRouterModel(id: "z-ai/glm-5.2:free", name: "Z.ai: GLM 5.2 (free)",
                        contextLength: 256_000, promptUSDPerMillion: 0, completionUSDPerMillion: 0),
        OpenRouterModel(id: "nvidia/nemotron-3.5-lightning:free", name: "NVIDIA: Nemotron 3.5 Lightning (free)",
                        contextLength: 1_000_000, promptUSDPerMillion: 0, completionUSDPerMillion: 0),
    ]

    /// The curated ids, in picker order — the "Recommended" section.
    public static let openRouterRecommendedIDs: [String] = openRouterCurated.map(\.id)

    /// The curated row for `id`, or nil when it isn't one — the offline
    /// price/context source for the model row in Settings.
    public static func openRouterCuratedModel(id: String) -> OpenRouterModel? {
        openRouterCurated.first { $0.id == id }
    }

    /// OpenRouter models (OpenAI-compatible API; slugs are namespaced),
    /// derived from `openRouterCurated`. The static list is only the
    /// recommended set — anything else in the live catalogue resolves
    /// through `resolve(modelID:for:)` with a registered budget. No prompt
    /// caching assumed across the router.
    public static let openRouterModels: [ProviderInfo] = openRouterCurated.map { model in
        ProviderInfo(
            kind: .openRouter,
            modelID: model.id,
            contextBudget: Self.openRouterBudget(forContext: model.contextLength),
            supportsPromptCaching: false,
            isLocal: false
        )
    }

    /// The router ceiling (see the type comment) applied to a real context
    /// window; a window the catalogue didn't report gets the conservative
    /// default.
    static func openRouterBudget(forContext contextLength: Int) -> Int {
        contextLength > 0 ? min(contextLength, 200_000) : openRouterFallbackBudget
    }

    /// The budget for an OpenRouter id the app knows nothing about — a
    /// persisted live pick before the catalogue has loaded this launch.
    static let openRouterFallbackBudget = 128_000

    /// Context windows for live-catalogue OpenRouter models, keyed by id.
    /// Filled by `OpenRouterModelStore` whenever a list arrives; read by
    /// `resolve`. Lock-protected: the store is an actor, the resolve
    /// happens on whatever thread `ProviderManager` is called from.
    ///
    /// Durable as well as in-memory: the map is mirrored to `UserDefaults`
    /// (`openRouterContextLengthsKey`) and the registry seeds itself from
    /// that mirror, synchronously, the first time it is touched. A persisted
    /// live pick therefore resolves with its real budget from the very
    /// first call after a relaunch — before any catalogue load, and without
    /// depending on the Caches JSON, which the system may purge and which
    /// `AppModel` restores only in an unawaited task.
    private static let openRouterBudgets = OpenRouterBudgetRegistry()

    /// The `UserDefaults.standard` key under which registered OpenRouter
    /// context windows persist, as a compact `[modelID: contextLength]`.
    public static let openRouterContextLengthsKey = "openRouter.contextLengths"

    private final class OpenRouterBudgetRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var contextLengths: [String: Int] = [:]
        private var seeded = false

        private var defaults: UserDefaults { .standard }

        /// Read the persisted mirror once, lazily, under the lock.
        private func seedIfNeeded() {
            guard !seeded else { return }
            seeded = true
            if let stored = defaults.dictionary(forKey: openRouterContextLengthsKey) as? [String: Int] {
                contextLengths = stored
            }
        }

        func register(_ models: [OpenRouterModel]) {
            lock.lock(); defer { lock.unlock() }
            seedIfNeeded()
            guard !models.isEmpty else { return }
            for model in models where model.contextLength > 0 {
                contextLengths[model.id] = model.contextLength
            }
            defaults.set(contextLengths, forKey: openRouterContextLengthsKey)
        }

        func budget(for id: String) -> Int? {
            lock.lock(); defer { lock.unlock() }
            seedIfNeeded()
            return contextLengths[id].map(openRouterBudget(forContext:))
        }

        /// Forget the in-memory map (what a relaunch does), and optionally
        /// the persisted mirror too.
        func reset(clearingPersisted: Bool) {
            lock.lock(); defer { lock.unlock() }
            contextLengths = [:]
            seeded = false
            if clearingPersisted {
                defaults.removeObject(forKey: openRouterContextLengthsKey)
            }
        }
    }

    /// Remember the context windows of a live OpenRouter list so a model
    /// picked from it resolves with a real budget — now and after a relaunch
    /// (the map is mirrored to `UserDefaults`). Idempotent; later lists
    /// overwrite earlier rows.
    public static func registerOpenRouterModels(_ models: [OpenRouterModel]) {
        openRouterBudgets.register(models)
    }

    /// Test hook: drop the in-memory registry so the next access re-seeds
    /// from the persisted mirror, or wipe the mirror as well.
    public static func resetOpenRouterBudgetsForTesting(clearingPersisted: Bool) {
        openRouterBudgets.reset(clearingPersisted: clearingPersisted)
    }

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

    /// The system's on-device model. One entry: the OS picks the model, and
    /// the app can only ask for it. Its window is 4,096 tokens *including* the
    /// answer, so the budget here keeps the retrieval tier's passages, anchor
    /// and question well inside it (`isLocal` already forces retrieval — the
    /// whole-book tier is never attempted).
    public static let appleIntelligenceModels: [ProviderInfo] = [
        ProviderInfo(
            kind: .appleIntelligence,
            modelID: "apple-on-device",
            contextBudget: 3_000,
            supportsPromptCaching: false,
            isLocal: true
        ),
    ]

    /// Every selectable model, across all kinds — built from the kinds, so a
    /// new kind can't be left out of the list.
    public static var all: [ProviderInfo] { ProviderInfo.Kind.allCases.flatMap(models(for:)) }

    /// The models available for a given provider kind.
    public static func models(for kind: ProviderInfo.Kind) -> [ProviderInfo] {
        switch kind {
        case .anthropic: return anthropicModels
        case .openAI: return openAIModels
        case .chatGPT: return chatGPTModels
        case .openRouter: return openRouterModels
        case .local: return localModels
        case .appleIntelligence: return appleIntelligenceModels
        }
    }

    /// Retired model IDs mapped to their same-tier successors, so a persisted
    /// selection survives a catalog refresh without silently jumping pricing
    /// tiers (a stored mid-tier sonnet-4-6 must not resolve to flagship Opus).
    static let legacyReplacements: [String: String] = [
        "claude-sonnet-4-6": "claude-sonnet-5",
        // Flagship → flagship: Opus 4.8 is superseded by Opus 5 at identical
        // pricing and context, so this stays same-tier.
        "claude-opus-4-8": "claude-opus-5",
        "gpt-4.1": "gpt-5.6-sol",
        "gpt-4.1-mini": "gpt-5.6-luna",
        // OpenRouter's unsuffixed GPT-5.6 slug retired with the Sol/Luna
        // split (flagship → flagship); the Llama free row left the `:free`
        // tier, so it maps to the free row that replaced it.
        "openai/gpt-5.6": "openai/gpt-5.6-sol",
        "meta-llama/llama-3.3-70b-instruct:free": "minimax/minimax-m3:free",
    ]

    /// Resolve a (possibly retired) model ID for `kind`: exact catalog match
    /// first, then the same-tier legacy replacement, then the kind's default.
    ///
    /// OpenRouter is the exception to the default fallback: its catalogue is
    /// live and the static list is only the recommended slice, so an unknown
    /// id there is a real model the reader picked, not a typo — it resolves
    /// as itself, with the budget the catalogue registered for it (see
    /// `registerOpenRouterModels`) or `openRouterFallbackBudget` before the
    /// catalogue has loaded this launch.
    public static func resolve(modelID: String?, for kind: ProviderInfo.Kind) -> ProviderInfo {
        let catalog = models(for: kind)
        if let id = modelID {
            if let exact = catalog.first(where: { $0.modelID == id }) { return exact }
            if let replacement = legacyReplacements[id],
               let mapped = catalog.first(where: { $0.modelID == replacement }) {
                return mapped
            }
            if kind == .openRouter, !id.isEmpty {
                return ProviderInfo(
                    kind: .openRouter,
                    modelID: id,
                    contextBudget: openRouterBudgets.budget(for: id) ?? openRouterFallbackBudget,
                    supportsPromptCaching: false,
                    isLocal: false
                )
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
