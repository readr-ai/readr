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
        // CryptoKit is available on all of ReadrKit's shipping platforms
        // (iOS/macOS) and is always preferred above. This portable FIPS 180-4
        // implementation exists for platforms without CryptoKit — Linux CI —
        // so the package's tests (including the RFC 7636 Appendix B vector,
        // which verifies this digest) can run everywhere.
        return sha256Portable(data)
        #endif
    }

    /// Pure-Swift SHA-256 (FIPS 180-4). Compiled only where CryptoKit is
    /// unavailable; correctness is pinned by `PKCETests.testRFC7636AppendixBVector`.
    static func sha256Portable(_ data: Data) -> Data {
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
            0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
            0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
            0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
            0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]

        // Pad: append 0x80, zeros to 56 mod 64, then the bit length (big-endian).
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let o = chunkStart + i * 4
                w[i] = (UInt32(message[o]) << 24) | (UInt32(message[o + 1]) << 16)
                    | (UInt32(message[o + 2]) << 8) | UInt32(message[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }

        var digest = Data(capacity: 32)
        for value in h {
            digest.append(UInt8(truncatingIfNeeded: value >> 24))
            digest.append(UInt8(truncatingIfNeeded: value >> 16))
            digest.append(UInt8(truncatingIfNeeded: value >> 8))
            digest.append(UInt8(truncatingIfNeeded: value))
        }
        return digest
    }

    /// Return `count` cryptographically random bytes.
    private static func randomBytes(count: Int) -> Data {
        #if canImport(Security)
        var secureBytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &secureBytes) == errSecSuccess {
            return Data(secureBytes)
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
