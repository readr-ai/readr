import Foundation

/// An error that carries triage detail the reader is never shown.
///
/// Two audiences, two strings. `localizedDescription` is what a reader reads
/// in the Ask panel or an import banner — plain language, a next step, no
/// protocol nouns. `diagnosticSummary` is what a bug report attaches (#41):
/// the status code, the offending path, the `OSStatus`, the provider's raw
/// reason. Conflating them is how "The operation couldn't be completed.
/// (ReadrKit.EPUBParseError error 3.)" ended up in front of readers (#48).
///
/// Implementations must keep secrets out of the summary — it is written to
/// disk. See `HTTPError.redactingSecrets(in:)`.
public protocol DiagnosticallyDescribable {
    var diagnosticSummary: String { get }
}

public extension Error {

    /// Everything the reader should see: what went wrong, then what to do.
    ///
    /// `localizedDescription` returns `errorDescription` alone, so any call
    /// site that interpolates it drops the recovery suggestion — which is
    /// where the actionable half of these messages lives. Banners and inline
    /// labels that show a single string should use this instead; surfaces that
    /// render the two parts separately (the Ask panel) keep doing that.
    var readerFacingMessage: String {
        guard let localized = self as? LocalizedError else { return localizedDescription }
        let description = localized.errorDescription ?? localizedDescription
        guard let recovery = localized.recoverySuggestion, !recovery.isEmpty else {
            return description
        }
        return description + " " + recovery
    }

    /// Triage detail for logs and bug reports, for errors that carry any.
    /// Falls back to the type-and-case description Swift already prints —
    /// useless to a reader, but exactly what a maintainer wants.
    var diagnosticDescription: String {
        (self as? DiagnosticallyDescribable)?.diagnosticSummary
            ?? String(reflecting: self)
    }
}

// MARK: - Importing a book

extension BookParserError: LocalizedError, DiagnosticallyDescribable {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Readr can't open this kind of file. It reads EPUB and PDF books, plus plain-text and Markdown files."
        case .drmProtected:
            // "DRM" is the industry's word, not the reader's.
            return "This book is copy-protected, so Readr can't open it."
        case .corrupted:
            // The parser's reason ("EOCD record not found…") means nothing to
            // a reader; it rides along in the diagnostics instead.
            return "This file seems to be damaged, so Readr couldn't read it."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormat:
            return "Try importing one of those instead."
        case .drmProtected:
            return "Readr opens DRM-free books you own. Books bought from stores that lock their files can't be opened here."
        case .corrupted:
            return "Try downloading the file again. If it opens elsewhere, send us a bug report from Settings."
        }
    }

    public var diagnosticSummary: String {
        switch self {
        case .unsupportedFormat: return "BookParserError.unsupportedFormat"
        case .drmProtected: return "BookParserError.drmProtected"
        case .corrupted(let detail):
            return "BookParserError.corrupted: \(HTTPError.redactingSecrets(in: detail).prefix(300))"
        }
    }
}

extension EPUBParseError: LocalizedError, DiagnosticallyDescribable {
    public var errorDescription: String? {
        switch self {
        case .entryTooLarge:
            return "Part of this book is too large for Readr to open safely."
        case .cumulativeSizeExceeded:
            return "This book is too large for Readr to open safely."
        case .tooManySpineItems:
            return "This book has more sections than Readr can open."
        }
    }

    public var recoverySuggestion: String? {
        "If this book opens in another reader, send us a bug report from Settings — that's a limit we may be able to raise."
    }

    public var diagnosticSummary: String {
        switch self {
        case .entryTooLarge(let path, let limit):
            return "EPUBParseError.entryTooLarge(path: \(path), limit: \(limit))"
        case .cumulativeSizeExceeded(let limit):
            return "EPUBParseError.cumulativeSizeExceeded(limit: \(limit))"
        case .tooManySpineItems(let count, let limit):
            return "EPUBParseError.tooManySpineItems(count: \(count), limit: \(limit))"
        }
    }
}

// MARK: - Signing in

extension AuthError: LocalizedError, DiagnosticallyDescribable {
    public var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Sign-in was cancelled."
        case .stateMismatch:
            // A PKCE `state` mismatch means the callback didn't match the
            // request we started. Naming the protocol helps nobody; naming the
            // outcome — we stopped it on purpose — does.
            return "Readr couldn't confirm that sign-in came back from the right place, so it stopped."
        case .tokenExchangeFailed:
            return "Sign-in didn't finish."
        case .refreshFailed:
            return "Readr couldn't renew your session."
        case .reauthenticationRequired:
            return "Your session has expired."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .userCancelled:
            return nil
        case .stateMismatch:
            return "Try to sign in again. If it keeps happening, close other sign-in windows first."
        case .tokenExchangeFailed:
            return "Try signing in again."
        case .refreshFailed, .reauthenticationRequired:
            return "Sign in again in Settings → AI Providers."
        }
    }

    public var diagnosticSummary: String {
        switch self {
        case .userCancelled: return "AuthError.userCancelled"
        case .stateMismatch: return "AuthError.stateMismatch"
        case .tokenExchangeFailed(let detail):
            return "AuthError.tokenExchangeFailed: \(HTTPError.redactingSecrets(in: detail).prefix(300))"
        case .refreshFailed: return "AuthError.refreshFailed"
        case .reauthenticationRequired: return "AuthError.reauthenticationRequired"
        }
    }
}

// MARK: - Annotations and articles

extension HighlightError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Nothing was selected to highlight."
        }
    }

    public var recoverySuggestion: String? {
        "Select some text in the book first, then highlight it."
    }
}

extension ArticleComposerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noHighlights:
            return "There are no highlights in this book yet."
        }
    }

    public var recoverySuggestion: String? {
        "Highlight the passages you want to write about, then come back — the article is built from them."
    }
}

// MARK: - Keychain

// `KeychainError` only exists where Security does, so the conformance is
// guarded to match its declaration in `KeychainCredentialStore.swift`.
#if canImport(Security)

/// A bare `OSStatus` means nothing to a reader — the common one here is
/// `errSecAuthFailed` (-25293), returned when the Keychain prompt is declined.
/// The number stays in the diagnostics for triage.
extension KeychainError: LocalizedError, DiagnosticallyDescribable {
    public var errorDescription: String? {
        switch self {
        case .unhandled:
            return "Readr couldn't reach your Keychain, so nothing was saved."
        }
    }

    public var recoverySuggestion: String? {
        "Try again, and allow Readr access when your Keychain asks."
    }

    public var diagnosticSummary: String {
        switch self {
        case .unhandled(let status):
            return "KeychainError.unhandled(OSStatus \(status))"
        }
    }
}

#endif
