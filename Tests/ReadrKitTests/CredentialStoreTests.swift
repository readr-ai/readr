import XCTest
@testable import ReadrKit

/// M2 — credential storage.
///
/// `InMemoryCredentialStore` is exercised directly. `KeychainCredentialStore`
/// is not tested here: the Keychain is not reliably available in a headless CI
/// environment. The JSON round-trip test below validates the encoding that the
/// Keychain store depends on.
final class CredentialStoreTests: XCTestCase {

    // MARK: - InMemoryCredentialStore

    func testSaveThenLoadReturnsAPIKey() throws {
        let store = InMemoryCredentialStore()
        try store.save(.apiKey("sk-x"), for: .anthropic)
        XCTAssertEqual(try store.load(for: .anthropic), .apiKey("sk-x"))
    }

    func testSaveThenLoadRoundTripsOAuth() throws {
        let store = InMemoryCredentialStore()
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let credentials = Credentials.oauth(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: expiry
        )
        try store.save(credentials, for: .openAI)
        XCTAssertEqual(try store.load(for: .openAI), credentials)
    }

    func testSaveOverwritesExistingCredential() throws {
        let store = InMemoryCredentialStore()
        try store.save(.apiKey("old"), for: .anthropic)
        try store.save(.apiKey("new"), for: .anthropic)
        XCTAssertEqual(try store.load(for: .anthropic), .apiKey("new"))
    }

    func testLoadForUnsavedKindReturnsNil() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.load(for: .local))
    }

    func testDeleteRemovesCredential() throws {
        let store = InMemoryCredentialStore()
        try store.save(.apiKey("sk-x"), for: .anthropic)
        try store.delete(for: .anthropic)
        XCTAssertNil(try store.load(for: .anthropic))
    }

    func testDifferentKindsAreIndependent() throws {
        let store = InMemoryCredentialStore()
        try store.save(.apiKey("anthropic-key"), for: .anthropic)
        // Saving (and deleting) one kind must not disturb another.
        XCTAssertNil(try store.load(for: .openAI))
        try store.save(.apiKey("openai-key"), for: .openAI)
        try store.delete(for: .anthropic)
        XCTAssertNil(try store.load(for: .anthropic))
        XCTAssertEqual(try store.load(for: .openAI), .apiKey("openai-key"))
    }

    // MARK: - Credentials JSON round-trip (the contract KeychainCredentialStore relies on)

    func testCredentialsJSONRoundTripAPIKey() throws {
        let original = Credentials.apiKey("sk-x")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Credentials.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCredentialsJSONRoundTripOAuth() throws {
        let original = Credentials.oauth(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Credentials.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
