import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The reader window (v2): a themed reading surface with TOC / bookmarks /
/// in-book search navigation, an Appearance popover, select-to-annotate (the
/// popover lives in `SelectableTextView`), the Ask panel, and the Notes
/// inspector. PDFs render natively via `PDFReaderView` — which brings its own
/// nav toolbar (TOC/thumbnails/search/bookmark) — unless the reader switches
/// to the extracted-text "Reading view" in Appearance.
struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    let book: Book

    @State private var chapterIndex = 0
    /// Reading anchor (character offset into the current chapter) in paged
    /// layouts — drives position persistence, bookmark anchors, and
    /// programmatic jumps. Scroll mode anchors to the chapter start.
    @State private var pagedAnchor = 0
    @State private var didRestorePosition = false
    @State private var askSelection: Selection?
    /// The committed text selection in chapter coordinates, reported by the
    /// reading surfaces. Drives the selection-dependent keyboard shortcuts
    /// (⇧⌘H highlight, ⇧⌘M note, and the selection-aware ⇧⌘A ask) — the
    /// selection itself lives inside the platform text views.
    ///
    /// Held in a render-inert box, NOT as observed `Range<Int>?` state:
    /// nothing rendered reads it (only the shortcut/Ask actions do), and the
    /// surfaces report on every selection change — mid-gesture. An observed
    /// write there re-renders the whole reader while the long-press is still
    /// down, which broke the press → annotation-bar → highlight flow on iOS
    /// (testHighlightFromSelectionAppearsInNotesPanel, red on the merge of
    /// the shortcuts PR). The box keeps the shortcuts' view of the selection
    /// current without ever invalidating the view tree.
    @State private var currentSelection = SelectionMirror()
    /// Published by PDFReaderView while the native PDF surface is mounted, so
    /// the shortcuts and the toolbar Ask can reach the PDFKit selection (it
    /// lives in the surface's private controller). This view owns EVERY
    /// annotation-shortcut registration and dispatches per mode — a single
    /// owner, so no mode can register a duplicate key equivalent.
    @State private var pdfAnnotationActions: PDFAnnotationActions?
    @State private var showAsk = false
    @State private var showNotes = false
    @State private var showTOC = false
    @State private var showSearch = false
    @State private var showAppearance = false
    /// Highlight whose note is being edited; drives the NoteEditor sheet.
    @State private var editingNote: Highlight?
    @State private var noteDraft = ""
    /// Highlight created implicitly by the Note action (create mode). Cancel
    /// deletes exactly this one so dismissing the editor doesn't strand a
    /// highlight the reader never asked to keep.
    @State private var noteFlowCreatedHighlightID: UUID?
    /// In-flight debounced position save (offset-only page turns).
    @State private var savePositionTask: Task<Void, Never>?
    /// Scroll mode: character offset the text view should scroll to (set by
    /// `jump`, cleared by SelectableTextView once performed).
    @State private var scrollTarget: Int?
    /// Whole-chapter "min left" for the scroll footer. Word-counting is
    /// O(chapter length), so it runs on chapter change — never in body.
    @State private var minutesCache: (chapterID: UUID, minutes: Int)?

    /// Persisted reading layout: continuous scroll, one page, or facing pages.
    @AppStorage("readerLayout") private var layoutRaw = PageLayout.scroll.rawValue
    /// Persisted appearance: reading theme (Paper/Sepia/Night) and text size.
    @AppStorage("readingTheme") private var themeRaw = ReadingTheme.paper.rawValue
    @AppStorage("readingFontSize") private var fontSize = 18.0
    /// Persisted typography: body typeface, line-spacing preset, and
    /// justification (the Apple-Books-style text controls).
    @AppStorage("readingFont") private var fontRaw = ReaderFont.newYork.rawValue
    @AppStorage("readingLineSpacing") private var lineSpacingRaw
        = ReaderLineSpacing.normal.rawValue
    @AppStorage("readingJustified") private var isJustified = true
    /// PDFs: show the original pages (native PDFKit) or the extracted text
    /// (which keeps text-mode highlights and layouts available).
    @AppStorage("pdfShowsOriginal") private var pdfShowsOriginal = true
    /// Most recent marker color, shared with the PDF reader (same key) so a
    /// new highlight anywhere defaults to the reader's last choice.
    @AppStorage("lastHighlightColor") private var lastHighlightColorRaw
        = HighlightColor.yellow.rawValue

    private var lastHighlightColor: HighlightColor {
        HighlightColor(rawValue: lastHighlightColorRaw) ?? .yellow
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Apple-Books-style distraction-free reading: a tap on the middle of the
    /// page hides ALL chrome (nav bar, bottom bar, status bar), another tap
    /// brings it back. Taps near the column's left/right edges turn pages in
    /// paged mode instead (see PagedChapterView). Starts visible so a reader
    /// opening a book sees where the controls live.
    @State private var showChrome = true

    /// Regular width (iPad full screen / wide multitasking): the nav bar has
    /// room for the full reader chrome, so the iPhone bottom bar — a
    /// workaround for the compact nav bar collapsing trailing items past two
    /// (see `toolbarContent`) — steps aside and everything rides up top,
    /// macOS-style. `nil` (undetermined) falls back to the compact
    /// arrangement, as does an iPad squeezed to compact in Split View.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    #endif

    private var layout: PageLayout {
        let stored = PageLayout(rawValue: layoutRaw) ?? .scroll
        #if os(iOS)
        // iOS offers single page + scroll only (like Apple Books on iPhone):
        // a facing-page spread doesn't make sense on a handheld screen, so a
        // stored doublePage preference (e.g. synced defaults from a Mac)
        // renders as single pages. The Appearance popover hides the segment.
        if stored == .doublePage {
            return .singlePage
        }
        #endif
        return stored
    }

    /// Everything the text renderer needs, derived from the persisted
    /// appearance settings (clamped in case stored values drift out of range).
    private var style: ReaderStyle {
        ReaderStyle(
            theme: ReadingTheme(rawValue: themeRaw) ?? .paper,
            fontSize: min(
                max(CGFloat(fontSize), ReaderStyle.fontSizeRange.lowerBound),
                ReaderStyle.fontSizeRange.upperBound
            ),
            font: ReaderFont(rawValue: fontRaw) ?? .newYork,
            spacing: ReaderLineSpacing(rawValue: lineSpacingRaw) ?? .normal,
            isJustified: isJustified
        )
    }

    /// True while the native PDF view is on screen. It supplies its own
    /// TOC/search/bookmark toolbar, so the text-mode items step aside and the
    /// chapter chevrons disable (PDF pages, not chapters, are the unit there).
    private var isPDFOriginal: Bool {
        pdfShowsOriginal && model.isPDF(book) && model.sourceURL(for: book) != nil
    }

    private var chapter: Chapter? {
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var body: some View {
        content
            .navigationTitle(book.metadata.title)
            #if os(macOS)
            // Toolbar center per spec: book title · chapter title.
            .navigationSubtitle(chapter?.title ?? "")
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            #if os(iOS)
            // The tap-to-hide chrome (Apple Books): everything disappears —
            // including the status bar — leaving just the page and its quiet
            // page label. Sheets and popovers anchor to toolbar buttons, so
            // they're reachable only while chrome is shown, as in Books.
            .toolbar(showChrome ? .visible : .hidden, for: .navigationBar)
            .toolbar(showChrome ? .visible : .hidden, for: .bottomBar)
            .statusBarHidden(!showChrome)
            #endif
            .background(hiddenFontShortcuts)
            .background(hiddenAnnotationShortcuts)
            .sheet(isPresented: $showAsk) {
                AskPanelView(app: model, book: book, selection: askSelection)
                    .environmentObject(model)
            }
            .sheet(item: $editingNote) { highlight in
                NoteEditor(
                    quotedText: highlight.quotedText,
                    text: $noteDraft,
                    onSave: {
                        var updated = highlight
                        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.note = trimmed.isEmpty ? nil : trimmed
                        model.updateHighlight(updated)
                        noteFlowCreatedHighlightID = nil
                    },
                    // Cancelling a note on a highlight that was created just
                    // for this note flow removes it again — but cancelling an
                    // edit of an existing highlight's note must keep the
                    // highlight.
                    onCancel: noteFlowCreatedHighlightID == highlight.id
                        ? {
                            model.removeHighlight(highlight, in: book)
                            noteFlowCreatedHighlightID = nil
                        }
                        : nil
                )
            }
            .inspector(isPresented: $showNotes) {
                NotesPanel(
                    book: book,
                    onJumpHighlight: { highlight in
                        guard let index = book.chapters.firstIndex(
                            where: { $0.id == highlight.chapterID }
                        ) else { return }
                        jump(toChapter: index, offset: highlight.range.lowerBound)
                        // iPhone: the inspector is a covering sheet — close it
                        // so the reader sees the jump land. iPad/macOS side
                        // columns stay open beside the page.
                        #if os(iOS)
                        if UIDevice.current.userInterfaceIdiom == .phone {
                            showNotes = false
                        }
                        #endif
                    },
                    // Jumping to a PDF page needs a page binding into
                    // PDFReaderView; v2 ships without one.
                    onJumpPDF: nil,
                    onClose: { showNotes = false }
                )
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
            }
            .onAppear {
                restoreOnce()
                updateMinutesCache()
            }
            .onDisappear {
                // Flush the debounced page-turn save — closing the reader
                // must never lose the last position.
                savePositionTask?.cancel()
                savePositionTask = nil
                saveTextPosition(chapterIndex: chapterIndex, characterOffset: pagedAnchor)
            }
            .onChange(of: chapterIndex) { _, newValue in
                // Chapter turns are rare — save immediately, and drop any
                // pending offset-only save (its offset belongs to the old
                // chapter).
                savePositionTask?.cancel()
                savePositionTask = nil
                saveTextPosition(chapterIndex: newValue, characterOffset: pagedAnchor)
                updateMinutesCache()
                // The selection's range belongs to the old chapter. The text
                // views also report nil when their content is replaced, but
                // that arrives async — clear eagerly so a shortcut can't race
                // it and annotate the wrong range. (Surface teardown — layout
                // switch, PDF display toggle — needs no clear here: the text
                // views report nil from onDisappear.)
                currentSelection.value = nil
            }
            .onChange(of: pagedAnchor) { _, newValue in
                // A page turn replaces the visible text: the collapse report
                // arrives async, so clear eagerly — same race as a chapter
                // turn, just within one chapter.
                currentSelection.value = nil
                // Page turns come in bursts and every save rewrites the whole
                // library JSON — debounce offset-only saves. Chapter changes
                // and onDisappear flush immediately.
                savePositionTask?.cancel()
                savePositionTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    saveTextPosition(chapterIndex: chapterIndex, characterOffset: newValue)
                }
            }
            // Build the retrieval index in the background when the book opens
            // so the first "ask" is fast. Safe to call repeatedly.
            .task(id: book.id) { await model.ensureIndexed(book) }
    }

    // MARK: - Reading surface

    private var content: some View {
        Group {
            if let url = model.sourceURL(for: book), model.isPDF(book), pdfShowsOriginal {
                PDFReaderView(
                    book: book,
                    url: url,
                    onAsk: { selection in
                        askSelection = selection
                        showAsk = true
                    },
                    annotationActions: $pdfAnnotationActions
                )
            } else if let chapter {
                readingSurface(for: chapter)
            } else {
                ContentUnavailableView("No readable content", systemImage: "doc")
            }
        }
    }

    private func readingSurface(for chapter: Chapter) -> some View {
        let images = model.inlineImages(for: book, chapter: chapter)
        let spans = highlightSpans(for: chapter)
        return VStack(spacing: 0) {
            if layout == .scroll {
                ScrollReadingColumn(
                    chapter: chapter,
                    style: style,
                    highlights: spans,
                    inlineImages: images,
                    scrollTarget: $scrollTarget,
                    onAnnotate: { target, action in
                        handleAnnotation(in: chapter, target: target, action: action)
                    },
                    onSelectionChange: { currentSelection.value = $0 },
                    onChromeToggle: toggleChrome
                )
                // Scroll mode has no pages, but a horizontal flick still
                // crosses chapters — the paged layouts flow across chapter
                // walls on swipe, and the default layout offering no swipe
                // at all reads as broken navigation.
                .modifier(ChapterSwipe { direction in
                    if direction > 0, chapterIndex < book.chapters.count - 1 {
                        jump(toChapter: chapterIndex + 1, offset: 0)
                    } else if direction < 0, chapterIndex > 0 {
                        jump(toChapter: chapterIndex - 1, offset: 0)
                    }
                })
                scrollFooter(for: chapter)
            } else {
                // Paged modes draw their own footer (progress track + page x
                // of y · min left) because pagination happens inside the
                // view; the chapter kicker renders on the first page.
                PagedChapterView(
                    chapter: chapter,
                    layout: layout,
                    style: style,
                    highlights: spans,
                    inlineImages: images,
                    anchorOffset: $pagedAnchor,
                    onAnnotate: { target, action in
                        handleAnnotation(in: chapter, target: target, action: action)
                    },
                    onSelectionChange: { currentSelection.value = $0 },
                    onChromeToggle: toggleChrome,
                    canOverflowBackward: chapterIndex > 0,
                    canOverflowForward: chapterIndex < book.chapters.count - 1,
                    onOverflow: { direction in
                        // Paging past a chapter's edge flows into the next/
                        // previous chapter: forward lands on its first page,
                        // backward on its LAST (an end-of-text offset — the
                        // paginator clamps it into the final page).
                        if direction > 0, chapterIndex < book.chapters.count - 1 {
                            jump(toChapter: chapterIndex + 1, offset: 0)
                        } else if direction < 0, chapterIndex > 0 {
                            let previous = chapterIndex - 1
                            jump(
                                toChapter: previous,
                                offset: max(0, book.chapters[previous].text.count - 1)
                            )
                        }
                    }
                )
            }
        }
        // The theme owns the entire surface. Scroll mode floats a centered
        // paper column over the deeper chrome `background` (its footer sits on
        // it too); paged mode is full-bleed paper — the page IS the window — so
        // the surface behind it must be `paper`, not the chrome color.
        .background((layout == .scroll ? style.theme.background : style.theme.paper).ignoresSafeArea())
    }

    /// iOS only: flips the chrome in/out (the reading surfaces report clean
    /// middle-of-the-page taps here). No-op on macOS, where chrome lives in
    /// the window toolbar and never hides.
    private func toggleChrome() {
        #if os(iOS)
        withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() }
        #endif
    }

    /// Scroll mode has no page anchor, so the estimate covers the whole
    /// chapter (see docs/DESIGN.md — "in scroll mode base it on chapter start")
    /// and the progress track fills by position in the book. Reads
    /// `minutesCache` (refreshed on appear/chapter change) because
    /// word-counting the chapter in body would rescan it on every render.
    private func scrollFooter(for chapter: Chapter) -> some View {
        let minutes = minutesCache?.chapterID == chapter.id
            ? (minutesCache?.minutes ?? 0)
            : 0
        let fraction = book.chapters.isEmpty
            ? 0
            : Double(chapterIndex + 1) / Double(book.chapters.count)
        return HStack(spacing: 14) {
            ReaderProgressTrack(
                fraction: fraction,
                ink: style.theme.inkColor,
                track: style.theme.line
            )
            if minutes > 0 {
                Text("~\(minutes) min left in chapter")
                    .font(.system(size: 11))
                    .foregroundStyle(style.theme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(style.theme.line).frame(height: 1)
        }
    }

    private func updateMinutesCache() {
        guard let chapter else {
            minutesCache = nil
            return
        }
        guard minutesCache?.chapterID != chapter.id else { return }
        minutesCache = (
            chapterID: chapter.id,
            minutes: ReadingTimeEstimator().minutesLeft(
                inChapterText: chapter.text, fromCharacterOffset: 0
            )
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Chapter chevrons are a macOS-only affordance. On iOS they read
            // as mystery buttons pinned over the page (nothing like Apple
            // Books) — touch navigation is swiping/edge-tapping through pages
            // (paged mode flows across chapter walls), the horizontal flick
            // in scroll mode, and the Contents list.
            #if os(macOS)
            Button { jump(toChapter: chapterIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityIdentifier("prevChapter")
            .accessibilityLabel("Previous chapter")
            .help("Previous chapter")
            .disabled(chapterIndex == 0 || isPDFOriginal)

            Button { jump(toChapter: chapterIndex + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityIdentifier("nextChapter")
            .accessibilityLabel("Next chapter")
            .help("Next chapter")
            .disabled(chapterIndex >= book.chapters.count - 1 || isPDFOriginal)

            if !isPDFOriginal {
                tocButton
                bookmarksMenu
            }
            #else
            // iPad regular width: contents/bookmarks ride up top, macOS-style;
            // compact keeps them in the bottom bar below.
            if isRegularWidth, !isPDFOriginal {
                tocButton
                bookmarksMenu
            }
            #endif
        }
        // Lesson from v1 (twice-observed in CI): the iPhone nav bar silently
        // collapses trailing items past TWO — and a secondaryAction group's
        // "…" button itself counts as one. So COMPACT iOS gets exactly
        // Appearance + Notes up top (UI tests tap `reader.notes` directly)
        // and everything else lives in the bottom bar, Apple-Books style.
        // Regular width (iPad) has nav-bar room like macOS, so it drops the
        // phone bottom bar and carries the full chrome up top — same
        // buttons, same accessibility identifiers, different placement (the
        // UI tests look items up by id, never by bar).
        #if os(iOS)
        if isRegularWidth {
            ToolbarItemGroup(placement: .primaryAction) {
                if !isPDFOriginal {
                    searchButton
                }
                appearanceButton
                askButton
                notesButton
            }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                appearanceButton
                notesButton
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if !isPDFOriginal {
                    tocButton
                    bookmarksMenu
                    Spacer()
                    searchButton
                } else {
                    Spacer()
                }
                askButton
            }
        }
        #else
        // macOS trailing area, Marginalia style: the appearance popover is
        // replaced by inline design controls — layout segments, an A / A font
        // stepper, and three theme dots (the `reader.appearance` id rides on
        // the layout segment container for compatibility).
        ToolbarItemGroup(placement: .primaryAction) {
            if !isPDFOriginal {
                searchButton
            }
            layoutSegmentControl
            fontStepperControl
            themeDotsControl
            if model.isPDF(book) {
                pdfDisplayMenu
            }
            askButton
            notesButton
        }
        #endif
    }

    private var tocButton: some View {
        Button { showTOC = true } label: {
            Label("Contents", systemImage: "list.bullet")
        }
        .accessibilityIdentifier("reader.toc")
        .accessibilityLabel("Table of contents")
        .help("Table of contents")
        .popover(isPresented: $showTOC) {
            // Marginalia-themed contents: serif rows on the elevated surface
            // (the default white List clashed with the reading page — seen in
            // the CI gallery), sized to a half sheet on iPhone instead of a
            // full screen for a handful of rows.
            VStack(alignment: .leading, spacing: 0) {
                Text("CONTENTS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(style.theme.faint)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                List(0..<book.chapters.count, id: \.self) { index in
                    Button {
                        showTOC = false
                        jump(toChapter: index)
                    } label: {
                        Text(book.chapters[index].title ?? "Chapter \(index + 1)")
                            .font(.system(size: 14.5, design: .serif))
                            .fontWeight(index == chapterIndex ? .bold : .regular)
                            .foregroundStyle(style.theme.inkColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(style.theme.line)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            // Height hugs the chapter list (header + ~34pt rows) instead of a
            // fixed ideal — a two-chapter book in an iPad popover was ~60%
            // dead cream below the rows. Long books cap where scrolling
            // takes over; iPhone's sheet detents below override this anyway.
            .frame(
                minWidth: 260, idealWidth: 300,
                idealHeight: min(420, 64 + CGFloat(book.chapters.count) * 34)
            )
            .background(style.theme.elevated)
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
            .presentationBackground(style.theme.elevated)
        }
    }

    private var bookmarksMenu: some View {
        Menu {
            Button(
                currentBookmark == nil ? "Add Bookmark" : "Remove Bookmark",
                action: toggleBookmark
            )
            .keyboardShortcut("d", modifiers: .command)

            let bookmarks = model.bookmarks(for: book)
            if !bookmarks.isEmpty {
                Divider()
                ForEach(bookmarks) { bookmark in
                    Menu {
                        Button("Go to Bookmark") {
                            jump(
                                toChapter: bookmark.chapterIndex,
                                offset: bookmark.characterOffset
                            )
                        }
                        Button("Remove", role: .destructive) {
                            model.removeBookmark(bookmark)
                        }
                    } label: {
                        Text(bookmarkLabel(for: bookmark))
                    }
                }
            }
        } label: {
            Label(
                "Bookmarks",
                systemImage: currentBookmark == nil ? "bookmark" : "bookmark.fill"
            )
        }
        .accessibilityIdentifier("reader.bookmarks")
        .accessibilityLabel("Bookmarks")
        .help("Bookmarks — ⌘D adds or removes one here")
    }

    private var searchButton: some View {
        Button { showSearch = true } label: {
            Label("Find in Book", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityIdentifier("reader.search")
        .accessibilityLabel("Find in book")
        .help("Find in book (⌘F)")
        .popover(isPresented: $showSearch) {
            ReaderSearchPopover(book: book) { index, offset in
                showSearch = false
                jump(toChapter: index, offset: offset)
            }
        }
    }

    #if os(iOS)
    /// iOS keeps the Aa popover (the nav bar has no room for inline
    /// controls); the popover itself is restyled to the Marginalia tokens.
    private var appearanceButton: some View {
        Button { showAppearance = true } label: {
            Label("Appearance", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("reader.appearance")
        .accessibilityLabel("Appearance")
        .help("Appearance — theme, text size (⌘+ / ⌘−), layout")
        .popover(isPresented: $showAppearance) {
            AppearancePopover(
                themeRaw: $themeRaw,
                layoutRaw: $layoutRaw,
                fontSize: $fontSize,
                fontRaw: $fontRaw,
                lineSpacingRaw: $lineSpacingRaw,
                isJustified: $isJustified,
                isPDF: model.isPDF(book),
                pdfShowsOriginal: $pdfShowsOriginal
            )
        }
    }
    #endif

    #if os(macOS)
    /// Inline layout segments: quiet text buttons; the selected one gets a
    /// paper pill. Carries the `reader.appearance` compatibility identifier.
    private var layoutSegmentControl: some View {
        HStack(spacing: 2) {
            layoutSegment("Scroll", .scroll)
            layoutSegment("Page", .singlePage)
            layoutSegment("Spread", .doublePage)
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style.theme.line, lineWidth: 1))
        .help("Reading layout")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.appearance")
        .accessibilityLabel("Appearance")
    }

    private func layoutSegment(_ label: String, _ value: PageLayout) -> some View {
        let selected = layout == value
        return Button { layoutRaw = value.rawValue } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? style.theme.inkColor : style.theme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? style.theme.paper : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label) layout")
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Inline A / A font stepper: serif glyphs, hairline divider and border.
    private var fontStepperControl: some View {
        HStack(spacing: 0) {
            Button { adjustFontSize(-1) } label: {
                Text("A")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(style.theme.inkColor)
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fontSize <= Double(ReaderStyle.fontSizeRange.lowerBound))
            .help("Smaller text (⌘−)")
            .accessibilityLabel("Smaller text")
            .accessibilityIdentifier("appearance.textSmaller")

            Rectangle().fill(style.theme.line).frame(width: 1, height: 25)

            Button { adjustFontSize(+1) } label: {
                Text("A")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(style.theme.inkColor)
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fontSize >= Double(ReaderStyle.fontSizeRange.upperBound))
            .help("Larger text (⌘+)")
            .accessibilityLabel("Larger text")
            .accessibilityIdentifier("appearance.textLarger")
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style.theme.line, lineWidth: 1))
    }

    /// Inline theme dots: 18pt paper swatches with a hairline border; the
    /// selected one gets an ink ring.
    private var themeDotsControl: some View {
        HStack(spacing: 7) {
            ForEach(ReadingTheme.allCases) { option in
                themeDot(option)
            }
        }
        .padding(.horizontal, 4)
    }

    private func themeDot(_ option: ReadingTheme) -> some View {
        let selected = option == style.theme
        return Button { themeRaw = option.rawValue } label: {
            ZStack {
                Circle()
                    .fill(option.paper)
                    .overlay(Circle().strokeBorder(style.theme.line, lineWidth: 1))
                    .frame(width: 18, height: 18)
                if selected {
                    Circle()
                        .strokeBorder(style.theme.inkColor, lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(option.displayName) theme")
        .accessibilityLabel(option.displayName)
        .accessibilityIdentifier("appearance.theme.\(option.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// PDFs keep their display switch in the appearance area: original pages
    /// (native PDFKit) or the extracted reading view.
    private var pdfDisplayMenu: some View {
        Menu {
            Picker("PDF display", selection: $pdfShowsOriginal) {
                Text("Original pages").tag(true)
                Text("Reading view").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("PDF display", systemImage: "doc.richtext")
        }
        .help("Show the PDF's original pages, or its extracted text with highlights")
        .accessibilityLabel("PDF display")
        .accessibilityIdentifier("reader.pdfDisplay")
    }
    #endif

    private var askButton: some View {
        let button = Button(action: askTheBook) {
            #if os(macOS)
            // The one iris moment in the chrome: the ✦ AI mark.
            Text("\(AppTheme.aiGlyph) Ask")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.theme.iris)
                .padding(.horizontal, 4)
            #else
            Label("Ask the Book", systemImage: "sparkles")
            #endif
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .accessibilityIdentifier("reader.ask")
        .accessibilityLabel("Ask the book")
        .help("Ask the book (⇧⌘A) — asks about the selection when text is selected")
        #if os(macOS)
        // Plain style so the iris tint survives the toolbar's own styling.
        return button.buttonStyle(.plain)
        #else
        return button
        #endif
    }

    /// Ask (toolbar button or ⇧⌘A): scoped to the current selection when
    /// there is one — the keyboard mirror of the selection menu's ✦ Ask —
    /// otherwise a whole-book question. The Ask panel shows the quoted
    /// passage, so the scope is always visible. Reaches the text surfaces'
    /// selection via `currentSelection` and the PDF surface's via its
    /// published actions.
    private func askTheBook() {
        if isPDFOriginal {
            askSelection = pdfAnnotationActions?.askSelection()
        } else if let chapter, let selected = currentSelection.value {
            askSelection = model.makeSelection(in: chapter, range: selected)
        } else {
            askSelection = nil // whole-book question
        }
        showAsk = true
    }

    private var notesButton: some View {
        Button { showNotes.toggle() } label: {
            Label("Highlights", systemImage: "highlighter")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .accessibilityIdentifier("reader.notes")
        .accessibilityLabel("Highlights")
        .help("Highlights & notes (⇧⌘N)")
    }

    /// Invisible buttons so ⌘+/⌘− resize text without opening the Appearance
    /// popover — a shortcut registered inside a popover is only live while
    /// that popover is on screen.
    private var hiddenFontShortcuts: some View {
        Group {
            Button("Larger text") { adjustFontSize(+1) }
                .keyboardShortcut("+", modifiers: .command)
            // ⌘= is what most keyboards actually produce for "⌘+".
            Button("Larger text") { adjustFontSize(+1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller text") { adjustFontSize(-1) }
                .keyboardShortcut("-", modifiers: .command)
        }
        .shortcutOnly()
    }

    /// Invisible buttons carrying the annotation shortcuts: ⇧⌘H highlights the
    /// current selection (last-used marker color), ⇧⌘M highlights it and opens
    /// the note editor — the keyboard equivalents of the selection menu's
    /// color dots and Note. No-ops without a selection. In native PDF mode
    /// they dispatch to the PDF surface's published actions; either way this
    /// view is the keys' only registration point.
    private var hiddenAnnotationShortcuts: some View {
        Group {
            Button("Highlight selection") {
                if isPDFOriginal {
                    pdfAnnotationActions?.highlightSelection()
                } else if let chapter, let selected = currentSelection.value {
                    handleAnnotation(
                        in: chapter, target: .selection(selected),
                        action: .highlight(lastHighlightColor)
                    )
                }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Add note to selection") {
                if isPDFOriginal {
                    pdfAnnotationActions?.noteSelection()
                } else if let chapter, let selected = currentSelection.value {
                    handleAnnotation(in: chapter, target: .selection(selected), action: .note)
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        .shortcutOnly()
    }

    private func adjustFontSize(_ delta: Double) {
        fontSize = min(
            max(fontSize + delta, Double(ReaderStyle.fontSizeRange.lowerBound)),
            Double(ReaderStyle.fontSizeRange.upperBound)
        )
    }

    // MARK: - Navigation & position

    /// All chapter/offset navigation funnels through here so the paged anchor
    /// and persisted position stay in sync (chevrons, TOC, bookmarks, search
    /// hits, notes-panel jumps).
    private func jump(toChapter index: Int, offset: Int = 0) {
        guard book.chapters.indices.contains(index) else { return }
        pagedAnchor = max(0, offset)
        chapterIndex = index
        if layout == .scroll {
            // Scroll mode has no anchor binding into the text view — hand it
            // the offset so search hits / bookmarks / notes-panel jumps
            // actually scroll (the text view clears it once performed).
            scrollTarget = max(0, offset)
        }
        // Same-chapter jumps don't fire onChange(of: chapterIndex) — persist
        // explicitly (duplicate saves are harmless).
        savePositionTask?.cancel()
        saveTextPosition(chapterIndex: index, characterOffset: offset)
    }

    /// Persist the text-mode position, PRESERVING the PDF page: both modes
    /// share one `ReadingPosition` record per book, so rebuilding it from
    /// scratch here would wipe the reader's place in the original PDF pages.
    /// (`PDFReaderController` does the mirror-image preservation for the
    /// chapter/offset fields.)
    private func saveTextPosition(chapterIndex: Int, characterOffset: Int) {
        var position = model.position(for: book) ?? ReadingPosition(chapterIndex: 0)
        position.chapterIndex = chapterIndex
        position.characterOffset = max(0, characterOffset)
        model.savePosition(position, for: book)
    }

    /// Restore once; later re-appears (e.g. after dismissing a sheet) must not
    /// clobber the chapter the reader navigated to.
    private func restoreOnce() {
        guard !didRestorePosition else { return }
        didRestorePosition = true
        model.markOpened(book)
        if let position = model.position(for: book) {
            pagedAnchor = max(0, position.characterOffset)
            chapterIndex = min(max(0, position.chapterIndex), max(0, book.chapters.count - 1))
        }
    }

    // MARK: - Bookmarks

    /// The anchor a bookmark toggles at: the visible page start in paged
    /// modes, the chapter start in scroll mode. Matching on the exact offset
    /// keeps ⌘D a true toggle — it removes exactly the bookmark it added.
    private var currentAnchorOffset: Int {
        layout == .scroll ? 0 : pagedAnchor
    }

    private var currentBookmark: Bookmark? {
        model.bookmarks(for: book).first {
            $0.chapterIndex == chapterIndex && $0.characterOffset == currentAnchorOffset
        }
    }

    private func toggleBookmark() {
        if let existing = currentBookmark {
            model.removeBookmark(existing)
        } else if let chapter {
            model.addBookmark(Bookmark(
                bookID: book.id,
                chapterIndex: chapterIndex,
                characterOffset: currentAnchorOffset,
                snippet: bookmarkSnippet(of: chapter, at: currentAnchorOffset),
                createdAt: Date()
            ))
        }
    }

    private func bookmarkLabel(for bookmark: Bookmark) -> String {
        let title = book.chapters.indices.contains(bookmark.chapterIndex)
            ? (book.chapters[bookmark.chapterIndex].title
                ?? "Chapter \(bookmark.chapterIndex + 1)")
            : "Chapter \(bookmark.chapterIndex + 1)"
        return bookmark.snippet.isEmpty
            ? title
            : "\(title) — \u{201C}\(bookmark.snippet)\u{201D}"
    }

    /// ~60 characters of context starting at the bookmarked position.
    /// Sliced with `String.Index` — materializing `Array(chapter.text)` would
    /// copy the whole chapter for a 60-character snippet.
    private func bookmarkSnippet(of chapter: Chapter, at offset: Int, length: Int = 60) -> String {
        let text = chapter.text
        guard let start = text.index(
            text.startIndex, offsetBy: max(0, offset), limitedBy: text.endIndex
        ), start < text.endIndex else { return "" }
        return String(text[start...].prefix(length))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Annotation

    private func highlightSpans(for chapter: Chapter) -> [HighlightSpan] {
        model.highlights(for: book)
            .filter { $0.chapterID == chapter.id }
            .map {
                HighlightSpan(
                    id: $0.id,
                    range: $0.range,
                    color: $0.markerColor,
                    hasNote: !($0.note ?? "").isEmpty
                )
            }
    }

    private func highlight(withID id: UUID) -> Highlight? {
        model.highlights(for: book).first { $0.id == id }
    }

    /// Executes an annotation-menu action against the model. Targets arrive in
    /// chapter coordinates (PagedChapterView already shifted page-local ones).
    private func handleAnnotation(
        in chapter: Chapter, target: AnnotationTarget, action: AnnotationAction
    ) {
        switch action {
        case let .highlight(color):
            // Any color-dot press becomes the new default marker (shared with
            // the PDF reader via `lastHighlightColor`).
            lastHighlightColorRaw = color.rawValue
            switch target {
            case let .selection(range):
                model.addHighlight(in: book, chapter: chapter, range: range, color: color)
            case let .span(span):
                if var existing = highlight(withID: span.id) {
                    existing.color = color
                    model.updateHighlight(existing)
                }
            }

        case .note:
            switch target {
            case let .selection(range):
                // The note editor works on a persisted highlight, so create
                // one first (in the last-used color) — one gesture, per the
                // spec. Remember its id: cancel must remove exactly this one.
                if let created = model.addHighlight(
                    in: book, chapter: chapter, range: range, color: lastHighlightColor
                ) {
                    noteDraft = ""
                    noteFlowCreatedHighlightID = created.id
                    editingNote = created
                }
            case let .span(span):
                if let existing = highlight(withID: span.id) {
                    noteDraft = existing.note ?? ""
                    noteFlowCreatedHighlightID = nil
                    editingNote = existing
                }
            }

        case .ask:
            let range: Range<Int>
            switch target {
            case let .selection(selected):
                range = selected
            case let .span(span):
                range = highlight(withID: span.id)?.range ?? span.range
            }
            askSelection = model.makeSelection(in: chapter, range: range)
            showAsk = true

        case .copy:
            let copied: String
            switch target {
            case let .selection(range):
                copied = substring(of: chapter, range: range)
            case let .span(span):
                copied = highlight(withID: span.id)?.quotedText ?? ""
            }
            // Shared clipboard helper (AnnotationListView). Skip empty text so
            // a failed lookup doesn't clear the clipboard.
            if !copied.isEmpty { Pasteboard.copy(copied) }

        case .remove:
            if case let .span(span) = target, let existing = highlight(withID: span.id) {
                model.removeHighlight(existing, in: book)
            }
        }
    }

    /// Slices with `String.Index` — materializing `Array(chapter.text)` would
    /// copy the whole chapter per copy action.
    private func substring(of chapter: Chapter, range: Range<Int>) -> String {
        let text = chapter.text
        let lowerOffset = max(0, range.lowerBound)
        guard range.upperBound > lowerOffset,
              let lower = text.index(
                  text.startIndex, offsetBy: lowerOffset, limitedBy: text.endIndex
              )
        else { return "" }
        // prefix clamps to the text's end, matching the old upper-bound clamp.
        return String(text[lower...].prefix(range.upperBound - lowerOffset))
    }
}

// MARK: - Selection mirror

/// Render-inert holder for the reading surfaces' committed selection. A plain
/// class in a `@State` slot: SwiftUI keeps the instance stable across body
/// re-evaluations, but writes to `value` do not invalidate any view — which
/// is the point. Selection reports arrive on every delegate callback,
/// including mid-gesture, and must never re-render the reader out from under
/// an in-flight touch (see the `currentSelection` doc in `ReaderView`).
final class SelectionMirror {
    var value: Range<Int>?
}

// MARK: - Chapter swipe (scroll mode)

/// Scroll mode's chapter-crossing flick: left → next chapter, right →
/// previous. The text view's own pan owns vertical scrolling, so this rides
/// `simultaneousGesture` and fires only on decisive horizontal flicks — the
/// same dominance + velocity thresholds as the paged `SwipeToTurn`, so
/// vertical scrolls and near-stationary selection-handle drags never
/// trigger. iOS-only: on macOS a pointer drag over text IS selection, and
/// trackpad swipes belong to the paged surface's event monitor.
private struct ChapterSwipe: ViewModifier {
    let onSwipe: (Int) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) * 1.2,
                          abs(value.velocity.width) > 220 else { return }
                    onSwipe(h < 0 ? +1 : -1)
                }
        )
        #else
        content
        #endif
    }
}

// MARK: - Shortcut-only buttons

private extension View {
    /// Container treatment for Buttons that exist only to register keyboard
    /// shortcuts: invisible and zero-size but still installed — `opacity(0)`
    /// keeps key equivalents live where `.hidden()` would not — and out of
    /// the accessibility tree (the visible controls carry the labels).
    func shortcutOnly() -> some View {
        opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Scroll-mode reading column

/// Scroll mode's reading surface: full-bleed paper with a centered column and
/// the chapter kicker (caps, faint) leading it. Extracted from ReaderView so
/// the macOS snapshot suite can render the real scroll layout (m08).
///
/// The column width is a font-relative measure — about 80 characters per line
/// at any text size — rather than a fixed point cap: a fixed 640pt read as
/// oversized margins on desktop windows, and it stranded large text at a
/// cramped character count. Phone widths are narrower than the measure, so
/// compact layouts are unaffected.
struct ScrollReadingColumn: View {
    let chapter: Chapter
    let style: ReaderStyle
    /// Highlights in chapter coordinates.
    let highlights: [HighlightSpan]
    /// Inline images keyed by character offset in chapter coordinates.
    var inlineImages: [Int: PlatformImage] = [:]
    /// Programmatic jump target (see SelectableTextView.scrollToOffset).
    var scrollTarget: Binding<Int?>? = nil
    var onAnnotate: (AnnotationTarget, AnnotationAction) -> Void = { _, _ in }
    /// The committed selection in chapter coordinates (nil ⇒ none) — feeds the
    /// host's selection-dependent keyboard shortcuts.
    var onSelectionChange: (Range<Int>?) -> Void = { _ in }
    /// A clean tap on the page (no selection, no annotation bar): the host
    /// toggles its chrome, Apple-Books-style. iOS only; nil ⇒ ignored.
    var onChromeToggle: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = chapter.title {
                // Displayed in caps, but exposed to accessibility under the
                // original title so UI tests (and VoiceOver) still find e.g.
                // "Chapter One".
                Text(title.uppercased())
                    .font(.system(size: 11))
                    .kerning(2)
                    .foregroundStyle(style.theme.faint)
                    .lineLimit(1)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 26)
            }
            SelectableTextView(
                text: chapter.text,
                highlights: highlights,
                style: style,
                inlineImages: inlineImages,
                scrollToOffset: scrollTarget,
                onAnnotate: onAnnotate,
                onSelectionChange: onSelectionChange,
                // Scroll mode has no page-turn zones — any clean page tap
                // just toggles the chrome.
                onPageTap: { _, _ in onChromeToggle?() }
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        // ~65–70 characters per line: measure = 33 em (avg glyph ≈ 0.5 em for
        // the serif content font) + the 48pt of column padding above — the
        // book measure Apple Books holds on wide panes (PagedChapterView
        // shares the same em count).
        .frame(maxWidth: style.fontSize * 33 + 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.theme.paper)
    }
}
