import Foundation

/// Credentials for a connected provider. Persisted only in the Keychain.
public enum Credentials: Sendable, Equatable {
    case apiKey(String)
    case oauth(accessToken: String, refreshToken: String?, expiresAt: Date?)

    public var isExpired: Bool {
        if case let .oauth(_, _, expiresAt?) = self {
            return expiresAt <= Date()
        }
        return false
    }
}

/// Performs a sign-in and yields `Credentials`.
/// Implementations (M2): `OpenAIOAuthProvider`, `AnthropicOAuthProvider`
/// (browser OAuth + PKCE, see docs/AUTH.md) and `APIKeyProvider`.
public protocol AuthProvider: Sendable {
    var kind: ProviderInfo.Kind { get }
    /// Run the sign-in flow (opens a browser for OAuth, no-op for API keys).
    func authenticate() async throws -> Credentials
    /// Refresh an expired OAuth credential; throws if re-auth is required.
    func refresh(_ credentials: Credentials) async throws -> Credentials
}

/// Keychain-backed credential storage. The only place secrets are persisted.
public protocol CredentialStore: Sendable {
    func save(_ credentials: Credentials, for kind: ProviderInfo.Kind) throws
    func load(for kind: ProviderInfo.Kind) throws -> Credentials?
    func delete(for kind: ProviderInfo.Kind) throws
}

public enum AuthError: Error, Sendable {
    case userCancelled
    case stateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed
    case reauthenticationRequired
}
