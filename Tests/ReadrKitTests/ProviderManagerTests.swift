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

        // Local is always available even with an empty store.
        XCTAssertEqual(manager.availableKinds(), [.local])

        try store.save(.apiKey("sk-anthropic"), for: .anthropic)
        XCTAssertEqual(Set(manager.availableKinds()), Set([.anthropic, .local]))

        try store.save(.apiKey("sk-openai"), for: .openAI)
        XCTAssertEqual(
            Set(manager.availableKinds()),
            Set([.anthropic, .openAI, .local])
        )

        // The sign-in kinds surface once their credentials exist: OpenRouter
        // stores the key its PKCE exchange returns, ChatGPT stores OAuth tokens.
        try store.save(.apiKey("sk-or-key"), for: .openRouter)
        try store.save(
            .oauth(accessToken: "at", refreshToken: "rt", expiresAt: nil), for: .chatGPT
        )
        XCTAssertEqual(
            Set(manager.availableKinds()),
            Set([.anthropic, .openAI, .openRouter, .chatGPT, .local])
        )
    }

    // MARK: - Selection model defaulting

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
