import Foundation

/// Turns a PDF's per-page text into `Chapter`s — one per page, in page order.
///
/// The PDF parser itself needs PDFKit and lives in the app; the rule for what
/// its output means lives here so it is tested on CI. Two things it decides:
///
/// - **Every page is a chapter**, text or not. A page without text keeps its
///   slot (empty text) so "Page N" titles, the outline, and saved positions
///   stay aligned with the document. Skipping such pages — the old behaviour —
///   shifted every later page number.
/// - **A book with no text on any page is image-only**: a scanned book, or
///   screenshots exported as a PDF. That is not damage; PDFKit renders the
///   pages fine. The flag lets the app show them and say plainly which
///   features have nothing to work with.
public enum PDFPageChapters {
    public struct Result: Sendable {
        public var chapters: [Chapter]
        /// True when the document has pages and none of them carries text.
        /// An empty document is false: that is a different failure.
        public var isImageOnly: Bool
        /// Page texts joined in order, for token estimation.
        public var fullText: String
    }

    /// - Parameter pageTexts: one entry per page, in page order — the text
    ///   PDFKit extracted, or nil when it found none.
    public static func build(fromPageTexts pageTexts: [String?]) -> Result {
        var chapters: [Chapter] = []
        var fullText = ""
        var sawText = false
        for (index, pageText) in pageTexts.enumerated() {
            let text = pageText ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawText = true
                fullText += text + "\n"
            }
            chapters.append(Chapter(title: "Page \(index + 1)", order: index, text: text))
        }
        return Result(
            chapters: chapters,
            isImageOnly: !pageTexts.isEmpty && !sawText,
            fullText: fullText
        )
    }
}
