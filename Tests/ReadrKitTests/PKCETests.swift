import XCTest
@testable import ReadrKit

final class PKCETests: XCTestCase {

    /// The unreserved character set permitted for a verifier (RFC 7636 §4.1).
    private let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 7636 Appendix B test vector: a known verifier maps to a known challenge.
    func testRFC7636AppendixBVector() {
        let pkce = PKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.codeChallenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    /// A generated verifier is the correct length and uses only unreserved chars.
    func testGeneratedVerifierIsValid() {
        for _ in 0..<50 {
            let verifier = PKCE().codeVerifier
            XCTAssertTrue((43...128).contains(verifier.count), "length \(verifier.count) out of range")
            XCTAssertTrue(verifier.allSatisfy { unreserved.contains($0) }, "non-unreserved char in \(verifier)")
        }
    }

    /// `randomState()` should be unpredictable: distinct across calls.
    func testRandomStateIsDistinct() {
        var seen = Set<String>()
        for _ in 0..<100 {
            seen.insert(PKCE.randomState())
        }
        XCTAssertEqual(seen.count, 100, "randomState produced collisions")
    }

    /// base64url output must not contain padding or non-URL-safe characters.
    func testBase64URLEncodeIsURLSafe() {
        // 0xFB 0xFF round-trips through both '+' (0x3E) and '/' (0x3F) positions
        // in standard base64, and a 2-byte input forces padding.
        let data = Data([0xFB, 0xFF])
        let encoded = PKCE.base64URLEncode(data)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))

        // Sweep a range of byte patterns to be safe.
        for byte in 0...255 {
            let out = PKCE.base64URLEncode(Data([UInt8(byte), UInt8((byte * 7) % 256)]))
            XCTAssertFalse(out.contains("="))
            XCTAssertFalse(out.contains("+"))
            XCTAssertFalse(out.contains("/"))
        }
    }
}
