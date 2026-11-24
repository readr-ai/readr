#if canImport(PDFKit)
import Foundation
import PDFKit
import Vision
import ReadrKit

/// PDF import via Apple's PDFKit — no third-party dependency. Extracts text one
/// chapter per page (a coarse but real first cut; the Readium-backed parser will
/// add proper outline/TOC-aware chaptering). Encrypted/locked PDFs are rejected.
///
/// A PDF with no text layer — a scanned book, or screenshots exported as a
/// PDF — receives local Vision OCR. Pages still lacking recognizable text
/// remain blank chapters; `isImageOnly` is set only when no page has text.
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

        // A page object PDFKit cannot build is damage; a page with no text
        // is not. The two must not be flattened into the same nil.
        var pageTexts: [String?] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw BookParserError.corrupted("page \(index + 1) could not be loaded")
            }
            try Task.checkCancellation()
            let native = page.string ?? ""
            pageTexts.append(native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? try recognize(page, number: index + 1) : native)
        }
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
        // Estimated from the same join `Book.fullText` sends as whole-book context.
        let fullText = pages.chapters.map(\.text).joined(separator: "\n\n")
        return Book(
            metadata: metadata,
            chapters: pages.chapters,
            estimatedTokenCount: estimateTokens(fullText)
        )
    }
    /// Vision is bundled with the OS. No model download or passage upload.
    private func recognize(_ page: PDFPage, number: Int) throws -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2200 / max(bounds.width, bounds.height, 1)
        let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        #if os(macOS)
        let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        let image = thumbnail.cgImage
        #endif
        guard let image else { throw BookParserError.corrupted("Page \(number) could not be rendered for text recognition") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { throw BookParserError.corrupted("Text recognition failed on page \(number). Try importing the PDF again.") }
        // Vision supplies lines in reading order. Blank plates remain blank
        // chapters; OCR text uses exactly the same coordinates as narration.
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

}
#endif
