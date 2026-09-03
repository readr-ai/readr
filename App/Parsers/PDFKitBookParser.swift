#if canImport(PDFKit)
import Foundation
import PDFKit
import ReadrKit

/// PDF import via Apple's PDFKit — no third-party dependency. Extracts text one
/// chapter per page (a coarse but real first cut; the Readium-backed parser will
/// add proper outline/TOC-aware chaptering). Encrypted/locked PDFs are rejected.
///
/// A PDF with no text layer — a scanned book, or screenshots exported as a
/// PDF — is not rejected: PDFKit renders its pages fine. It imports with one
/// empty chapter per page and `isImageOnly` set, so the reader shows the
/// original pages and says which text features have nothing to work with.
/// The page-to-chapter rule itself is `PDFPageChapters` in ReadrKit.
struct PDFKitBookParser: BookParser {
    func canParse(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    func parse(_ url: URL) async throws -> Book {
        guard let document = PDFDocument(url: url) else {
            throw BookParserError.corrupted("could not open PDF")
        }
        if document.isEncrypted && document.isLocked {
            throw BookParserError.drmProtected
        }
        guard document.pageCount > 0 else {
            throw BookParserError.corrupted("PDF has no pages")
        }

        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string }
        let pages = PDFPageChapters.build(fromPageTexts: pageTexts)

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let toc = pages.chapters.compactMap { chapter in
            chapter.title.map { TOCEntry(title: $0, chapterIndex: chapter.order) }
        }
        let metadata = BookMetadata(
            title: title,
            authors: author.map { [$0] } ?? [],
            tableOfContents: toc,
            isImageOnly: pages.isImageOnly ? true : nil
        )
        return Book(
            metadata: metadata,
            chapters: pages.chapters,
            estimatedTokenCount: estimateTokens(pages.fullText)
        )
    }
}
#endif
