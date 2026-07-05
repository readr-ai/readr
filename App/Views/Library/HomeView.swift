import SwiftUI
import ReadrKit

/// Home: resume reading and see what's new — content first, zero
/// merchandising (per docs/DESIGN.md). An empty library gets the welcome
/// state: import guidance plus a nudge to connect an AI provider.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let openBook: (Book) -> Void
    @Binding var isImporting: Bool
    @Binding var showSettings: Bool

    var body: some View {
        Group {
            if model.books.isEmpty {
                emptyState
            } else {
                shelves
            }
        }
        .navigationTitle("Home")
        .toolbar {
            LibraryToolbarItems(isImporting: $isImporting, showSettings: $showSettings)
        }
    }

    // MARK: Shelves

    private var shelves: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !model.continueReading.isEmpty {
                    header("Continue Reading")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(model.continueReading) { book in
                                ContinueReadingCard(
                                    book: book,
                                    coverImage: model.coverImage(for: book),
                                    progress: LibraryProgress.fraction(
                                        for: book, position: model.position(for: book)
                                    ),
                                    minutesLeft: minutesLeft(in: book)
                                ) {
                                    openBook(book)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        // Vertical breathing room so cover shadows don't clip.
                        .padding(.vertical, 12)
                    }
                }
                if !model.recentlyAdded.isEmpty {
                    header("Recently Added")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(Array(model.recentlyAdded.prefix(12))) { book in
                                RecentlyAddedCard(
                                    book: book,
                                    coverImage: model.coverImage(for: book)
                                ) {
                                    openBook(book)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
        }
    }

    /// Serif section headings — reading-related headings use the book face
    /// (chrome elsewhere stays system sans, per the visual system).
    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .fontDesign(.serif)
            .padding(.horizontal, 24)
            .padding(.top, 8)
    }

    /// "~N min left in chapter" for the resume card, when a position is saved.
    private func minutesLeft(in book: Book) -> Int? {
        guard let position = model.position(for: book),
              book.chapters.indices.contains(position.chapterIndex) else { return nil }
        let minutes = ReadingTimeEstimator().minutesLeft(
            inChapterText: book.chapters[position.chapterIndex].text,
            fromCharacterOffset: position.characterOffset
        )
        return minutes > 0 ? minutes : nil
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 52))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.bottom, 8)
                Text("Welcome to Readr")
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.serif)
                // Its own element on purpose: the empty-library UI test
                // asserts on this exact string.
                Text("Your library is empty")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Import an EPUB, PDF, or plain-text book to start reading — or just drag files from Finder anywhere into this window.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button {
                    isImporting = true
                } label: {
                    Label("Import a Book", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("home.import")
                .padding(.top, 8)

                if model.activeProvider() == nil {
                    providerCard
                        .padding(.top, 28)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(32)
            .padding(.top, 40)
        }
    }

    /// A small secondary card nudging provider setup — only while no provider
    /// is active, so a configured app never nags.
    private var providerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect an AI provider")
                    .font(.headline)
                Text("Ask your books questions and turn highlights into articles.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Set Up") { showSettings = true }
                .accessibilityIdentifier("home.connectProvider")
        }
        .padding(16)
        .frame(maxWidth: 440)
        .background(
            Color.gray.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

/// A large resume card: cover, title, progress, minutes-left estimate, and an
/// explicit Continue affordance. The whole card is one button — one click
/// resumes at the exact saved position.
private struct ContinueReadingCard: View {
    let book: Book
    let coverImage: PlatformImage?
    let progress: Double?
    let minutesLeft: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                BookCoverView(book: book, coverImage: coverImage, width: 140)
                Text(book.metadata.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let author = book.metadata.authors.first {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: progress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "book.fill")
                        Text("Continue")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppTheme.accent))
                    if let minutesLeft {
                        Text("~\(minutesLeft) min left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
            .frame(width: 190, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.metadata.title)
    }
}

/// A standard cover card for the Recently Added row.
private struct RecentlyAddedCard: View {
    let book: Book
    let coverImage: PlatformImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                BookCoverView(book: book, coverImage: coverImage, width: 120)
                Text(book.metadata.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let author = book.metadata.authors.first {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.metadata.title)
    }
}
