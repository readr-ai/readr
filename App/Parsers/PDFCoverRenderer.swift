#if canImport(PDFKit)
import Foundation
import PDFKit

/// Renders a PDF's first page as cover artwork, Apple-Books style.
enum PDFCoverRenderer {
    static func firstPageThumbnail(url: URL, maxDimension: CGFloat = 600) -> Data? {
        guard let document = PDFDocument(url: url),
              !document.isLocked,
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        #if canImport(UIKit)
        return thumbnail.pngData()
        #else
        guard let tiff = thumbnail.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }
}
#endif
