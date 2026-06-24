import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Proof Key for Code Exchange (RFC 7636) helper.
///
/// Holds a high-entropy `codeVerifier` and derives the matching S256
/// `codeChallenge`. The challenge is sent on the authorization request; the
/// verifier is sent on the token exchange so the server can confirm both halves
/// originated from the same client.
public struct PKCE: Sendable, Equatable {
    /// The plaintext verifier: 43–128 characters from the unreserved set
    /// `[A-Z a-z 0-9 - . _ ~]` (RFC 7636 §4.1).
    public let codeVerifier: String

    /// Generate a fresh, cryptographically random verifier.
    ///
    /// We base64url-encode 32 random bytes, which yields a 43-character string
    /// composed entirely of unreserved characters — a valid verifier.
    public init() {
        let randomBytes = PKCE.randomBytes(count: 32)
        self.codeVerifier = PKCE.base64URLEncode(randomBytes)
    }

    /// Deterministic initializer for tests / replaying a known verifier.
    public init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
    }

    /// The S256 code challenge: `base64url( SHA256(codeVerifier) )`, unpadded.
    public var codeChallenge: String {
        let digest = PKCE.sha256(Data(codeVerifier.utf8))
        return PKCE.base64URLEncode(digest)
    }

    // MARK: - Encoding helpers

    /// Base64url-encode without padding (`=` removed, `+`→`-`, `/`→`_`),
    /// per RFC 7636 §A.
    public static func base64URLEncode(_ data: Data) -> String {
        var encoded = data.base64EncodedString()
        encoded = encoded.replacingOccurrences(of: "+", with: "-")
        encoded = encoded.replacingOccurrences(of: "/", with: "_")
        encoded = encoded.replacingOccurrences(of: "=", with: "")
        return encoded
    }

    /// A URL-safe random token suitable for the OAuth `state` parameter.
    public static func randomState() -> String {
        base64URLEncode(randomBytes(count: 32))
    }

    // MARK: - Crypto primitives

    private static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        // CryptoKit is available on all of ReadrKit's supported platforms
        // (iOS/macOS); this fallback exists only so the file type-checks on
        // platforms lacking CryptoKit.
        fatalError("SHA256 requires CryptoKit on this platform")
        #endif
    }

    /// Return `count` cryptographically random bytes.
    private static func randomBytes(count: Int) -> Data {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        // Fall through to the system RNG if SecRandom is unavailable.
        #endif
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max))
        }
        return Data(bytes)
    }
}
