import SwiftUI
import ReadrKit

#if canImport(PDFKit)
import PDFKit

/// TOC popover content: the document's page bookmarks first, then the PDF
/// outline flattened into an indented list. Outline items are snapshotted
/// on appear — an outline never changes while a document is open, so
/// there's nothing to observe; the bookmarks are the live model's.
struct PDFOutlineList: View {
    let controller: PDFReaderController
    /// Page bookmarks in page order. Tap jumps; ✕ removes.
    var bookmarks: [Bookmark] = []
    var onRemoveBookmark: ((Bookmark) -> Void)? = nil
    /// Host closes the popover; rows call this after jumping.
    var dismiss: () -> Void

    @State private var items: [PDFReaderController.OutlineItem] = []

    /// Matches the reader's persisted theme so the PDF contents popover sits on
    /// the same Marginalia palette as the page rather than a system-material
    /// surface that reads as white/gray chrome on sepia and dark.
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    private var bookmarkedPages: Set<Int> {
        Set(bookmarks.compactMap { $0.pdfPageIndex.map { $0 + 1 } })
    }

    var body: some View {
        Group {
            if items.isEmpty, bookmarks.isEmpty {
                Text("No table of contents")
                    .foregroundStyle(theme.muted)
                    .frame(width: 260, height: 76)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !bookmarks.isEmpty {
                            header("BOOKMARKS")
                            ForEach(bookmarks) { bookmark in
                                bookmarkRow(bookmark)
                            }
                        }
                        if !items.isEmpty {
                            header("CONTENTS")
                            ForEach(items) { item in
                                row(item)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 320, height: min(400, CGFloat(bookmarks.count * 44 + items.count * 32) + 80))
            }
        }
        .background(theme.elevated)
        .presentationBackground(theme.elevated)
        .onAppear { items = controller.outlineItems() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(1.5)
            .foregroundStyle(theme.faint)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 8) {
            Button {
                controller.goToPage(bookmark.pdfPageIndex ?? 0)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                    Text(bookmark.snippet.isEmpty ? "Page \((bookmark.pdfPageIndex ?? 0) + 1)" : bookmark.snippet)
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(theme.inkColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("contents.bookmark")
            if let onRemoveBookmark {
                Button {
                    onRemoveBookmark(bookmark)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.faint)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove bookmark")
                .accessibilityLabel("Remove bookmark")
                .accessibilityIdentifier("contents.removeBookmark")
            }
        }
    }

    private func row(_ item: PDFReaderController.OutlineItem) -> some View {
        Button {
            controller.jump(to: item)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.system(size: 13.5, design: .serif))
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let page = item.pageNumber, bookmarkedPages.contains(page) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.faint)
                        .accessibilityLabel("Has a bookmark")
                }
                if let page = item.pageNumber {
                    Text("\(page)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.muted)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(item.depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.destination == nil)
    }
}
#endif
