import XCTest
@testable import ReadrKit

/// Errors must read like a person wrote them (#48).
///
/// The messages were already actionable prose, but they still carried the
/// wire detail into the reader's face: "(HTTP 401)" and a `Details:` dump of
/// the provider's raw JSON envelope. A reader can't act on a status code, and
/// the envelope is noise wrapped around the one sentence that matters.
///
/// The codes aren't thrown away — they move to `diagnosticSummary`, which is
/// what a bug report attaches. These pin the split: prose for the reader,
/// wire detail for the log.
final class PlainLanguageErrorTests: XCTestCase {

    // MARK: - No wire detail in the reader-facing sentence

    func testNoStatusCodeLeaksIntoAnyMessage() {
        for code in [400, 401, 403, 413, 418, 429, 500, 503, 529] {
            let message = HTTPError.status(code, body: "").localizedDescription
            XCTAssertFalse(
                message.localizedCaseInsensitiveContains("HTTP"),
                "status \(code) still shows the protocol to the reader: \(message)"
            )
            XCTAssertFalse(
                message.contains("\(code)"),
                "status \(code) still shows its code to the reader: \(message)"
            )
        }
    }

    func testRawJSONEnvelopeIsNeverShownToTheReader() {
        let body = #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        let message = HTTPError.status(401, body: body).localizedDescription

        XCTAssertFalse(message.contains("{"), message)
        XCTAssertFalse(message.contains("\"error\""), message)
        XCTAssertFalse(message.localizedCaseInsensitiveContains("invalid_request_error"), message)
        XCTAssertFalse(message.contains("Details:"), message)
    }

    /// The useful sentence inside the envelope still reaches the reader — that
    /// is why the raw body was being appended in the first place.
    func testReadableProviderMessageSurvivesTheEnvelope() {
        let body = #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}"#
        let message = HTTPError.status(401, body: body).localizedDescription
        XCTAssertTrue(message.contains("Incorrect API key provided."), message)
    }

    func testUnreadableBodyIsDroppedRatherThanShown() {
        for body in ["", "  ", "<html><body>502 Bad Gateway</body></html>", "{}"] {
            let message = HTTPError.status(500, body: body).localizedDescription
            XCTAssertFalse(message.contains("<"), message)
            XCTAssertFalse(message.contains("{"), message)
            XCTAssertFalse(message.hasSuffix(":"), message)
        }
    }

    // MARK: - Secrets never ride along

    /// Providers echo the rejected key back in the message. It is invalid by
    /// definition here, but it is still a credential, and this string lands in
    /// bug reports — CLAUDE.md: secrets never in logs.
    func testAPIKeysAreRedactedFromProviderDetail() {
        let body = #"{"error":{"message":"Incorrect API key provided: sk-proj-AbC123dEf456GhI789jKl. Check your key."}}"#
        let message = HTTPError.status(401, body: body).localizedDescription

        XCTAssertFalse(message.contains("sk-proj-AbC123dEf456GhI789jKl"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("redacted"), message)
        XCTAssertTrue(message.contains("Check your key."), message)
    }

    func testRedactionCoversTheCommonKeyShapes() {
        for key in [
            "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
            "sk-abcdefghijklmnopqrstuvwxyz012345",
            "Bearer abcdefghijklmnopqrstuvwxyz012345",
        ] {
            let redacted = HTTPError.redactingSecrets(in: "key was \(key) here")
            XCTAssertFalse(redacted.contains(key), "not redacted: \(redacted)")
        }
    }

    /// Redaction must not eat ordinary prose.
    func testRedactionLeavesNormalSentencesAlone() {
        let sentence = "Your account is out of credit. Add a payment method to continue."
        XCTAssertEqual(HTTPError.redactingSecrets(in: sentence), sentence)
    }

    // MARK: - Every message still reads as plain language

    func testEveryMessageIsASentenceAReaderCanActOn() {
        let cases: [HTTPError] = [
            .status(401, body: ""), .status(429, body: ""), .status(400, body: ""),
            .status(500, body: ""), .status(418, body: ""), .nonHTTPResponse,
            .transport(.timedOut), .transport(.notConnectedToInternet),
        ]
        for error in cases {
            let message = error.localizedDescription
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(
                message.contains("operation couldn't be completed"),
                message
            )
            XCTAssertTrue(
                message.hasSuffix(".") || message.hasSuffix("?"),
                "not a sentence: \(message)"
            )
        }
    }

    /// The transport fallback used to end in a bare `URLError` code number.
    func testTransportFallbackDoesNotShowAnErrorNumber() {
        let message = HTTPError.transport(.badServerResponse).localizedDescription
        XCTAssertFalse(message.contains("-1011"), message)
        XCTAssertFalse(
            message.rangeOfCharacter(from: .decimalDigits) != nil,
            "a raw error number reached the reader: \(message)"
        )
    }

    // MARK: - The wire detail survives, for diagnostics

    /// #41 attaches this to bug reports; triage needs the code the reader
    /// never sees.
    func testDiagnosticSummaryKeepsTheStatusCode() {
        let summary = HTTPError.status(401, body: #"{"error":{"code":"invalid_api_key"}}"#)
            .diagnosticSummary
        XCTAssertTrue(summary.contains("401"), summary)
        XCTAssertTrue(summary.contains("invalid_api_key"), summary)
    }

    func testDiagnosticSummaryRedactsSecretsToo() {
        let summary = HTTPError
            .status(401, body: "key sk-proj-AbC123dEf456GhI789jKl rejected")
            .diagnosticSummary
        XCTAssertFalse(summary.contains("sk-proj-AbC123dEf456GhI789jKl"), summary)
    }

    func testDiagnosticSummaryIsBounded() {
        let summary = HTTPError
            .status(500, body: String(repeating: "x", count: 5_000))
            .diagnosticSummary
        XCTAssertLessThan(summary.count, 600, "diagnostics must stay bounded")
    }

    func testDiagnosticSummaryCoversTransportAndNonHTTP() {
        XCTAssertTrue(
            HTTPError.transport(.timedOut).diagnosticSummary
                .localizedCaseInsensitiveContains("timed"),
            HTTPError.transport(.timedOut).diagnosticSummary
        )
        XCTAssertFalse(HTTPError.nonHTTPResponse.diagnosticSummary.isEmpty)
    }
}

/// The errors that *aren't* `HTTPError` were the worse half of #48: none of
/// them conformed to `LocalizedError`, so `localizedDescription` fell through
/// to Foundation and a reader importing a copy-protected book was told
/// "The operation couldn't be completed. (ReadrKit.BookParserError error 1.)".
///
/// `AppModel.importBook` and the settings screens interpolate
/// `localizedDescription` directly, so the conformance is what the reader sees.
final class DomainErrorMessageTests: XCTestCase {

    /// Foundation's fallback names the Swift type and an ordinal. If any of
    /// these leak, the conformance is missing.
    private func assertReadable(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let message = error.localizedDescription
        XCTAssertFalse(
            message.contains("couldn't be completed"),
            "no LocalizedError conformance: \(message)", file: file, line: line
        )
        XCTAssertFalse(
            message.contains("ReadrKit."),
            "the Swift type name reached the reader: \(message)", file: file, line: line
        )
        XCTAssertFalse(
            message.localizedCaseInsensitiveContains("error 0")
                || message.localizedCaseInsensitiveContains("error 1"),
            "a raw case ordinal reached the reader: \(message)", file: file, line: line
        )
        XCTAssertTrue(
            message.hasSuffix(".") || message.hasSuffix("?"),
            "not a sentence: \(message)", file: file, line: line
        )
    }

    // MARK: - Importing a book

    func testEveryParserErrorReadsAsPlainLanguage() {
        for error in [
            BookParserError.unsupportedFormat,
            .drmProtected,
            .corrupted("EOCD record not found at offset 0x1f4"),
        ] {
            assertReadable(error)
        }
    }

    /// The most common real import failure. "DRM" is jargon most readers don't
    /// use; "copy-protected" is what the message has to say.
    func testDRMErrorExplainsInReadersWords() {
        let message = BookParserError.drmProtected.localizedDescription
        XCTAssertTrue(message.localizedCaseInsensitiveContains("copy-protected"), message)
        XCTAssertFalse(message.contains("DRM"), message)
    }

    func testUnsupportedFormatNamesWhatReadrDoesOpen() {
        let message = BookParserError.unsupportedFormat.localizedDescription
        XCTAssertTrue(message.contains("EPUB"), message)
        XCTAssertTrue(message.contains("PDF"), message)
    }

    /// The parser's internal detail is triage material, not reader copy.
    func testCorruptedKeepsItsDetailInDiagnosticsOnly() {
        let error = BookParserError.corrupted("EOCD record not found at offset 0x1f4")
        XCTAssertFalse(error.localizedDescription.contains("EOCD"), error.localizedDescription)
        XCTAssertTrue(error.diagnosticSummary.contains("EOCD"), error.diagnosticSummary)
    }

    // MARK: - EPUB extraction limits

    /// These fire on hostile or unusual archives. The reader gets a plain
    /// sentence; the byte caps stay in diagnostics.
    func testEveryEPUBErrorReadsAsPlainLanguage() {
        for error in [
            EPUBParseError.entryTooLarge(path: "OEBPS/huge.xhtml", limit: 64 * 1024 * 1024),
            .cumulativeSizeExceeded(limit: 512 * 1024 * 1024),
            .tooManySpineItems(count: 20_000, limit: 10_000),
        ] {
            assertReadable(error)
            XCTAssertFalse(
                error.localizedDescription.contains("\(64 * 1024 * 1024)"),
                error.localizedDescription
            )
        }
    }

    func testEPUBLimitDetailSurvivesInDiagnostics() {
        let error = EPUBParseError.entryTooLarge(path: "OEBPS/huge.xhtml", limit: 1_024)
        XCTAssertTrue(error.diagnosticSummary.contains("OEBPS/huge.xhtml"), error.diagnosticSummary)
        XCTAssertTrue(error.diagnosticSummary.contains("1024"), error.diagnosticSummary)
    }

    // MARK: - Signing in

    func testEveryAuthErrorReadsAsPlainLanguage() {
        for error in [
            AuthError.userCancelled,
            .stateMismatch,
            .tokenExchangeFailed("invalid_grant: code already redeemed"),
            .refreshFailed,
            .reauthenticationRequired,
        ] {
            assertReadable(error)
        }
    }

    /// "State mismatch" is a PKCE implementation detail. What the reader needs
    /// is that sign-in was stopped and can be retried.
    func testStateMismatchDoesNotLeakTheProtocol() {
        let message = AuthError.stateMismatch.readerFacingMessage
        XCTAssertFalse(message.localizedCaseInsensitiveContains("state"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("sign in"), message)
    }

    func testTokenExchangeDetailStaysInDiagnostics() {
        let error = AuthError.tokenExchangeFailed("invalid_grant: code already redeemed")
        XCTAssertFalse(error.localizedDescription.contains("invalid_grant"))
        XCTAssertTrue(error.diagnosticSummary.contains("invalid_grant"))
    }

    /// An expired session is the one auth error with an obvious next step.
    func testReauthenticationTellsTheReaderToSignInAgain() {
        let message = AuthError.reauthenticationRequired.readerFacingMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("sign in again"), message)
    }

    // MARK: - The two halves reach single-string call sites

    /// `AppModel.importBook` and the settings screens interpolate one string.
    /// `localizedDescription` drops the recovery suggestion, so those surfaces
    /// use `readerFacingMessage` — which must carry both halves.
    func testReaderFacingMessageCarriesTheNextStep() {
        let message = BookParserError.drmProtected.readerFacingMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("copy-protected"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("DRM-free"), message)
    }

    /// No trailing separator when an error has no suggestion to add.
    func testReaderFacingMessageIsJustTheSentenceWhenThereIsNoRecovery() {
        XCTAssertEqual(
            AuthError.userCancelled.readerFacingMessage,
            "Sign-in was cancelled."
        )
    }

    /// A non-`LocalizedError` still has to produce something rather than crash.
    func testReaderFacingMessageFallsBackForPlainErrors() {
        struct Plain: Error {}
        XCTAssertFalse(Plain().readerFacingMessage.isEmpty)
        XCTAssertTrue(Plain().diagnosticDescription.contains("Plain"))
    }

    // MARK: - Annotations and articles

    func testHighlightAndArticleErrorsGuideRatherThanReport() {
        assertReadable(HighlightError.emptySelection)
        assertReadable(ArticleComposerError.noHighlights)

        XCTAssertTrue(
            ArticleComposerError.noHighlights.localizedDescription
                .localizedCaseInsensitiveContains("highlight"),
            "the guidance must name the thing to do first"
        )
    }
}

#if canImport(Security)
final class KeychainErrorMessageTests: XCTestCase {

    /// `errSecAuthFailed` is what a denied Keychain prompt returns. The reader
    /// saw the bare OSStatus before.
    func testKeychainErrorIsReadableAndKeepsTheStatusForTriage() {
        let error = KeychainError.unhandled(-25293)
        let message = error.localizedDescription

        XCTAssertFalse(message.contains("couldn't be completed"), message)
        XCTAssertFalse(message.contains("-25293"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("keychain"), message)
        XCTAssertTrue(error.diagnosticSummary.contains("-25293"), error.diagnosticSummary)
    }
}
#endif
