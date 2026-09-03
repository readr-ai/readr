import XCTest
import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import CoreText
@testable import Readr
import ReadrKit

/// Importing a PDF with no text layer — a scanned book, or screenshots that
/// Preview exported as a PDF — used to fail with "This file seems to be
/// damaged". Two real books hit it on 2026-09-03: PDFKit returned nil text for
/// every page, the parser skipped every page, and the empty chapter list was
/// reported as corruption. The parser now keeps one chapter per page and flags
/// the book image-only instead; the reader shows the pages and says which
/// features have nothing to work with.
///
/// App-hosted (macOS) because `PDFKitBookParser` needs PDFKit; the chaptering
/// rule itself is pinned in `ReadrKitTests/ImageOnlyPDFTests`.
final class ImageOnlyPDFImportTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageOnlyPDFImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - The regression

    func testScannedPDFImportsWithOnePageChapterPerPageAndTheImageOnlyFlag() async throws {
        let url = try makePDF(named: "scan", pages: [.image, .image, .image])

        let book = try await PDFKitBookParser().parse(url)

        XCTAssertEqual(book.metadata.isImageOnly, true)
        XCTAssertEqual(book.chapters.count, 3, "every page keeps its slot")
        XCTAssertEqual(book.chapters.map(\.title), ["Page 1", "Page 2", "Page 3"])
        XCTAssertTrue(book.chapters.allSatisfy { $0.text.isEmpty })
        XCTAssertEqual(book.metadata.title, "scan", "falls back to the file name")
        XCTAssertEqual(book.metadata.tableOfContents.count, 3)
    }

    // MARK: - Books with text are untouched

    func testTextPDFIsNotFlaggedAndKeepsItsText() async throws {
        let url = try makePDF(named: "text", pages: [.text("First page."), .text("Second page.")])

        let book = try await PDFKitBookParser().parse(url)

        XCTAssertNil(book.metadata.isImageOnly)
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertTrue(book.chapters[0].text.contains("First"))
        XCTAssertTrue(book.chapters[1].text.contains("Second"))
        XCTAssertGreaterThan(book.estimatedTokenCount, 0)
    }

    func testMixedPDFKeepsPageNumberingAcrossImagePages() async throws {
        // A text book with a full-page plate in the middle: the plate used to
        // be dropped, so "Page 3" was titled "Page 2".
        let url = try makePDF(named: "mixed", pages: [.text("One."), .image, .text("Three.")])

        let book = try await PDFKitBookParser().parse(url)

        XCTAssertNil(book.metadata.isImageOnly)
        XCTAssertEqual(book.chapters.count, 3)
        XCTAssertEqual(book.chapters[1].title, "Page 2")
        XCTAssertTrue(book.chapters[1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(book.chapters[2].title, "Page 3")
        XCTAssertTrue(book.chapters[2].text.contains("Three"))
    }

    // MARK: - Failure paths

    func testFileThatIsNotAPDFStillFailsAsCorrupted() async throws {
        let url = scratch.appendingPathComponent("not-a.pdf")
        try Data("hello".utf8).write(to: url)

        do {
            _ = try await PDFKitBookParser().parse(url)
            XCTFail("expected a parse failure")
        } catch let error as BookParserError {
            guard case .corrupted = error else {
                return XCTFail("expected .corrupted, got \(error)")
            }
        }
    }

    // MARK: - The reader says so

    /// The native PDF surface for an image-only book carries the one-line
    /// notice above the first page; a book with text does not. Rendered
    /// offscreen like `MacSnapshotTests`, with the PNGs attached for a look.
    ///
    /// Asserted on pixels: the strip's icon, sentence, and ✕ are dark marks
    /// in a band that, without the strip, is the blank top of the page
    /// (`PDFView` shows the first page from its top edge, and the fixture's
    /// text starts an inch down). Both surfaces are near-white, so a single
    /// colour sample could not tell them apart.
    @MainActor
    func testScannedPDFReaderShowsTheNoticeAndTextPDFDoesNot() async throws {
        // The host is the real app, so its defaults are the developer's: pin
        // the theme, and keep the macOS thumbnail sidebar (which would sit
        // inside the sampled band) out of the render.
        UserDefaults.standard.set(ReadingTheme.paper.rawValue, forKey: "readingTheme")
        UserDefaults.standard.set(false, forKey: "pdfShowsThumbnails")
        defer {
            UserDefaults.standard.removeObject(forKey: "readingTheme")
            UserDefaults.standard.removeObject(forKey: "pdfShowsThumbnails")
        }

        let scanURL = try makePDF(named: "scan", pages: [.image, .image])
        let textURL = try makePDF(named: "text", pages: [.text("Words."), .text("More.")])
        let scan = try await PDFKitBookParser().parse(scanURL)
        let text = try await PDFKitBookParser().parse(textURL)
        XCTAssertEqual(scan.metadata.isImageOnly, true)
        XCTAssertNil(text.metadata.isImageOnly)

        let scanRep = try XCTUnwrap(renderReader(for: scan, at: scanURL, name: "m12-pdf-scan-notice"))
        let textRep = try XCTUnwrap(renderReader(for: text, at: textURL, name: "m12-pdf-text-no-notice"))

        let scanMarks = Self.darkPixels(in: scanRep, rowsFrom: 0.015, to: 0.08)
        let textMarks = Self.darkPixels(in: textRep, rowsFrom: 0.015, to: 0.08)
        XCTAssertGreaterThan(scanMarks, 200, "scanned PDF should show the notice strip")
        XCTAssertEqual(textMarks, 0, "a PDF with text must not show the notice strip")
    }

    // MARK: - Fixtures

    private enum Page {
        case text(String)
        /// A page carrying nothing but a bitmap — what a scanner writes.
        case image
    }

    private func makePDF(named name: String, pages: [Page]) throws -> URL {
        let url = scratch.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text):
                let attributed = NSAttributedString(
                    string: text,
                    attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)]
                )
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: 0, length: 0),
                    CGPath(rect: mediaBox.insetBy(dx: 72, dy: 72), transform: nil), nil
                )
                CTFrameDraw(frame, context)
            case .image:
                context.draw(try scannedPageBitmap(), in: mediaBox.insetBy(dx: 36, dy: 36))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: Rendering

    /// Hosts the native PDF reader offscreen and returns one drawn frame.
    @MainActor
    private func renderReader(for book: Book, at url: URL, name: String) -> NSBitmapImageRep? {
        let store = InMemoryLibraryStore()
        try? store.add(book)
        let model = AppModel(store: store)
        let view = PDFReaderView(
            book: book, url: url, onAsk: { _ in }, annotationActions: .constant(nil)
        )
        .environmentObject(model)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: CGSize(width: 640, height: 480))
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return rep
    }

    /// Pixels darker than mid-grey in a horizontal band of the render, the
    /// band given as fractions of its height. Only the middle 80% of each row
    /// is read: `PDFView` draws a dark margin down both edges of the page,
    /// which is not the strip.
    private static func darkPixels(in rep: NSBitmapImageRep, rowsFrom top: CGFloat, to bottom: CGFloat) -> Int {
        var count = 0
        let firstRow = Int(CGFloat(rep.pixelsHigh) * top)
        let lastRow = Int(CGFloat(rep.pixelsHigh) * bottom)
        let firstColumn = Int(CGFloat(rep.pixelsWide) * 0.1)
        let lastColumn = Int(CGFloat(rep.pixelsWide) * 0.9)
        for y in firstRow..<lastRow {
            for x in stride(from: firstColumn, to: lastColumn, by: 2) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.brightnessComponent < 0.5 { count += 1 }
            }
        }
        return count
    }

    /// A small grey bitmap with a few dark bars — text-shaped to the eye,
    /// invisible to text extraction.
    private func scannedPageBitmap() throws -> CGImage {
        let size = 120
        let bitmap = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        bitmap.setFillColor(gray: 0.95, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: size, height: size))
        bitmap.setFillColor(gray: 0.15, alpha: 1)
        for row in stride(from: 12, to: size - 12, by: 14) {
            bitmap.fill(CGRect(x: 12, y: row, width: size - 24, height: 6))
        }
        return try XCTUnwrap(bitmap.makeImage())
    }
}
