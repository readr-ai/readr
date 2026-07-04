import SwiftUI

#if canImport(PDFKit)
import PDFKit
#endif

/// Native PDF rendering via PDFKit's `PDFView` — continuous vertical scrolling
/// with auto-scaling, like Apple Books' PDF mode. Selection-based Ask and
/// highlights don't apply here; the text reading modes remain for EPUB/text.
struct PDFReaderView: View {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    var body: some View {
        #if canImport(PDFKit)
        PDFKitView(url: url)
        #else
        ContentUnavailableView("PDF rendering unavailable", systemImage: "doc.richtext")
        #endif
    }
}

#if canImport(PDFKit)
private func configure(_ view: PDFView) {
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
}

/// Tracks which URL was last loaded. `PDFDocument.documentURL` can't be
/// compared against our URL directly: PDFKit reports resolved paths
/// (`/private/var/…`) while ours go through the `/var` symlink, so raw
/// equality never matches and the reader would reset to page 1 on every
/// SwiftUI update. Also prevents retry-loops when a document fails to load.
private final class LoadState {
    var loadedURL: URL?
}

private func loadIfNeeded(_ view: PDFView, url: URL, state: LoadState) {
    let target = url.standardizedFileURL.resolvingSymlinksInPath()
    guard state.loadedURL != target else { return }
    view.document = PDFDocument(url: url)
    state.loadedURL = target
}

#if canImport(UIKit)
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> LoadState { LoadState() }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        loadIfNeeded(view, url: url, state: context.coordinator)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        loadIfNeeded(view, url: url, state: context.coordinator)
    }
}
#elseif canImport(AppKit)
private struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> LoadState { LoadState() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        loadIfNeeded(view, url: url, state: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        loadIfNeeded(view, url: url, state: context.coordinator)
    }
}
#endif
#endif
