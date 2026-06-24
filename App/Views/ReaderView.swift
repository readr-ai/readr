import SwiftUI
import ReadrKit

/// Minimal reading view for M1: renders chapter text and remembers the chapter
/// the reader is on. The Readium-backed paginated renderer (with proper
/// reflow, fonts, and highlight decorations) replaces this within M1; the
/// select-text → Ask panel arrives in M3.
struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    let book: Book

    @State private var chapterIndex = 0

    private var chapter: Chapter? {
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let chapter {
                    if let title = chapter.title {
                        Text(title).font(.title2.bold())
                    }
                    Text(chapter.text)
                        .font(.body)
                        .textSelection(.enabled)
                } else {
                    Text("This book has no readable content.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding()
        }
        .navigationTitle(book.metadata.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    chapterIndex = max(0, chapterIndex - 1)
                } label: { Image(systemName: "chevron.left") }
                    .disabled(chapterIndex == 0)
                Button {
                    chapterIndex = min(book.chapters.count - 1, chapterIndex + 1)
                } label: { Image(systemName: "chevron.right") }
                    .disabled(chapterIndex >= book.chapters.count - 1)
            }
        }
        .onAppear {
            chapterIndex = model.position(for: book)?.chapterIndex ?? 0
        }
        .onChange(of: chapterIndex) { _, newValue in
            model.savePosition(ReadingPosition(chapterIndex: newValue), for: book)
        }
    }
}
