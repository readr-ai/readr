import XCTest
@testable import ReadrKit

/// OpenRouter's catalogue is live, not a three-row list: the picker shows
/// whatever `GET /api/v1/models` returns today, with a curated set on top and
/// a disk copy for when the network is away. These pin the parse, the price
/// labels, the cache/offline fallbacks, and the one resolve rule that lets a
/// live-picked id survive `ProviderCatalog` — an unknown OpenRouter id is a
/// real model, not a typo to be replaced by the default.
final class OpenRouterModelCatalogTests: XCTestCase {

    // MARK: - Fixture

    /// A slice of the live shape (2026-09-03): pricing is USD per token as
    /// strings, and the entries that must be dropped are all here — a batch
    /// variant, a router alias, and an image model.
    private static let fixture = Data("""
    {"data":[
      {"id":"zeta/zebra-1","name":"Zeta: Zebra 1","context_length":131072,
       "pricing":{"prompt":"0.00000008","completion":"0.00000017"},
       "architecture":{"output_modalities":["text"]}},
      {"id":"anthropic/claude-sonnet-5","name":"Anthropic: Claude Sonnet 5","context_length":1000000,
       "pricing":{"prompt":"0.000002","completion":"0.00001"},
       "architecture":{"output_modalities":["text"]}},
      {"id":"anthropic/claude-sonnet-5:batch","name":"Anthropic: Claude Sonnet 5 (batch)","context_length":1000000,
       "pricing":{"prompt":"0.000001","completion":"0.000005"},
       "architecture":{"output_modalities":["text"]}},
      {"id":"~cheap","name":"Router: Cheap","context_length":128000,
       "pricing":{"prompt":"0","completion":"0"},
       "architecture":{"output_modalities":["text"]}},
      {"id":"pixel/painter","name":"Pixel: Painter","context_length":32000,
       "pricing":{"prompt":"0.00001","completion":"0.00004"},
       "architecture":{"output_modalities":["image"]}},
      {"id":"minimax/minimax-m3:free","name":"MiniMax: MiniMax M3 (free)","context_length":1048576,
       "pricing":{"prompt":"0","completion":"0"},
       "architecture":{"output_modalities":["text"]}}
    ]}
    """.utf8)

    private func temporaryCacheURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenRouterModelCatalogTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("OpenRouterModels.json")
    }

    /// Counts calls across the `@Sendable` fetch closure.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private struct Boom: Error {}

    // MARK: - Parse

    func testParseFiltersBatchAliasAndNonTextAndSortsByName() throws {
        let models = try OpenRouterModelCatalog.parse(Self.fixture)
        XCTAssertEqual(
            models.map(\.id),
            ["anthropic/claude-sonnet-5", "minimax/minimax-m3:free", "zeta/zebra-1"],
            "batch variants, router aliases and image models are dropped; the rest sort by name"
        )
    }

    func testParseConvertsPerTokenPricingToPerMillion() throws {
        let models = try OpenRouterModelCatalog.parse(Self.fixture)
        let sonnet = try XCTUnwrap(models.first { $0.id == "anthropic/claude-sonnet-5" })
        XCTAssertEqual(sonnet.name, "Anthropic: Claude Sonnet 5")
        XCTAssertEqual(sonnet.contextLength, 1_000_000)
        XCTAssertEqual(sonnet.promptUSDPerMillion, 2, accuracy: 0.0001)
        XCTAssertEqual(sonnet.completionUSDPerMillion, 10, accuracy: 0.0001)
        XCTAssertFalse(sonnet.isFree)

        let zebra = try XCTUnwrap(models.first { $0.id == "zeta/zebra-1" })
        XCTAssertEqual(zebra.promptUSDPerMillion, 0.08, accuracy: 0.0001)
        XCTAssertEqual(zebra.completionUSDPerMillion, 0.17, accuracy: 0.0001)

        let free = try XCTUnwrap(models.first { $0.id == "minimax/minimax-m3:free" })
        XCTAssertTrue(free.isFree)
    }

    /// OpenRouter reports "-1" for routers priced per upstream model
    /// (openrouter/fusion); a price it can't state is not a price of zero,
    /// and such a row must never land in the Free section.
    func testParseDropsDynamicallyPricedAndUnparseablePriceRows() throws {
        let data = Data("""
        {"data":[
          {"id":"openrouter/fusion","name":"OpenRouter: Fusion","context_length":128000,
           "pricing":{"prompt":"-1","completion":"-1"},
           "architecture":{"output_modalities":["text"]}},
          {"id":"acme/half-priced","name":"Acme: Half Priced","context_length":128000,
           "pricing":{"prompt":"0.000001","completion":"-1"},
           "architecture":{"output_modalities":["text"]}},
          {"id":"acme/garbled","name":"Acme: Garbled","context_length":128000,
           "pricing":{"prompt":"n/a","completion":"0.000001"},
           "architecture":{"output_modalities":["text"]}},
          {"id":"acme/unpriced","name":"Acme: Unpriced","context_length":128000,
           "pricing":{},
           "architecture":{"output_modalities":["text"]}},
          {"id":"acme/free","name":"Acme: Free","context_length":128000,
           "pricing":{"prompt":"0","completion":"0"},
           "architecture":{"output_modalities":["text"]}}
        ]}
        """.utf8)
        let models = try OpenRouterModelCatalog.parse(data)
        XCTAssertEqual(models.map(\.id), ["acme/free"], "only a stated $0/$0 row survives as free")
        XCTAssertTrue(models[0].isFree)
    }

    func testIsFreeOnlyWhenBothPricesAreExactlyZero() {
        func model(_ prompt: Double, _ completion: Double) -> OpenRouterModel {
            OpenRouterModel(
                id: "x/y", name: "X", contextLength: 1,
                promptUSDPerMillion: prompt, completionUSDPerMillion: completion
            )
        }
        XCTAssertTrue(model(0, 0).isFree)
        XCTAssertFalse(model(0, 0.1).isFree)
        XCTAssertFalse(model(0.1, 0).isFree)
        XCTAssertFalse(model(-1, -1).isFree, "a sentinel is not a price")
    }

    func testParseRejectsMalformedJSON() {
        XCTAssertThrowsError(try OpenRouterModelCatalog.parse(Data("not json".utf8)))
    }

    // MARK: - Labels

    func testPriceLabelFormatting() {
        func model(_ prompt: Double, _ completion: Double) -> OpenRouterModel {
            OpenRouterModel(
                id: "x/y", name: "X", contextLength: 1,
                promptUSDPerMillion: prompt, completionUSDPerMillion: completion
            )
        }
        XCTAssertEqual(model(0.08, 0.17).priceLabel, "$0.08 in · $0.17 out per 1M tokens")
        XCTAssertEqual(model(2, 10).priceLabel, "$2 in · $10 out per 1M tokens")
        XCTAssertEqual(model(0.2, 1.2).priceLabel, "$0.20 in · $1.20 out per 1M tokens")
        XCTAssertEqual(model(1.25, 4.25).priceLabel, "$1.25 in · $4.25 out per 1M tokens")
        XCTAssertEqual(model(0.075, 0.25).priceLabel, "$0.075 in · $0.25 out per 1M tokens")
        XCTAssertEqual(model(0, 0).priceLabel, "Free")
    }

    func testPickerLineJoinsPriceAndContext() {
        let paid = OpenRouterModel(
            id: "x/y", name: "X", contextLength: 1_048_576,
            promptUSDPerMillion: 0.08, completionUSDPerMillion: 0.17
        )
        XCTAssertEqual(paid.pickerLine, "$0.08 in · $0.17 out per 1M · 1M context")
        let free = OpenRouterModel(
            id: "x/y:free", name: "X", contextLength: 256_000,
            promptUSDPerMillion: 0, completionUSDPerMillion: 0
        )
        XCTAssertEqual(free.pickerLine, "Free · 256K context")
    }

    func testContextLabelRoundsToThousandsAndMillions() {
        func model(_ context: Int) -> OpenRouterModel {
            OpenRouterModel(
                id: "x/y", name: "X", contextLength: context,
                promptUSDPerMillion: 0, completionUSDPerMillion: 0
            )
        }
        XCTAssertEqual(model(1_048_576).contextLabel, "1M context")
        XCTAssertEqual(model(1_000_000).contextLabel, "1M context")
        XCTAssertEqual(model(200_000).contextLabel, "200K context")
        XCTAssertEqual(model(131_072).contextLabel, "131K context")
        XCTAssertEqual(model(262_144).contextLabel, "262K context")
        XCTAssertEqual(model(8_192).contextLabel, "8K context")
    }

    // MARK: - Store

    func testStoreFetchesThenServesTheDiskCacheWhenTheRefreshFails() async throws {
        let cacheURL = temporaryCacheURL()
        let first = OpenRouterModelStore(
            cacheURL: cacheURL, arguments: [],
            fetch: { _ in Self.fixture }
        )
        let live = await first.load()
        XCTAssertEqual(live.source, .live)
        XCTAssertEqual(live.models.map(\.id), try OpenRouterModelCatalog.parse(Self.fixture).map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "a live list is written to disk")

        // A fresh store with an expired TTL must try the network — and when
        // that throws, hand back the stale copy rather than nothing.
        let second = OpenRouterModelStore(
            cacheURL: cacheURL, timeToLive: 0, arguments: [],
            fetch: { _ in throw Boom() }
        )
        let stale = await second.load()
        XCTAssertEqual(stale.source, .cache)
        XCTAssertEqual(stale.models, live.models)
        let models = await second.models()
        XCTAssertEqual(models, live.models)
    }

    func testStoreServesAFreshDiskCacheWithoutFetching() async {
        let cacheURL = temporaryCacheURL()
        let first = OpenRouterModelStore(cacheURL: cacheURL, arguments: [], fetch: { _ in Self.fixture })
        _ = await first.load()

        let counter = CallCounter()
        let second = OpenRouterModelStore(
            cacheURL: cacheURL, arguments: [],
            fetch: { _ in counter.bump(); return Self.fixture }
        )
        let loaded = await second.load()
        XCTAssertEqual(loaded.source, .cache)
        XCTAssertEqual(counter.value, 0, "a cache younger than the TTL is served as-is")
        let cached = await second.cachedModels()
        XCTAssertEqual(cached, loaded.models)
    }

    /// A clock corrected backwards leaves a cache stamped in the future; an
    /// age below zero is not "fresh", it is unknowable, and must refetch.
    func testStoreTreatsAFutureDatedCacheAsStale() async {
        let cacheURL = temporaryCacheURL()
        let later = Date(timeIntervalSinceNow: 6 * 60 * 60)
        let first = OpenRouterModelStore(
            cacheURL: cacheURL, arguments: [], now: { later },
            fetch: { _ in Self.fixture }
        )
        _ = await first.load()

        let counter = CallCounter()
        let second = OpenRouterModelStore(
            cacheURL: cacheURL, arguments: [], now: { Date() },
            fetch: { _ in counter.bump(); return Self.fixture }
        )
        let loaded = await second.load()
        XCTAssertEqual(loaded.source, .live)
        XCTAssertEqual(counter.value, 1, "a cache from the future is refetched, not trusted")
    }

    func testStoreFallsBackToTheCuratedListWhenNothingIsCachedAndTheFetchFails() async {
        let store = OpenRouterModelStore(
            cacheURL: temporaryCacheURL(), arguments: [],
            fetch: { _ in throw Boom() }
        )
        let loaded = await store.load()
        XCTAssertEqual(loaded.source, .curated)
        XCTAssertEqual(loaded.models, ProviderCatalog.openRouterCurated)
    }

    func testStoreUsesTheCuratedListOnlyUnderAUITestFlag() async {
        let counter = CallCounter()
        let cacheURL = temporaryCacheURL()
        let store = OpenRouterModelStore(
            cacheURL: cacheURL, arguments: ["-uiTestSeed"],
            fetch: { _ in counter.bump(); return Self.fixture }
        )
        let loaded = await store.load()
        XCTAssertEqual(loaded.source, .curated)
        XCTAssertEqual(loaded.models, ProviderCatalog.openRouterCurated)
        XCTAssertEqual(counter.value, 0, "no network under -uiTest*")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path), "and no disk cache")
        let cached = await store.cachedModels()
        XCTAssertTrue(cached.isEmpty)
    }

    // MARK: - Catalog

    func testCuratedListDrivesTheStaticOpenRouterCatalog() {
        let curated = ProviderCatalog.openRouterCurated
        XCTAssertEqual(ProviderCatalog.openRouterModels.map(\.modelID), curated.map(\.id))
        XCTAssertEqual(ProviderCatalog.openRouterRecommendedIDs, curated.map(\.id))
        XCTAssertEqual(ProviderCatalog.defaultModel(for: .openRouter).modelID, "anthropic/claude-sonnet-5")
        for (info, model) in zip(ProviderCatalog.openRouterModels, curated) {
            XCTAssertEqual(info.kind, .openRouter)
            XCTAssertEqual(info.contextBudget, min(model.contextLength, 200_000), model.id)
            XCTAssertFalse(info.supportsPromptCaching, model.id)
            XCTAssertFalse(info.isLocal, model.id)
        }
        XCTAssertEqual(Set(curated.map(\.id)).count, curated.count, "no duplicate ids")
        XCTAssertEqual(curated.filter(\.isFree).count, 3, "three :free rows")
        XCTAssertFalse(curated.contains { $0.id == "openai/gpt-5.6" })
        XCTAssertFalse(curated.contains { $0.id == "meta-llama/llama-3.3-70b-instruct:free" })
    }

    func testCuratedPricingIsAvailableOffline() throws {
        let flash = try XCTUnwrap(ProviderCatalog.openRouterCuratedModel(id: "deepseek/deepseek-v4-flash"))
        XCTAssertEqual(flash.promptUSDPerMillion, 0.08, accuracy: 0.0001)
        XCTAssertEqual(flash.completionUSDPerMillion, 0.17, accuracy: 0.0001)
        XCTAssertNil(ProviderCatalog.openRouterCuratedModel(id: "acme/not-curated"))
    }

    func testLegacyOpenRouterIDsMapToSameTierSuccessors() {
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: "openai/gpt-5.6", for: .openRouter).modelID,
            "openai/gpt-5.6-sol"
        )
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: "meta-llama/llama-3.3-70b-instruct:free", for: .openRouter).modelID,
            "minimax/minimax-m3:free"
        )
    }

    // MARK: - Resolve

    func testResolveKeepsAnUnknownOpenRouterIDWithTheRegisteredBudget() {
        let id = "acme/test-\(UUID().uuidString)"
        ProviderCatalog.registerOpenRouterModels([
            OpenRouterModel(
                id: id, name: "Acme Test", contextLength: 64_000,
                promptUSDPerMillion: 0.1, completionUSDPerMillion: 0.2
            ),
        ])
        let info = ProviderCatalog.resolve(modelID: id, for: .openRouter)
        XCTAssertEqual(info.kind, .openRouter)
        XCTAssertEqual(info.modelID, id, "a live-picked id is a real model, not a typo")
        XCTAssertEqual(info.contextBudget, 64_000)
        XCTAssertFalse(info.supportsPromptCaching)
        XCTAssertFalse(info.isLocal)
    }

    /// The registry's only durable copy used to be the purgeable Caches JSON,
    /// restored by an unawaited task at launch — so the first resolve after a
    /// relaunch could hand a persisted live pick the 128K fallback. Budgets
    /// now also persist to UserDefaults and seed the registry synchronously
    /// on first access.
    func testRegisteredBudgetsSurviveARegistryReset() {
        let id = "acme/persisted-\(UUID().uuidString)"
        ProviderCatalog.registerOpenRouterModels([
            OpenRouterModel(
                id: id, name: "Acme Persisted", contextLength: 96_000,
                promptUSDPerMillion: 0.1, completionUSDPerMillion: 0.2
            ),
        ])
        // Drop the in-memory map only — what a relaunch does.
        ProviderCatalog.resetOpenRouterBudgetsForTesting(clearingPersisted: false)
        let info = ProviderCatalog.resolve(modelID: id, for: .openRouter)
        XCTAssertEqual(info.contextBudget, 96_000, "the persisted map seeds the registry on first access")

        // And the persisted map is what a relaunch reads.
        let persisted = UserDefaults.standard.dictionary(forKey: ProviderCatalog.openRouterContextLengthsKey) as? [String: Int]
        XCTAssertEqual(persisted?[id], 96_000)

        ProviderCatalog.resetOpenRouterBudgetsForTesting(clearingPersisted: true)
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: id, for: .openRouter).contextBudget, 128_000,
            "with nothing persisted the fallback applies again"
        )
    }

    func testResolveCapsARegisteredBudgetAtTheRouterCeiling() {
        let id = "acme/huge-\(UUID().uuidString)"
        ProviderCatalog.registerOpenRouterModels([
            OpenRouterModel(
                id: id, name: "Acme Huge", contextLength: 1_048_576,
                promptUSDPerMillion: 0, completionUSDPerMillion: 0
            ),
        ])
        XCTAssertEqual(ProviderCatalog.resolve(modelID: id, for: .openRouter).contextBudget, 200_000)
    }

    func testResolveDefaultsAnUnregisteredOpenRouterIDTo128K() {
        let info = ProviderCatalog.resolve(modelID: "acme/never-registered-\(UUID().uuidString)", for: .openRouter)
        XCTAssertEqual(info.contextBudget, 128_000)
        XCTAssertTrue(info.modelID.hasPrefix("acme/never-registered-"))
    }

    func testResolveStillFallsBackForAnUnknownAnthropicID() {
        let info = ProviderCatalog.resolve(modelID: "claude-imaginary-9", for: .anthropic)
        XCTAssertEqual(info, ProviderCatalog.defaultModel(for: .anthropic))
    }

    func testResolveWithNoModelIDGivesTheOpenRouterDefault() {
        XCTAssertEqual(
            ProviderCatalog.resolve(modelID: nil, for: .openRouter),
            ProviderCatalog.defaultModel(for: .openRouter)
        )
    }
}
