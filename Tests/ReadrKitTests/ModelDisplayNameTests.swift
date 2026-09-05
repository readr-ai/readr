import XCTest
@testable import ReadrKit

/// Settings used to list models by their wire ids — `claude-opus-5`,
/// `gpt-5.6-sol` — which are not names anyone chose to read. Every catalogue
/// row now carries a display name, and ids the catalogue does not know (a
/// live OpenRouter pick, offline) get a readable one derived from the id.
/// (September 2026 UX review, F11.)
final class ModelDisplayNameTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProviderCatalog.resetOpenRouterBudgetsForTesting(clearingPersisted: true)
    }

    override func tearDown() {
        ProviderCatalog.resetOpenRouterBudgetsForTesting(clearingPersisted: true)
        super.tearDown()
    }

    func testEveryCatalogueRowHasAReadableName() {
        for info in ProviderCatalog.all {
            XCTAssertFalse(info.name.isEmpty, "\(info.modelID) has no name")
            XCTAssertNotEqual(info.name, info.modelID, "\(info.modelID) is shown as its id")
        }
    }

    func testCatalogueNamesReadAsProducts() {
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "claude-opus-5", for: .anthropic).name, "Claude Opus 5")
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "claude-haiku-4-5", for: .anthropic).name, "Claude Haiku 4.5")
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "gpt-5.6-sol", for: .openAI).name, "GPT-5.6 Sol")
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "gpt-5.4-mini", for: .chatGPT).name, "GPT-5.4 mini")
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: "apple-on-device", for: .appleIntelligence).name,
            "Apple Intelligence"
        )
        // A retired id resolves to its successor, and takes its name.
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "claude-opus-4-8", for: .anthropic).name, "Claude Opus 5")
        // OpenRouter's curated rows carry the catalogue's own names.
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: "anthropic/claude-haiku-4.5", for: .openRouter).name,
            "Anthropic: Claude Haiku 4.5"
        )
    }

    func testAnUnknownIDIsMadeReadable() {
        // A live OpenRouter pick the static catalogue has never seen: the
        // vendor namespace goes, the family is capitalized, `:free` becomes
        // a suffix — the same shape as the catalogue's own rows.
        XCTAssertEqual(ModelDisplayName.name(for: "zeta/zebra-1"), "Zebra 1")
        XCTAssertEqual(ModelDisplayName.name(for: "minimax/minimax-m3:free"), "Minimax M3 (free)")
        XCTAssertEqual(ModelDisplayName.name(for: "claude-sonnet-4-6"), "Claude Sonnet 4.6")
        XCTAssertEqual(ModelDisplayName.name(for: "gpt-4.1-mini"), "GPT-4.1 mini")
        XCTAssertEqual(ModelDisplayName.name(for: "llama3"), "Llama 3")
        XCTAssertEqual(ModelDisplayName.name(for: "qwen2.5"), "Qwen 2.5")
        XCTAssertEqual(ModelDisplayName.name(for: ""), "")
        // OpenAI's own spellings, and a date suffix that is not a version.
        XCTAssertEqual(ModelDisplayName.name(for: "openai/gpt-4o-mini"), "GPT-4o mini")
        XCTAssertEqual(
            ModelDisplayName.name(for: "google/gemini-2.5-pro-preview-05-06"),
            "Gemini 2.5 Pro Preview 05 06"
        )
        XCTAssertEqual(ModelDisplayName.name(for: "cohere/command-r-plus-08-2024"), "Command R Plus 08 2024")
    }

    // A live OpenRouter list registers its names alongside its context
    // windows, so an id the static catalogue never saw resolves with the
    // name the catalogue gave it — everywhere, not only where a view holds
    // the store — and still after a relaunch (the mirror persists).
    func testALiveOpenRouterNameIsRegisteredAndSurvivesARelaunch() {
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "zeta/zebra-1", for: .openRouter).name, "Zebra 1")
        ProviderCatalog.registerOpenRouterModels([
            OpenRouterModel(id: "zeta/zebra-1", name: "Zeta: Zebra 1", contextLength: 131_072,
                            promptUSDPerMillion: 0.1, completionUSDPerMillion: 0.2),
        ])
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "zeta/zebra-1", for: .openRouter).name, "Zeta: Zebra 1")
        ProviderCatalog.resetOpenRouterBudgetsForTesting(clearingPersisted: false)
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: "zeta/zebra-1", for: .openRouter).name, "Zeta: Zebra 1",
            "the registered name comes back from the persisted mirror"
        )
    }

    // Settings' "Ask uses …" line and the sidebar's model line come from
    // one place: the selection, by name and card.
    func testASelectionSummarisesItselfByNameAndCard() {
        let claude = ProviderSelection(kind: .anthropic, modelID: "claude-opus-5")
        XCTAssertEqual(claude.summary(connected: true), "Claude Opus 5 · Claude (Anthropic)")
        XCTAssertEqual(
            claude.summary(connected: false), "Claude Opus 5 · Claude (Anthropic) — not connected"
        )
        XCTAssertEqual(claude.modelName, "Claude Opus 5")
        // A retired id is summarised as its successor.
        XCTAssertEqual(
            ProviderSelection(kind: .anthropic, modelID: "claude-opus-4-8").modelName, "Claude Opus 5"
        )
        // A vendor with two ways in says which one.
        XCTAssertEqual(
            ProviderSelection(kind: .chatGPT, modelID: "gpt-5.4").summary(connected: true),
            "GPT-5.4 · OpenAI via ChatGPT"
        )
        XCTAssertEqual(
            ProviderSelection(kind: .openAI, modelID: "gpt-5.6-sol").summary(connected: true),
            "GPT-5.6 Sol · OpenAI via API key"
        )
        XCTAssertEqual(
            ProviderSelection(kind: .appleIntelligence, modelID: "apple-on-device").summary(connected: true),
            "Apple Intelligence · On this device"
        )
    }

    func testAnExplicitNameWinsOverTheDerivedOne() {
        let derived = ProviderInfo(
            kind: .openRouter, modelID: "zeta/zebra-1", contextBudget: 1, supportsPromptCaching: false, isLocal: false
        )
        XCTAssertEqual(derived.name, "Zebra 1")
        let named = ProviderInfo(
            kind: .openRouter, modelID: "zeta/zebra-1", contextBudget: 1, supportsPromptCaching: false,
            isLocal: false, displayName: "Zeta: Zebra 1"
        )
        XCTAssertEqual(named.name, "Zeta: Zebra 1")
        // An unknown live OpenRouter id resolves as itself, and is readable.
        XCTAssertEqual(ProviderCatalog.resolve(modelID: "zeta/zebra-1", for: .openRouter).name, "Zebra 1")
    }
}
