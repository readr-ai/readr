import XCTest
@testable import ReadrKit

final class ProviderManagerTests: XCTestCase {

    /// A factory that produces `MockLLMProvider`s, preserving the resolved
    /// `ProviderInfo` (including `isLocal`), and capturing the credentials it
    /// was handed so tests can assert on them.
    private final class CapturingFactory: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lastCredentials: Credentials?
        private(set) var callCount = 0

        var make: ProviderManager.ProviderFactory {
            { [weak self] info, credentials in
                if let self {
                    self.lock.lock()
                    self.lastCredentials = credentials
                    self.callCount += 1
                    self.lock.unlock()
                }
                return MockLLMProvider(info: info)
            }
        }
    }

    private func makeManager(
        store: FakeCredentialStore,
        factory: CapturingFactory
    ) -> ProviderManager {
        ProviderManager(store: store, factory: factory.make)
    }

    // MARK: - Configuration

    func testIsConfiguredWithEmptyStore() {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        XCTAssertTrue(manager.isConfigured(.local))
        XCTAssertFalse(manager.isConfigured(.anthropic))
        XCTAssertFalse(manager.isConfigured(.openAI))
    }

    func testNoSelectionReturnsNilProvider() throws {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        XCTAssertNil(try manager.activeProvider())
    }

    // MARK: - Local selection

    func testLocalSelectionProducesLocalProvider() throws {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        manager.setActive(kind: .local)
        let provider = try manager.activeProvider()

        XCTAssertNotNil(provider)
        XCTAssertTrue(provider?.info.isLocal == true)
        // No credentials are loaded for local providers.
        XCTAssertNil(factory.lastCredentials)
    }

    // MARK: - On-device model

    /// Stands in for the app's Foundation Models provider: no credentials,
    /// and a readiness it reports itself.
    private final class OnDeviceProvider: LLMProvider, OnDeviceReadinessReporting, @unchecked Sendable {
        let info: ProviderInfo
        let report: OnDeviceReadiness
        init(info: ProviderInfo, report: OnDeviceReadiness) {
            self.info = info
            self.report = report
        }
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func countTokens(_ text: String) throws -> Int { max(1, text.count / 4) }
        func readiness() async -> OnDeviceReadiness { report }
    }

    private func makeOnDeviceManager(reporting report: OnDeviceReadiness) -> ProviderManager {
        ProviderManager(store: FakeCredentialStore(), factory: { info, credentials in
            XCTAssertNil(credentials, "the on-device model takes no credentials")
            return OnDeviceProvider(info: info, report: report)
        })
    }

    func testTheOnDeviceModelIsConfiguredBeforeAnyCheck() {
        let manager = makeOnDeviceManager(reporting: .ready)
        XCTAssertTrue(manager.isConfigured(.appleIntelligence))
        XCTAssertFalse(manager.hasStoredCredential(.appleIntelligence))
        XCTAssertTrue(manager.availableKinds().contains(.appleIntelligence))
    }

    func testAReadyOnDeviceModelValidatesActive() async throws {
        let manager = makeOnDeviceManager(reporting: .ready)
        manager.setActive(kind: .appleIntelligence)
        let state = await manager.validate(.appleIntelligence)
        XCTAssertEqual(state, .active)
        XCTAssertTrue(try manager.activeProvider()?.info.isLocal == true)
    }

    /// Apple Intelligence switched off, or the model still downloading: the
    /// reader can fix it, so the card explains and Ask stays optimistic.
    func testAnOnDeviceModelTheReaderCanEnableIsUnavailableNotInvalid() async throws {
        let manager = makeOnDeviceManager(
            reporting: .unavailable(reason: "Turn on Apple Intelligence in Settings.")
        )
        manager.setActive(kind: .appleIntelligence)
        let state = await manager.validate(.appleIntelligence)
        XCTAssertEqual(state, .unavailable(reason: "Turn on Apple Intelligence in Settings."))
        XCTAssertFalse(manager.isConfigured(.appleIntelligence))
        XCTAssertNotNil(try manager.activeProvider(), "a transient state must not block Ask")
    }

    /// A device or OS that can never run it: proven unusable, so the
    /// selection must not resolve to a provider that will only fail.
    func testAnUnsupportedOnDeviceModelIsInvalidAndBlocksTheProvider() async {
        let manager = makeOnDeviceManager(
            reporting: .unsupported(reason: "This device can't run the on-device model.")
        )
        manager.setActive(kind: .appleIntelligence)
        let state = await manager.validate(.appleIntelligence)
        XCTAssertEqual(state, .invalid(reason: "This device can't run the on-device model."))
        XCTAssertThrowsError(try manager.activeProvider()) {
            XCTAssertEqual(
                $0 as? ProviderManager.ProviderError, .notConfigured(.appleIntelligence)
            )
        }
    }

    // MARK: - Remote selection

    func testAnthropicSelectionPassesCredentialsToFactory() throws {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        try store.save(.apiKey("sk-test-123"), for: .anthropic)
        manager.setActive(kind: .anthropic)

        let provider = try manager.activeProvider()

        XCTAssertNotNil(provider)
        XCTAssertEqual(factory.lastCredentials, .apiKey("sk-test-123"))
        XCTAssertEqual(provider?.info.kind, .anthropic)
    }

    func testOpenAIWithoutCredentialsThrowsNotConfigured() {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        manager.setActive(kind: .openAI)

        XCTAssertThrowsError(try manager.activeProvider()) { error in
            XCTAssertEqual(
                error as? ProviderManager.ProviderError,
                .notConfigured(.openAI)
            )
        }
    }

    // MARK: - Available kinds

    func testAvailableKindsReflectStoredCredentials() throws {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        // The on-device kinds are always available even with an empty store.
        XCTAssertEqual(manager.availableKinds(), [.local, .appleIntelligence])

        try store.save(.apiKey("sk-anthropic"), for: .anthropic)
        XCTAssertEqual(Set(manager.availableKinds()), Set([.anthropic, .local, .appleIntelligence]))

        try store.save(.apiKey("sk-openai"), for: .openAI)
        XCTAssertEqual(
            Set(manager.availableKinds()),
            Set([.anthropic, .openAI, .local, .appleIntelligence])
        )

        // The sign-in kinds surface once their credentials exist: OpenRouter
        // stores the key its PKCE exchange returns, ChatGPT stores OAuth tokens.
        try store.save(.apiKey("sk-or-key"), for: .openRouter)
        try store.save(
            .oauth(accessToken: "at", refreshToken: "rt", expiresAt: nil), for: .chatGPT
        )
        XCTAssertEqual(
            Set(manager.availableKinds()),
            Set([.anthropic, .openAI, .openRouter, .chatGPT, .local, .appleIntelligence])
        )
    }

    // MARK: - Stored-credential check

    /// `hasStoredCredential` reports what's in the store, independent of
    /// validation state — so a key that fails a live check can still be
    /// disconnected and its model changed (the card would otherwise dead-end).
    func testHasStoredCredentialIgnoresValidationState() async throws {
        /// Always fails its credential check with a plain rate limit.
        struct RateLimited: LLMProvider, CredentialValidating {
            let info = ProviderInfo.fixture(kind: .openAI)
            func validateCredential() async throws {
                throw HTTPError.status(429, body: #"{"code":"rate_limit_exceeded"}"#)
            }
            func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
                AsyncThrowingStream { $0.finish() }
            }
            func countTokens(_ text: String) throws -> Int { 1 }
        }

        let store = FakeCredentialStore()
        let manager = ProviderManager(store: store, factory: { _, _ in RateLimited() })

        XCTAssertFalse(manager.hasStoredCredential(.openAI))
        try store.save(.apiKey("sk-x"), for: .openAI)
        XCTAssertTrue(manager.hasStoredCredential(.openAI))

        // A failed live check must not hide the stored credential — otherwise
        // the settings card loses Disconnect and the model picker.
        _ = await manager.validate(.openAI)
        XCTAssertFalse(manager.isConfigured(.openAI), "isConfigured still tracks verification")
        XCTAssertTrue(manager.hasStoredCredential(.openAI), "the key is still there to remove")

        // Local never stores credentials.
        XCTAssertFalse(manager.hasStoredCredential(.local))
    }

    // MARK: - Validation freshness

    /// Counts credential checks so tests can assert probes are skipped.
    private final class CountingValidator: LLMProvider, CredentialValidating, @unchecked Sendable {
        let info = ProviderInfo.fixture(kind: .openAI)
        private let lock = NSLock()
        private var _checks = 0
        private let failure: Error?
        var checks: Int { lock.lock(); defer { lock.unlock() }; return _checks }

        init(failure: Error? = nil) { self.failure = failure }

        func validateCredential() async throws {
            lock.lock(); _checks += 1; lock.unlock()
            if let failure { throw failure }
        }
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func countTokens(_ text: String) throws -> Int { 1 }
    }

    private func makeClockedManager(
        store: FakeCredentialStore,
        provider: LLMProvider,
        now: @escaping @Sendable () -> Date
    ) -> ProviderManager {
        ProviderManager(store: store, factory: { _, _ in provider }, now: now)
    }

    /// The probe now costs a token, so a provider verified moments ago isn't
    /// re-checked when the settings sheet reopens.
    func testFreshSuccessIsNotRevalidated() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-x"), for: .openAI)
        let provider = CountingValidator()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let manager = makeClockedManager(store: store, provider: provider, now: clock.read)

        await manager.validateIfStale(.openAI, maxAge: 300)
        XCTAssertEqual(provider.checks, 1)

        clock.advance(by: 60)
        await manager.validateIfStale(.openAI, maxAge: 300)
        XCTAssertEqual(provider.checks, 1, "still fresh — no second probe")
    }

    func testStaleSuccessIsRevalidated() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-x"), for: .openAI)
        let provider = CountingValidator()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let manager = makeClockedManager(store: store, provider: provider, now: clock.read)

        await manager.validateIfStale(.openAI, maxAge: 300)
        clock.advance(by: 301)
        await manager.validateIfStale(.openAI, maxAge: 300)
        XCTAssertEqual(provider.checks, 2)
    }

    /// Failures are never cached: the reader may have just fixed billing, and
    /// caching one would resurrect the sticky-failure bug.
    func testFailedValidationIsAlwaysRetried() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-x"), for: .openAI)
        let provider = CountingValidator(
            failure: HTTPError.status(429, body: #"{"code":"rate_limit_exceeded"}"#)
        )
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let manager = makeClockedManager(store: store, provider: provider, now: clock.read)

        await manager.validateIfStale(.openAI, maxAge: 300)
        await manager.validateIfStale(.openAI, maxAge: 300)
        XCTAssertEqual(provider.checks, 2, "a failed check must not be cached")
    }

    /// An explicit "Check again" bypasses the cache entirely.
    func testExplicitValidateIgnoresFreshness() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-x"), for: .openAI)
        let provider = CountingValidator()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let manager = makeClockedManager(store: store, provider: provider, now: clock.read)

        await manager.validateIfStale(.openAI, maxAge: 300)
        _ = await manager.validate(.openAI)
        XCTAssertEqual(provider.checks, 2)
    }

    /// Saving a new credential must invalidate the freshness stamp, or the
    /// replacement would inherit the old key's verdict unchecked.
    func testNewCredentialClearsFreshness() async throws {
        let store = FakeCredentialStore()
        try store.save(.apiKey("sk-old"), for: .openAI)
        let provider = CountingValidator()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let manager = makeClockedManager(store: store, provider: provider, now: clock.read)

        await manager.validateIfStale(.openAI, maxAge: 300)
        XCTAssertEqual(provider.checks, 1)

        try store.save(.apiKey("sk-new"), for: .openAI)
        manager.clearValidation(.openAI)
        await manager.validateIfStale(.openAI, maxAge: 300)
        XCTAssertEqual(provider.checks, 2, "a replaced key is unproven")
    }

    // MARK: - Selection model defaulting

    func testStalePersistedModelIDResolvesToSameTierReplacement() throws {
        // A catalog refresh can retire a model ID that a user's persisted
        // selection still names. Resolution must land on the SAME-TIER
        // successor — never silently jump the user to a pricier tier.
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        // Retired mid-tier Anthropic model → mid-tier successor, not Opus.
        try store.save(.apiKey("sk-test"), for: .anthropic)
        manager.setActive(kind: .anthropic, modelID: "claude-sonnet-4-6")
        XCTAssertEqual(
            try manager.activeProvider()?.info.modelID, "claude-sonnet-5",
            "A retired mid-tier selection must not resolve to the flagship"
        )

        // Retired flagship → flagship successor (same price, same context).
        manager.setActive(kind: .anthropic, modelID: "claude-opus-4-8")
        XCTAssertEqual(try manager.activeProvider()?.info.modelID, "claude-opus-5")

        // Retired cheap-tier OpenAI model → cheap-tier successor.
        try store.save(.apiKey("sk-test"), for: .openAI)
        manager.setActive(kind: .openAI, modelID: "gpt-4.1-mini")
        XCTAssertEqual(try manager.activeProvider()?.info.modelID, "gpt-5.6-luna")

        // Retired flagship → flagship successor (also the default).
        manager.setActive(kind: .openAI, modelID: "gpt-4.1")
        XCTAssertEqual(try manager.activeProvider()?.info.modelID, "gpt-5.6-sol")
    }

    func testUnknownPersistedModelIDResolvesToCatalogDefault() throws {
        // An ID with no legacy mapping (corrupt data, far-future write-back)
        // still falls back to the kind's default rather than failing.
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        try store.save(.apiKey("sk-test"), for: .openAI)
        manager.setActive(kind: .openAI, modelID: "not-a-model")
        XCTAssertEqual(
            try manager.activeProvider()?.info.modelID,
            ProviderCatalog.defaultModel(for: .openAI).modelID
        )
    }

    func testSetActiveDefaultsToCatalogDefaultModel() {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        manager.setActive(kind: .anthropic)
        XCTAssertEqual(
            manager.selection?.modelID,
            ProviderCatalog.defaultModel(for: .anthropic).modelID
        )
    }

    func testSetActiveRespectsExplicitModelID() {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)

        manager.setActive(kind: .local, modelID: "qwen2.5")
        XCTAssertEqual(manager.selection?.modelID, "qwen2.5")
    }

    // MARK: - Catalog

    func testCatalogModelsForKindNonEmpty() {
        XCTAssertFalse(ProviderCatalog.models(for: .anthropic).isEmpty)
        XCTAssertFalse(ProviderCatalog.models(for: .openAI).isEmpty)
        XCTAssertFalse(ProviderCatalog.models(for: .local).isEmpty)
    }

    func testCatalogAllCountEqualsSum() {
        let expected = ProviderCatalog.anthropicModels.count
            + ProviderCatalog.openAIModels.count
            + ProviderCatalog.chatGPTModels.count
            + ProviderCatalog.openRouterModels.count
            + ProviderCatalog.localModels.count
            + ProviderCatalog.appleIntelligenceModels.count
        XCTAssertEqual(ProviderCatalog.all.count, expected)
    }

    func testCatalogDefaultLocalModelIsLocal() {
        XCTAssertTrue(ProviderCatalog.defaultModel(for: .local).isLocal)
    }

    // MARK: - Codable

    func testProviderSelectionRoundTripsThroughJSON() throws {
        let selection = ProviderSelection(kind: .openAI, modelID: "gpt-4.1")
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(ProviderSelection.self, from: data)
        XCTAssertEqual(decoded, selection)
    }

    // MARK: - Selection persistence

    /// An isolated defaults suite per test, cleaned up afterwards.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "ProviderManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testSetActivePersistsSelectionAcrossManagers() throws {
        let defaults = try makeDefaults()
        let store = FakeCredentialStore()
        let factory = CapturingFactory()

        let first = ProviderManager(
            store: store, factory: factory.make, persistingIn: defaults
        )
        first.setActive(kind: .anthropic, modelID: "claude-x")

        // A relaunch constructs a fresh manager over the same defaults.
        let second = ProviderManager(
            store: store, factory: factory.make, persistingIn: defaults
        )
        XCTAssertEqual(
            second.selection,
            ProviderSelection(kind: .anthropic, modelID: "claude-x")
        )
    }

    func testExplicitSelectionBeatsPersistedOne() throws {
        let defaults = try makeDefaults()
        let store = FakeCredentialStore()
        let factory = CapturingFactory()

        ProviderManager(store: store, factory: factory.make, persistingIn: defaults)
            .setActive(kind: .openAI)

        let explicit = ProviderSelection(kind: .local, modelID: "llama3")
        let manager = ProviderManager(
            store: store, factory: factory.make,
            selection: explicit, persistingIn: defaults
        )
        XCTAssertEqual(manager.selection, explicit)
    }

    func testNoDefaultsMeansNoPersistence() {
        let store = FakeCredentialStore()
        let factory = CapturingFactory()
        let manager = makeManager(store: store, factory: factory)
        manager.setActive(kind: .anthropic)

        let fresh = makeManager(store: store, factory: factory)
        XCTAssertNil(fresh.selection)
    }

    func testCorruptPersistedSelectionIsIgnored() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: ProviderManager.selectionDefaultsKey)

        let manager = ProviderManager(
            store: FakeCredentialStore(),
            factory: CapturingFactory().make,
            persistingIn: defaults
        )
        XCTAssertNil(manager.selection)
    }
}
