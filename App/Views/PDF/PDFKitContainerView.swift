import SwiftUI
import ReadrKit

#if canImport(PDFKit)
import PDFKit

// The `PDFView` host and the thumbnail strip. Both are thin: all behavior
// lives in `PDFReaderController`, which the platform view is attached to so
// PDFKit callbacks and SwiftUI observation share one object.

/// Book/model/onAsk are (re)synced on every update — SwiftUI may hand the
/// reader a fresh `AppModel` or closure identity while the platform view
/// lives on. Syncing precedes `loadIfNeeded` so the first document load
/// already has the store to restore overlays and position from.
@MainActor
private func syncController(
    _ controller: PDFReaderController,
    model: AppModel, book: Book, url: URL,
    onAsk: @escaping (Selection) -> Void
) {
    controller.model = model
    controller.book = book
    controller.onAsk = onAsk
    controller.loadIfNeeded(url: url)
}

#if canImport(UIKit)
struct PDFKitContainerView: UIViewRepresentable {
    let controller: PDFReaderController
    let model: AppModel
    let book: Book
    let url: URL
    let onAsk: (Selection) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        controller.attach(view)
        syncController(controller, model: model, book: book, url: url, onAsk: onAsk)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        syncController(controller, model: model, book: book, url: url, onAsk: onAsk)
    }
}
#elseif canImport(AppKit)
struct PDFKitContainerView: NSViewRepresentable {
    let controller: PDFReaderController
    let model: AppModel
    let book: Book
    let url: URL
    let onAsk: (Selection) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        controller.attach(view)
        syncController(controller, model: model, book: book, url: url, onAsk: onAsk)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        syncController(controller, model: model, book: book, url: url, onAsk: onAsk)
    }
}
#endif

// MARK: - Thumbnails

/// `PDFThumbnailView` tracks the `PDFView` it's pointed at (page changes,
/// document swaps) on its own; our only job is to (re)connect it once the
/// PDFView exists. Observing the controller re-runs `update` when the
/// document loads, covering the case where the strip is built first.
#if canImport(UIKit)
struct PDFThumbnailStrip: UIViewRepresentable {
    @ObservedObject var controller: PDFReaderController

    func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.layoutMode = .horizontal
        view.backgroundColor = .clear
        view.pdfView = controller.pdfView
        return view
    }

    func updateUIView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== controller.pdfView {
            view.pdfView = controller.pdfView
        }
    }
}
#elseif canImport(AppKit)
struct PDFThumbnailStrip: NSViewRepresentable {
    @ObservedObject var controller: PDFReaderController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.backgroundColor = .clear
        view.pdfView = controller.pdfView
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== controller.pdfView {
            view.pdfView = controller.pdfView
        }
    }
}
#endif
#endif
