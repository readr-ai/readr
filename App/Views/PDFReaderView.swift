import SwiftUI
import ReadrKit

#if canImport(PDFKit)
import PDFKit

/// Native PDF reading — the headline feature Apple Books lacks on the Mac
/// (it punts PDFs to Preview). Continuous vertical PDFKit pages with the full
/// Readr annotation loop: select → popover → one-click highlight, notes,
/// select-to-Ask, plus outline TOC, thumbnails, find-in-PDF, page bookmarks,
/// and position restore. Highlights live in Readr's own store as page-space
/// rects; the PDF file itself is never mutated.
///
/// Brings its own toolbar items (SwiftUI merges them with the host reader's
/// toolbar); the host must disable its text-mode ⌘F search in PDF mode since
/// `pdf.search` claims that shortcut.
struct PDFReaderView: View {
    let book: Book
    let url: URL
    var onAsk: (Selection) -> Void

    @EnvironmentObject private var model: AppModel
    @StateObject private var controller = PDFReaderController()
    /// Strip visibility persists across books like the other reader prefs.
    @AppStorage("pdfShowsThumbnails") private var showThumbnails = false
    @State private var showTOC = false
    @State private var showSearch = false

    var body: some View {
        content
            .toolbar { toolbarItems }
            .sheet(item: $controller.pendingNote) { highlight in
                PDFHighlightNoteSheet(
                    highlight: highlight,
                    isNew: controller.pendingNoteIsNew,
                    controller: controller
                )
                .environmentObject(model)
            }
            // Flush the debounced position save so closing the reader
            // mid-scroll can't drop the last page turn.
            .onDisappear { controller.flushPosition() }
    }

    // MARK: Layout

    private var content: some View {
        #if canImport(UIKit)
        // iOS: thumbnails as a bottom strip (horizontal layout mode).
        VStack(spacing: 0) {
            pdfSurface
            if showThumbnails {
                Divider()
                PDFThumbnailStrip(controller: controller)
                    .frame(height: 116)
            }
        }
        #else
        // macOS: thumbnails as a leading sidebar strip, Preview-style.
        HStack(spacing: 0) {
            if showThumbnails {
                PDFThumbnailStrip(controller: controller)
                    .frame(width: 132)
                Divider()
            }
            pdfSurface
        }
        #endif
    }

    private var pdfSurface: some View {
        PDFKitContainerView(
            controller: controller,
            model: model,
            book: book,
            url: url,
            onAsk: onAsk
        )
        .overlay(alignment: .bottom) { bottomOverlay }
    }

    private var bottomOverlay: some View {
        VStack(spacing: 10) {
            #if canImport(UIKit)
            // iOS has no anchored popover: the annotation menu floats as a
            // capsule bar above the bottom edge, near the thumb.
            if let context = controller.activeMenu {
                controller.menuView(for: context)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            #endif
            if controller.pageCount > 0 {
                Text("Page \(controller.currentPageIndex + 1) of \(controller.pageCount)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("pdf.pageIndicator")
            }
        }
        .padding(.bottom, 14)
        .animation(.snappy(duration: 0.2), value: controller.activeMenu != nil)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(id: "pdf.toc", placement: .navigation) {
            Button {
                showTOC.toggle()
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .help("Table of contents")
            .accessibilityIdentifier("pdf.toc")
            .popover(isPresented: $showTOC, arrowEdge: .bottom) {
                PDFOutlineList(controller: controller) { showTOC = false }
            }
        }
        ToolbarItem(id: "pdf.thumbnails", placement: .navigation) {
            Toggle(isOn: $showThumbnails) {
                Label("Thumbnails", systemImage: "rectangle.grid.1x2")
            }
            .toggleStyle(.button)
            .help("Show page thumbnails")
            .accessibilityIdentifier("pdf.thumbnails")
        }
        ToolbarItem(id: "pdf.bookmark", placement: .navigation) {
            bookmarkMenu
        }
        ToolbarItem(id: "pdf.search", placement: .primaryAction) {
            Button {
                showSearch.toggle()
            } label: {
                Label("Find in PDF", systemImage: "magnifyingglass")
            }
            // The host reader's text search is disabled in PDF mode, so ⌘F
            // is ours here.
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in PDF (⌘F)")
            .accessibilityIdentifier("pdf.search")
            .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                PDFSearchView(controller: controller)
            }
        }
    }

    // MARK: Bookmarks

    private var currentBookmark: Bookmark? {
        model.bookmarks(for: book).first { $0.pdfPageIndex == controller.currentPageIndex }
    }

    private var pageBookmarks: [Bookmark] {
        model.bookmarks(for: book)
            .filter { $0.pdfPageIndex != nil }
            .sorted { ($0.pdfPageIndex ?? 0) < ($1.pdfPageIndex ?? 0) }
    }

    /// Split control: primary click toggles the bookmark on the current page
    /// (the icon fills when the page is bookmarked); the menu lists all page
    /// bookmarks for jumping.
    private var bookmarkMenu: some View {
        Menu {
            Button {
                toggleBookmark()
            } label: {
                Label(
                    currentBookmark == nil ? "Add Bookmark" : "Remove Bookmark",
                    systemImage: currentBookmark == nil ? "bookmark" : "bookmark.slash"
                )
            }
            .keyboardShortcut("d", modifiers: .command)
            if !pageBookmarks.isEmpty {
                Divider()
                ForEach(pageBookmarks) { bookmark in
                    Button {
                        controller.goToPage(bookmark.pdfPageIndex ?? 0)
                    } label: {
                        Label(
                            bookmark.snippet.isEmpty
                                ? "Page \((bookmark.pdfPageIndex ?? 0) + 1)"
                                : bookmark.snippet,
                            systemImage: "bookmark.fill"
                        )
                    }
                }
            }
        } label: {
            Label(
                "Bookmarks",
                systemImage: currentBookmark == nil ? "bookmark" : "bookmark.fill"
            )
        } primaryAction: {
            toggleBookmark()
        }
        .help("Bookmark this page (⌘D)")
        .accessibilityIdentifier("pdf.bookmark")
    }

    private func toggleBookmark() {
        if let existing = currentBookmark {
            model.removeBookmark(existing)
        } else {
            model.addBookmark(Bookmark(
                bookID: book.id,
                chapterIndex: 0,
                characterOffset: 0,
                pdfPageIndex: controller.currentPageIndex,
                snippet: "Page \(controller.currentPageIndex + 1)",
                createdAt: Date()
            ))
        }
    }
}

/// Wraps the shared `NoteEditor` for a PDF highlight. Draft is seeded once
/// from the highlight — the sheet owns the text until Save, so background
/// store updates can't stomp mid-edit typing. When the Note action just
/// created the highlight, cancelling the sheet undoes the creation; cancel
/// on an existing highlight's note leaves the highlight alone.
private struct PDFHighlightNoteSheet: View {
    @EnvironmentObject private var model: AppModel
    let highlight: PDFHighlight
    /// True when the highlight exists only because Note was clicked.
    let isNew: Bool
    /// Removal goes through the controller so the page overlay comes off too.
    let controller: PDFReaderController
    @State private var draft: String
    @State private var saved = false

    init(highlight: PDFHighlight, isNew: Bool, controller: PDFReaderController) {
        self.highlight = highlight
        self.isNew = isNew
        self.controller = controller
        _draft = State(initialValue: highlight.note ?? "")
    }

    var body: some View {
        NoteEditor(quotedText: highlight.quotedText, text: $draft) {
            var updated = highlight
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // Saving an empty editor clears the note rather than storing "".
            updated.note = trimmed.isEmpty ? nil : trimmed
            model.updatePDFHighlight(updated)
            saved = true
        }
        .onDisappear {
            // Dismissed without Save: a Note-flow highlight was never asked
            // for, so take it back out.
            if isNew && !saved {
                controller.removeHighlight(highlight)
            }
        }
    }
}

#else

/// Non-Apple platforms have no PDFKit; keep the contract compiling.
struct PDFReaderView: View {
    let book: Book
    let url: URL
    var onAsk: (Selection) -> Void

    var body: some View {
        ContentUnavailableView("PDF rendering unavailable", systemImage: "doc.richtext")
    }
}
#endif
