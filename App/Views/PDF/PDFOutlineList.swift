import SwiftUI

#if canImport(PDFKit)
import PDFKit

/// TOC popover content: the PDF outline flattened into an indented list.
/// Items are snapshotted on appear — an outline never changes while a
/// document is open, so there's nothing to observe.
struct PDFOutlineList: View {
    let controller: PDFReaderController
    /// Host closes the popover; rows call this after jumping.
    var dismiss: () -> Void

    @State private var items: [PDFReaderController.OutlineItem] = []

    var body: some View {
        Group {
            if items.isEmpty {
                Text("No table of contents")
                    .foregroundStyle(.secondary)
                    .frame(width: 260, height: 76)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 320, height: 400)
            }
        }
        .onAppear { items = controller.outlineItems() }
    }

    private func row(_ item: PDFReaderController.OutlineItem) -> some View {
        Button {
            controller.jump(to: item)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if let page = item.pageNumber {
                    Text("\(page)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
