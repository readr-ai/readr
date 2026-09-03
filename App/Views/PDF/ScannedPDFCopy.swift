import Foundation

/// Every sentence the app says about a PDF with no text layer, in one place:
/// the import notice, the reader banner, the disabled-control reasons, and the
/// missing-file and image-page states. The feature list is the part that will
/// change — OCR on import (see `docs/DEVELOPMENT-PLAN.md`) unlocks features one
/// at a time — so it is written once.
enum ScannedPDFCopy {
    /// What needs text, in the order the toolbar shows them.
    static let textFeatures = "Ask, Listen, search, highlights, and the Reading view"

    /// The one-time alert after import: what it is, what still works, what
    /// doesn't, and the way to unlock it.
    static func importNotice(title: String) -> String {
        """
        “\(title)” is a scanned PDF with no text layer. Readr shows its pages, \
        but \(textFeatures) all need text, so they're unavailable for this \
        book. Run it through an OCR tool and import the result to unlock them.
        """
    }

    /// The one-line strip above the first page, each time the book opens.
    static let banner =
        "Scanned PDF with no text layer — \(textFeatures) aren't available for this book."

    /// Tooltip (macOS) and accessibility hint (both platforms) on a control
    /// that is disabled because the book has no text.
    static func needsText(_ feature: String) -> String {
        "\(feature) needs text, and this scanned PDF has none."
    }

    /// The reader's own copy of the original file is gone and there is no
    /// text to fall back on.
    static let missingFileTitle = "This scanned PDF's file is missing"
    static let missingFileDescription =
        "Readr's copy of the original file is gone, and a scanned PDF has no text to show instead. Import the PDF again to read it."

    /// A page that carries only an image, met in the Reading view of a PDF
    /// that does have text elsewhere.
    static func imagePageTitle(_ pageTitle: String) -> String {
        "\(pageTitle) is an image"
    }
    static let imagePageDescription =
        "This page has no text to show. Switch to Original pages to see it."
    static let showOriginalPages = "Show Original Pages"
}
