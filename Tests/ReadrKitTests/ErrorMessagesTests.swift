import XCTest
@testable import ReadrKit

/// Provider and transport errors surface directly in the Ask panel and
/// Article Studio via `localizedDescription`, so each case must read as an
/// actionable sentence — not Foundation's "The operation couldn't be
/// completed. (ReadrKit.HTTPError error 0.)".
final class ErrorMessagesTests: XCTestCase {

    // MARK: HTTPError

    func testUnauthorizedPointsAtTheAPIKey() {
        let message = HTTPError.status(401, body: "").localizedDescription
        XCTAssertTrue(message.localizedCaseInsensitiveContains("API key"), message)
        // The status code moved to `diagnosticSummary` — see
        // PlainLanguageErrorTests. A reader can't act on "401" (#48).
        XCTAssertTrue(HTTPError.status(401, body: "").diagnosticSummary.contains("401"))
    }

    func testForbiddenPointsAtTheAPIKey() {
        let message = HTTPError.status(403, body: "").localizedDescription
        XCTAssertTrue(message.localizedCaseInsensitiveContains("API key"), message)
    }

    /// "Rate-limited" is jargon; what the reader needs is that they asked too
    /// fast and that waiting fixes it (#48).
    func testRateLimitSaysTooFastAndTryAgain() {
        let message = HTTPError.status(429, body: "").localizedDescription
        XCTAssertTrue(message.localizedCaseInsensitiveContains("faster"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("try again"), message)
    }

    func testBadRequestMentionsSize() {
        // The usual real-world 400 is a prompt over the model's context limit
        // (chars/4 token estimate under-counts dense text).
        let message = HTTPError.status(400, body: "").localizedDescription
        XCTAssertTrue(message.localizedCaseInsensitiveContains("too large"), message)
    }

    func testServerErrorSaysProviderTrouble() {
        for code in [500, 503, 529] {
            let error = HTTPError.status(code, body: "")
            let message = error.localizedDescription
            XCTAssertTrue(message.localizedCaseInsensitiveContains("provider"), message)
            // The code is triage detail, not reader-facing copy (#48).
            XCTAssertTrue(error.diagnosticSummary.contains("\(code)"), error.diagnosticSummary)
        }
    }

    /// An unrecognised status still has to produce a real sentence rather than
    /// Foundation's default — it just no longer recites the number (#48).
    func testUnknownStatusStillReadsAsASentence() {
        let error = HTTPError.status(418, body: "")
        let message = error.localizedDescription
        XCTAssertFalse(message.contains("operation couldn't be completed"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("provider"), message)
        XCTAssertTrue(error.diagnosticSummary.contains("418"), error.diagnosticSummary)
    }

    func testProviderSuppliedDetailIsIncluded() {
        let message = HTTPError.status(401, body: "invalid x-api-key").localizedDescription
        XCTAssertTrue(message.contains("invalid x-api-key"), message)
    }

    func testOverlongBodyIsTruncated() {
        let long = String(repeating: "x", count: 500)
        let message = HTTPError.status(500, body: long).localizedDescription
        XCTAssertLessThan(message.count, 400, message)
    }

    func testNonHTTPResponseMentionsConnection() {
        let message = HTTPError.nonHTTPResponse.localizedDescription
        XCTAssertTrue(message.localizedCaseInsensitiveContains("connection"), message)
    }

    // MARK: ProviderManager.ProviderError

    func testNotConfiguredNamesTheProviderAndTheFix() {
        let message = ProviderManager.ProviderError
            .notConfigured(.anthropic).localizedDescription
        XCTAssertTrue(message.contains("Claude"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("API key"), message)

        let openAI = ProviderManager.ProviderError
            .notConfigured(.openAI).localizedDescription
        XCTAssertTrue(openAI.contains("OpenAI"), openAI)
        XCTAssertTrue(openAI.localizedCaseInsensitiveContains("API key"), openAI)

        // ChatGPT is the subscription path — its fix is signing in, not a key.
        let chatGPT = ProviderManager.ProviderError
            .notConfigured(.chatGPT).localizedDescription
        XCTAssertTrue(chatGPT.contains("ChatGPT"), chatGPT)
        XCTAssertTrue(chatGPT.localizedCaseInsensitiveContains("sign in"), chatGPT)
        XCTAssertFalse(chatGPT.localizedCaseInsensitiveContains("API key"), chatGPT)

        let openRouter = ProviderManager.ProviderError
            .notConfigured(.openRouter).localizedDescription
        XCTAssertTrue(openRouter.contains("OpenRouter"), openRouter)
    }

    // MARK: 429 — quota exhaustion vs rate limiting

    /// OpenAI returns 429 for two opposite conditions. A rate limit clears on
    /// its own; an exhausted quota never does, so "try again" is wrong advice.
    func testRateLimitSaysWaitButQuotaExhaustionSaysBilling() {
        let rateLimited = HTTPError
            .status(429, body: #"{"error":{"code":"rate_limit_exceeded"}}"#)
            .localizedDescription
        XCTAssertTrue(rateLimited.localizedCaseInsensitiveContains("try again"), rateLimited)

        let outOfQuota = HTTPError.status(
            429,
            body: #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota"}}"#
        ).localizedDescription
        XCTAssertTrue(outOfQuota.localizedCaseInsensitiveContains("billing"), outOfQuota)
        XCTAssertFalse(
            outOfQuota.localizedCaseInsensitiveContains("try again"),
            "waiting never clears an exhausted quota: \(outOfQuota)"
        )
    }

    func testQuotaExhaustionDetection() {
        XCTAssertTrue(HTTPError.indicatesQuotaExhausted(#"{"type":"insufficient_quota"}"#))
        XCTAssertTrue(HTTPError.indicatesQuotaExhausted("You exceeded your current quota"))
        XCTAssertFalse(HTTPError.indicatesQuotaExhausted(#"{"code":"rate_limit_exceeded"}"#))
        XCTAssertFalse(HTTPError.indicatesQuotaExhausted(""))
    }

    func testLocalMismatchIsReadable() {
        let message = ProviderManager.ProviderError.localMismatch.localizedDescription
        XCTAssertFalse(message.contains("operation couldn't be completed"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("model"), message)
    }
}
