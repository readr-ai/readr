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
