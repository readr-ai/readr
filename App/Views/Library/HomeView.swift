import SwiftUI
import ReadrKit

/// Home: resume reading and see what's new — content first, zero
/// merchandising (per docs/DESIGN.md). An empty library gets the welcome
/// state: import guidance plus a nudge to connect an AI provider.
///
/// Marginalia styling: serif section headers with faint counts, flat covers
/// with hairline progress marks, and the ink-pill Continue affordance.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let openBook: (Book) -> Void
    @Binding var isImporting: Bool
    @Binding var showSettings: Bool

    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        #if os(iOS)
        // Inline: the serif in-content header is the screen title; a large
        // nav-bar title would duplicate it.
        main.navigationBarTitleDisplayMode(.inline)
        #else
        main
        #endif
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
            if model.books.isEmpty {
                emptyState
            } else {
                shelves
            }
        }
        .background(theme.background)
        // The serif in-content "Home" header IS the title; an empty nav title
        // avoids the doubled "Home / Home" seen in the CI screenshots. macOS
        // keeps a window title for Mission Control/window menus.
        #if os(iOS)
        .navigationTitle("")
        #else
        .navigationTitle("Home")
        #endif
    }

    /// Serif screen header with the shared settings/Import… buttons (the
    /// design keeps them in content, not the system toolbar).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Home")
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkColor)
            Spacer(minLength: 12)
            LibraryHeaderButtons(
                isImporting: $isImporting,
                showSettings: $showSettings,
                theme: theme
            )
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 8)
    }

    // MARK: Shelves

    private var shelves: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !model.continueReading.isEmpty {
                    sectionHeader("Continue Reading", count: model.continueReading.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(model.continueReading) { book in
                                // Computed per card, per render, from the
                                // app's cached chapter lengths and its
                                // published positions: cheap, and current
                                // the moment the reader saves a position —
                                // "Chapter 7 of 24" is right after a session,
                                // and Recap never vanishes because a cache
                                // was built before the book was opened.
                                let summary = positionSummary(for: book)
                                ContinueReadingCard(
                                    book: book,
                                    coverImage: model.coverImage(for: book),
                                    progress: LibraryProgress.fraction(
                                        for: book, position: model.position(for: book)
                                    ),
                                    minutesLeft: minutesLeft(in: book),
                                    theme: theme,
                                    action: { openBook(book) },
                                    position: summary,
                                    onRecap: summary == nil ? nil : {
                                        // Open the book, then the recap: the
                                        // reader picks the id up on appearance.
                                        model.pendingRecapBookID = book.id
                                        openBook(book)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 36)
                        // Vertical breathing room so cover shadows don't clip.
                        .padding(.vertical, 12)
                    }
                }
                if !model.recentlyAdded.isEmpty {
                    sectionHeader("Recently Added", count: model.recentlyAdded.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 24) {
                            ForEach(Array(model.recentlyAdded.prefix(12))) { book in
                                RecentlyAddedCard(
                                    book: book,
                                    coverImage: model.coverImage(for: book),
                                    theme: theme
                                ) {
                                    openBook(book)
                                }
                            }
                        }
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
    }

    /// Serif section headings with a faint count — reading-related headings
    /// use the book face (chrome elsewhere stays system sans, per the visual
    /// system). The title stays its own Text element: the UI tests assert on
    /// `staticTexts["Continue Reading"]`.
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkColor)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(theme.faint)
        }
        .padding(.horizontal, 36)
        .padding(.top, 10)
    }

    /// "Chapter 7 of 24" for the resume card — and, when present, the Recap
    /// action. Same rule as `minutesLeft`: a PDF page is not a reading
    /// position, so PDFs get neither. Built from the cached chapter lengths,
    /// so it is safe to compute in body.
    private func positionSummary(for book: Book) -> ReadingPositionSummary? {
        guard !model.isPDF(book),
              let position = model.position(for: book),
              position.pdfPageIndex == nil else { return nil }
        return ReadingPositionSummary(
            book: book, position: position, lengths: model.readingLengths(for: book)
        )
    }

    /// "~N min left in chapter" for the resume card, when a position is saved.
    /// PDF positions get no estimate: their chapterIndex/characterOffset don't
    /// track the page, so a chapter-text estimate would be meaningless.
    private func minutesLeft(in book: Book) -> Int? {
        guard let position = model.position(for: book),
              position.pdfPageIndex == nil,
              book.chapters.indices.contains(position.chapterIndex) else { return nil }
        let minutes = ReadingTimeEstimator().minutesLeft(
            in: model.readingLengths(for: book), at: ReadingFrontier(position)
        )
        return minutes > 0 ? minutes : nil
    }

    // MARK: Empty state

    /// U1: platform-correct empty-library detail. macOS keeps the drag-from-
    /// Finder language (drag-drop import works everywhere on the Mac); iOS has
    /// no Finder/window, so it just invites an import.
    private var emptyStateDetail: String {
        #if os(macOS)
        return "Import an EPUB, PDF, or plain-text book to start reading — or just drag files from Finder anywhere into this window."
        #else
        return "Import a file to start reading — an EPUB, PDF, or plain-text book."
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            emptyBookGlyph
            // Its own element on purpose: the empty-library UI test
            // asserts on this exact string.
            Text("Your library is empty")
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkColor)
            // U1: platform-aware copy. Mac users get the drag-from-Finder
            // affordance; iOS has no Finder or window, so it just invites an
            // import (matches the empty-state mockups).
            Text(emptyStateDetail)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 340)
            Button {
                isImporting = true
            } label: {
                Text("Import a book")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.background)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.inkColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.import")
            .padding(.top, 6)

            if model.activeProvider() == nil {
                providerCard
                    .padding(.top, 28)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The design's empty-book outline: a faint jacket with a spine seam and
    /// the ✦ mark resting inside.
    private var emptyBookGlyph: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(theme.faint, lineWidth: 1.5)
            .frame(width: 54, height: 70)
            .overlay(alignment: .leading) {
                theme.faint
                    .frame(width: 1)
                    .padding(.vertical, 1.5)
                    .padding(.leading, 7)
            }
            .overlay {
                Text(AppTheme.aiGlyph)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.faint)
            }
            .accessibilityHidden(true)
    }

    /// A small secondary card nudging provider setup — only while no provider
    /// is active, so a configured app never nags.
    private var providerCard: some View {
        HStack(spacing: 12) {
            Text(AppTheme.aiGlyph)
                .font(.system(size: 17))
                .foregroundStyle(theme.iris)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect an AI provider")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                Text("Ask your books questions and turn highlights into articles.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 12)
            Button {
                showSettings = true
            } label: {
                Text("Set Up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkColor)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.elevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.line, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.connectProvider")
        }
        .padding(16)
        .frame(maxWidth: 440)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1)
        )
    }
}

/// A large resume card: cover, title, hairline progress, minutes-left
/// estimate, and the ink-pill Continue affordance. The card is one button —
/// one click resumes at the exact saved position — with a "where am I" line
/// beneath it that carries the ✦ Recap action when the book has a position
/// to recap up to.
///
/// Internal (not private) so the macOS snapshot suite can measure two cards
/// side by side and assert the shelf stays aligned.
struct ContinueReadingCard: View {
    let book: Book
    let coverImage: PlatformImage?
    let progress: Double?
    let minutesLeft: Int?
    let theme: ReadingTheme
    let action: () -> Void
    /// "Chapter 7 of 24"; nil for a PDF or an unopened book.
    var position: ReadingPositionSummary? = nil
    /// Open the book and recap it. Nil hides the action.
    var onRecap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            resumeButton
            whereAmI
        }
        .frame(width: 150, alignment: .leading)
    }

    /// "Chapter 7 of 24" and ✦ Recap, on one line of reserved height so every
    /// card on the shelf stays the same height — a PDF card shows the line
    /// blank rather than shorter. Outside `resumeButton`: a button inside a
    /// button is a tap with two owners.
    private var whereAmI: some View {
        HStack(spacing: 8) {
            Text(position?.chapterLine ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(position == nil)
            Spacer(minLength: 0)
            if let onRecap {
                // The one iris moment on the shelf: the ✦ AI mark.
                Button(action: onRecap) {
                    Text("\(AppTheme.aiGlyph) Recap")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.iris)
                        .fixedSize()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Recap what you've read so far, spoiler-free")
                .accessibilityLabel("Recap \(book.metadata.title) so far")
                .accessibilityIdentifier("library.recap")
            }
        }
        .frame(height: 16)
    }

    /// The card proper, as one button.
    private var resumeButton: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Same slot width as Recently Added — the two shelves must
                // read as ONE bookshelf (mismatched jacket sizes looked like
                // a layout bug), and the slot rests covers of any aspect on
                // its bottom-leading corner (see BookCoverView.Slot).
                BookCoverView.Slot(book: book, coverImage: coverImage, width: 150)
                // Every row below the jacket keeps a fixed height, so the
                // hairline, the percentage and the Continue pill sit on the
                // same line across the whole shelf. Without the reserved
                // space a one-line title (or a book with no author) pulls its
                // card's controls up and the row reads as broken.
                CardCaption(book: book, theme: theme)
                LibraryProgressHairline(
                    fraction: progress,
                    isFinished: false,
                    theme: theme
                )
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.background)
                        // Never wraps ("Contin/ue" on the 150pt card — seen
                        // in the CI gallery); the minutes text yields instead.
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.inkColor))
                    if let minutesLeft {
                        Text("~\(minutesLeft) min left")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .padding(.top, 2)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.metadata.title)
    }
}

/// A standard cover card for the Recently Added row.
///
/// Internal for the same reason as `ContinueReadingCard` — the alignment
/// snapshot test measures it.
struct RecentlyAddedCard: View {
    let book: Book
    let coverImage: PlatformImage?
    let theme: ReadingTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // Matches the Continue Reading slot exactly — one shelf, one
                // jacket size (see the note there).
                BookCoverView.Slot(book: book, coverImage: coverImage, width: 150)
                CardCaption(book: book, theme: theme)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.metadata.title)
    }
}
