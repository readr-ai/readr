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

    var body: some View {
        let bookmarkedPages = Set(bookmarks.compactMap { $0.pdfPageIndex.map { $0 + 1 } })
        return Group {
            if items.isEmpty, bookmarks.isEmpty {
                Text("No table of contents")
                    .foregroundStyle(theme.muted)
                    .frame(width: 260, height: 76)
                    .background(theme.elevated)
                    .presentationBackground(theme.elevated)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !bookmarks.isEmpty {
                        ContentsSectionHeader(title: "BOOKMARKS", theme: theme)
                        ForEach(bookmarks) { bookmark in
                            let page = (bookmark.pdfPageIndex ?? 0) + 1
                            ContentsBookmarkRow(
                                kicker: "Page \(page)",
                                // Bookmarks made before 3.4 stored "Page N"
                                // as their snippet; that is the kicker now.
                                snippet: bookmark.snippet == "Page \(page)" ? "" : bookmark.snippet,
                                theme: theme,
                                accessibilityLabel: "Bookmark on page \(page)",
                                onJump: {
                                    controller.goToPage(bookmark.pdfPageIndex ?? 0)
                                    dismiss()
                                },
                                onRemove: { onRemoveBookmark?(bookmark) }
                            )
                        }
                    }
                    if !items.isEmpty {
                        ContentsSectionHeader(title: "CONTENTS", theme: theme)
                        ForEach(items) { item in
                            row(item, bookmarked: bookmarkedPages.contains(item.pageNumber ?? -1))
                        }
                    }
                }
                .padding(.top, 6)
                .contentsPopoverFrame(theme: theme)
            }
        }
        .onAppear { items = controller.outlineItems() }
    }

    private func row(_ item: PDFReaderController.OutlineItem, bookmarked: Bool) -> some View {
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
                if bookmarked {
                    ContentsBookmarkMarker(theme: theme)
                        .accessibilityHidden(true)
                }
                if let page = item.pageNumber {
                    Text("\(page)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.muted)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .padding(.leading, CGFloat(item.depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityHint(bookmarked ? "Has a bookmark" : "")
        .disabled(item.destination == nil)
    }
}
#endif
