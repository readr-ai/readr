import XCTest
@testable import ReadrKit

/// J5 — the default factory builds the right concrete provider, and integrates
/// with ProviderManager end to end (with a mock transport).
final class DefaultProviderFactoryTests: XCTestCase {

    private let http = MockHTTPClient()

    func testLocalNeedsNoCredentials() throws {
        let info = ProviderCatalog.defaultModel(for: .local)
        let provider = try DefaultProviderFactory.make(info: info, credentials: nil, http: http)
        XCTAssertTrue(provider.info.isLocal)
        XCTAssertEqual(provider.info.kind, .local)
    }

    /// The on-device model's runtime is an Apple framework, so the app
    /// supplies it (`AppProviderFactory`); the kit's factory must refuse
    /// rather than pretend, and the catalog entry must route to retrieval
    /// (local, small budget) since the model's window is 4,096 tokens.
    func testTheOnDeviceModelIsLocalSmallAndNotBuiltByTheKitFactory() {
        let info = ProviderCatalog.defaultModel(for: .appleIntelligence)
        XCTAssertTrue(info.isLocal)
        XCTAssertFalse(info.supportsPromptCaching)
        XCTAssertLessThanOrEqual(info.contextBudget, 3_500)
        XCTAssertThrowsError(try DefaultProviderFactory.make(info: info, credentials: nil, http: http)) {
            XCTAssertEqual($0 as? ProviderManager.ProviderError, .notConfigured(.appleIntelligence))
        }
    }

    /// Android's system model reaches the kit through AICore, an Android API,
    /// so the Kotlin side supplies the provider exactly as the app does for
    /// Apple's. The catalog row must route to retrieval like every other
    /// small-window model.
    func testGeminiNanoIsLocalSmallAndNotBuiltByTheKitFactory() {
        let info = ProviderCatalog.defaultModel(for: .geminiNano)
        XCTAssertEqual(info.modelID, "gemini-nano")
        XCTAssertEqual(info.name, "Gemini Nano")
        XCTAssertTrue(info.isLocal)
        XCTAssertFalse(info.supportsPromptCaching)
        XCTAssertLessThanOrEqual(info.contextBudget, 3_500)
        XCTAssertThrowsError(try DefaultProviderFactory.make(info: info, credentials: nil, http: http)) {
            XCTAssertEqual($0 as? ProviderManager.ProviderError, .notConfigured(.geminiNano))
        }
    }

    /// The refusal is a sentence a reader on that phone can act on — never a
    /// mention of a framework or a factory.
    func testTheGeminiNanoRefusalReadsAsASentence() {
        XCTAssertEqual(
            ProviderManager.ProviderError.notConfigured(.geminiNano).errorDescription,
            "Gemini Nano isn't available on this phone."
        )
    }

    /// A kind is persisted by raw value, so the existing six must keep
    /// decoding — a stored selection outlives any catalog change.
    func testKindRawValuesAreStableAndTheNewOneIsAdditive() throws {
        let stored = #"["anthropic","openAI","chatGPT","openRouter","local","appleIntelligence","geminiNano"]"#

        XCTAssertEqual(
            try JSONDecoder().decode([ProviderInfo.Kind].self, from: Data(stored.utf8)),
            [.anthropic, .openAI, .chatGPT, .openRouter, .local, .appleIntelligence, .geminiNano]
        )
        XCTAssertEqual(ProviderInfo.Kind.geminiNano.rawValue, "geminiNano")
    }

    func testAnthropicBuildsWithCredentials() throws {
        let info = ProviderCatalog.defaultModel(for: .anthropic)
        let provider = try DefaultProviderFactory.make(
            info: info, credentials: .apiKey("sk-test"), http: http
        )
        XCTAssertEqual(provider.info.kind, .anthropic)
        XCTAssertFalse(provider.info.isLocal)
    }

    func testHostedWithoutCredentialsThrows() {
        let info = ProviderCatalog.defaultModel(for: .openAI)
        XCTAssertThrowsError(try DefaultProviderFactory.make(info: info, credentials: nil, http: http)) {
            XCTAssertEqual($0 as? ProviderManager.ProviderError, .notConfigured(.openAI))
        }
    }

    func testOpenRouterBuildsWithCredentials() throws {
        let info = ProviderCatalog.defaultModel(for: .openRouter)
        let provider = try DefaultProviderFactory.make(
            info: info, credentials: .apiKey("sk-or-test"), http: http
        )
        XCTAssertEqual(provider.info.kind, .openRouter)
        XCTAssertFalse(provider.info.isLocal)
    }

    func testOpenRouterWithoutCredentialsThrows() {
        let info = ProviderCatalog.defaultModel(for: .openRouter)
        XCTAssertThrowsError(try DefaultProviderFactory.make(info: info, credentials: nil, http: http)) {
            XCTAssertEqual($0 as? ProviderManager.ProviderError, .notConfigured(.openRouter))
        }
    }

    func testChatGPTBuildsWithOAuthCredentials() throws {
        let info = ProviderCatalog.defaultModel(for: .chatGPT)
        let provider = try DefaultProviderFactory.make(
            info: info,
            credentials: .oauth(accessToken: "at", refreshToken: "rt", expiresAt: nil),
            http: http
        )
        XCTAssertEqual(provider.info.kind, .chatGPT)
    }

    func testChatGPTRejectsAPIKeyCredentials() {
        let info = ProviderCatalog.defaultModel(for: .chatGPT)
        XCTAssertThrowsError(
            try DefaultProviderFactory.make(info: info, credentials: .apiKey("sk-x"), http: http)
        ) {
            XCTAssertEqual($0 as? ProviderManager.ProviderError, .notConfigured(.chatGPT))
        }
    }

    func testIntegratesWithProviderManager() throws {
        let store = FakeCredentialStore()
        let manager = ProviderManager(store: store, factory: DefaultProviderFactory.factory(http: http))

        // Local works with no credentials.
        manager.setActive(kind: .local)
        XCTAssertTrue(try XCTUnwrap(manager.activeProvider()).info.isLocal)

        // Anthropic requires stored credentials.
        try store.save(.apiKey("sk-test"), for: .anthropic)
        manager.setActive(kind: .anthropic)
        XCTAssertEqual(try XCTUnwrap(manager.activeProvider()).info.kind, .anthropic)
    }
}
