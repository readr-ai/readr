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
    /// External chapter links open in the reader's browser.
    @Environment(\.openURL) private var openURL
    let book: Book

    @State private var chapterIndex = 0
    /// Reading anchor (character offset into the current chapter) in paged
    /// layouts — drives position persistence, bookmark anchors, and
    /// programmatic jumps. Scroll mode anchors to the chapter start.
    @State private var pagedAnchor = 0
    /// Where the sentence the voice is reading began, while it is reading one.
    ///
    /// `pagedAnchor` follows the voice to the *word* so a long sentence turns
    /// the page partway through, but that is the wrong thing to write down: a
    /// mid-sentence anchor makes the next Listen start at the sentence *after*
    /// it, skipping the rest of the one that was interrupted. Persist this
    /// instead, and fall back to `pagedAnchor` whenever the reader — not the
    /// voice — is the one moving.
    @State private var narrationResumeAnchor: Int?
    @State private var didRestorePosition = false
    /// The welcome-back line (`WelcomeBack`): a one-line card above the page
    /// offering a spoiler-free recap, set on restore when the reader has
    /// been away a day or more, and cleared after a few page turns, on ✕, or
    /// on Recap. Never persisted.
    @State private var welcomeBack: WelcomeBackLine?
    /// The character range of the spread in view (paged layouts), reported
    /// by the surface. The bookmark ribbon is filled when a bookmark falls
    /// inside it — "the page in view", not "this exact anchor", so a
    /// repagination (text size, window width) never unfills a bookmarked
    /// page or lets ⌘D add a second bookmark to it.
    @State private var visibleRange: Range<Int>?
    /// A PDF page bookmark picked from the Reading view's Contents: switch
    /// to the original pages, then go to the page once the surface is up.
    @State private var pendingPDFPage: Int?
    /// Page turns the reader has made since the line went up.
    @State private var pageTurnsSinceWelcome = 0
    /// The (chapter, anchor) the last counted turn landed on. Both values'
    /// `onChange` handlers report a turn, and a jump changes both in one
    /// pass, so a turn counts only when the page is a new one — and the
    /// restore's own writes, which land on this page, count for nothing.
    @State private var lastCountedPage = PagePosition(chapter: 0, anchor: 0)
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
    /// Set by "Listen from here": the selected sentence may have begun on the
    /// page before the one the reader is looking at, and following the voice
    /// there would flip the page backwards — the very regression the Listen
    /// button's begins-after rule exists for. So the page holds until the
    /// voice reaches it (or moves on to another sentence).
    @State private var holdsPageForSelectionStart = false
    @State private var heldSentenceStart: Int?
    /// The Ask sheet's opening (iPhone): non-nil presents the sheet. The
    /// conversation itself is the book's, on the app model, already pointed
    /// at this request by `presentAsk`.
    @State private var askRequest: AskRequest?
    /// The inspector column: Highlights (⌘⇧N) or ✦ Ask (⌘⇧A) — one column,
    /// two tabs, the page readable beside either. On iPhone the inspector
    /// is a sheet and Ask stays its own full-height sheet (owner decision,
    /// September 2026), so the tab strip shows only where Ask lives here —
    /// or where it already is, after an iPad narrowed with Ask open.
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .highlights
    /// The voice was paused because Ask opened over it; it resumes when
    /// Ask goes away (the sheet dismisses, or the inspector leaves the Ask
    /// tab). A reader can't listen to page 5 while reading an answer
    /// about page 4.
    @State private var narrationPausedForAsk = false
    /// The chapter the voice is in, for the card's kicker — resolved when the
    /// voice crosses a chapter, not on every tick (the title walks the TOC).
    @State private var narratedChapterTitle: String?
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
    /// Footnote being shown as a popup (a tapped noteref whose fragment
    /// matched a lifted `Chapter.footnotes` entry); nil ⇒ none.
    @State private var footnotePopup: FootnotePopup?
    /// Text-to-speech. Owned by the reader (not the app model) because
    /// narration is scoped to the open book: leaving the reader ends it, and
    /// the Listen bar only exists while it is running. Created empty and bound
    /// to a book by the Listen button.
    @StateObject private var narration = NarrationModel()
    /// Set while narration is moving the reading anchor, so the page-turn
    /// handler can tell the voice's page turns from the reader's. Render-inert
    /// for the same reason `currentSelection` is — it must never invalidate
    /// the view tree from inside an update.
    @State private var narrationMove = NarrationMoveFlag()

    /// Persisted reading layout: continuous scroll, one page, or facing pages.
    // Single page is the first-run default (#42): book-like pagination is the
    // expected reading posture for EPUBs — Scroll stays one Aa-popover tap away.
    @AppStorage("readerLayout") private var layoutRaw = PageLayout.singlePage.rawValue
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
    /// Pops the reader off the NavigationStack — the explicit back chevron's
    /// action (the system back button is hidden, see `toolbarContent`).
    @Environment(\.dismiss) private var dismiss

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
        let stored = PageLayout(rawValue: layoutRaw) ?? .singlePage
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
        (pdfShowsOriginal || isImageOnlyPDF) && model.isPDF(book)
            && model.sourceURL(for: book) != nil
    }

    /// A PDF with no text layer (scanned pages, screenshots). Its chapters
    /// are empty, so the Reading view would be blank and Ask, Listen, and
    /// search have nothing to work with: the original pages are the only
    /// surface, and the text-mode controls disable with a reason.
    ///
    /// Keyed directly on the parser's verdict so the gates hold even when the
    /// copy into the Books directory failed; `content` then explains the
    /// missing file instead of showing a blank page.
    private var isImageOnlyPDF: Bool {
        book.metadata.isImageOnly == true
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
            // The reader owns horizontal swipes: in paged mode a
            // left-to-right drag turns BACK a page (SwipeToTurn), so the
            // system back affordances step aside — the back button is
            // replaced by an explicit chevron (see `toolbarContent`) and the
            // interactive pop gesture is off while reading. Apple Books does
            // the same; leaving the pop gesture live let it win the swipe
            // and dump the reader back in the library mid-read.
            .navigationBarBackButtonHidden(true)
            .background(PopGestureDisabler())
            #endif
            .background(hiddenFontShortcuts)
            .background(hiddenAnnotationShortcuts)
            .sheet(item: $askRequest, onDismiss: resumeNarrationAfterAsk) { _ in
                AskPanelView(
                    book: book,
                    conversation: model.askConversation(for: book),
                    presentation: .sheet,
                    onNewConversation: startNewConversation
                )
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
            // Footnote popup: a medium sheet on iOS (Apple-Books-style note
            // card), a popover on macOS. Anchored to the toolbar area, not
            // the tapped glyph — the link callback carries no geometry.
            #if os(iOS)
            .sheet(item: $footnotePopup) { popup in
                FootnoteView(note: popup.note, style: style)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(style.theme.elevated)
            }
            #else
            .popover(item: $footnotePopup) { popup in
                FootnoteView(note: popup.note, style: style)
                    .frame(
                        minWidth: 320, idealWidth: 380, maxWidth: 440,
                        minHeight: 140, maxHeight: 420
                    )
            }
            .overlay(alignment: .topTrailing) { appearancePopoverAnchor }
            #endif
            .inspector(isPresented: $showInspector) {
                inspectorColumn
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
            }
            .onChange(of: showInspector) { _, shown in
                if !shown { resumeNarrationAfterAsk() }
            }
            .onChange(of: inspectorTab) { _, tab in
                if tab != .ask { resumeNarrationAfterAsk() }
            }
            // The voice starting again while Ask is open — the card's ●, the
            // lock screen, a headphone pinch — means the reader took over:
            // Ask's pause no longer applies, and neither does its resume. A
            // pause they press after that is theirs to keep.
            .onChange(of: narration.isUnderway) { _, underway in
                if underway { narrationPausedForAsk = false }
            }
            .onAppear {
                restoreOnce()
                updateMinutesCache()
                // The page follows the voice: narration reports the sentence
                // it moves to, and the reader turns to it.
                narration.onPosition = { position in
                    followNarration(position)
                }
                // Catch up on anything narrated while the callback was
                // unwired (onDisappear breaks it for every departure,
                // including a presented sheet the voice keeps reading under):
                // events fired meanwhile are gone — the one-shot chapter-hold
                // notification included — so re-sync to where the voice is.
                if let position = narration.position {
                    followNarration(position)
                }
            }
            .onDisappear {
                // Flush the debounced page-turn save — closing the reader
                // must never lose the last position.
                savePositionTask?.cancel()
                savePositionTask = nil
                saveTextPosition(chapterIndex: chapterIndex, characterOffset: anchorToPersist)
                // Break the reference cycle the follow callback forms (model →
                // closure → this view → its `@StateObject` box) EVERY time the
                // view goes off screen. `onAppear` rewires it on return, and
                // without this a reader who left with the notes inspector open
                // leaked the model — which kept the voice reading over the
                // library, and stacked a second voice on top when the book was
                // reopened. With the cycle broken, `NarrationModel.deinit` is
                // the backstop that silences narration when the reader is
                // discarded for real.
                narration.onPosition = nil
                // Closing the book stops the voice — narration is scoped to the
                // reader, and a book read aloud after the reader is gone has no
                // controls and no page to follow. But ONLY when the reader is
                // really leaving: a presented sheet can take this view off
                // screen too (the same reason `restoreOnce` guards against a
                // second `onAppear`), and asking the book about the passage it
                // just read must not cut the narration off. An answer still
                // streaming stops too: the transcript keeps what arrived, and
                // nothing streams for a book nobody is reading.
                if !isPresentingOverlay {
                    narration.stop()
                    model.askConversation(for: book).cancel()
                }
            }
            .onChange(of: chapterIndex) { _, newValue in
                // Chapter turns are rare — save immediately, and drop any
                // pending offset-only save (its offset belongs to the old
                // chapter).
                savePositionTask?.cancel()
                savePositionTask = nil
                saveTextPosition(chapterIndex: newValue, characterOffset: anchorToPersist)
                updateMinutesCache()
                // A chapter the voice crossed is not a page the reader turned.
                if !narration.isActive { noteReaderTurnedPage() }
                // The selection's range belongs to the old chapter. The text
                // views also report nil when their content is replaced, but
                // that arrives async — clear eagerly so a shortcut can't race
                // it and annotate the wrong range. (Surface teardown — layout
                // switch, PDF display toggle — needs no clear here: the text
                // views report nil from onDisappear.)
                currentSelection.value = nil
            }
            .onChange(of: pagedAnchor) { _, _ in
                if narrationMove.isActive {
                    narrationMove.isActive = false
                    // The voice turned this page, not the reader: their
                    // selection is still theirs (the annotation shortcuts read
                    // it), and the save throttles instead of debouncing.
                    scheduleAnchorSave(after: 30, throttled: true)
                    return
                }
                // A page turn replaces the visible text: the collapse report
                // arrives async, so clear eagerly — same race as a chapter
                // turn, just within one chapter.
                currentSelection.value = nil
                // The reader moved, so the voice's sentence is no longer where
                // they are — their page is the anchor again.
                narrationResumeAnchor = nil
                scheduleAnchorSave(after: 1, throttled: false)
                noteReaderTurnedPage()
            }
            // Build the retrieval index in the background when the book opens
            // so the first "ask" is fast. Safe to call repeatedly.
            .task(id: book.id) { await model.ensureIndexed(book) }
            .onChange(of: pdfAnnotationActions != nil) { _, mounted in
                if mounted, let page = pendingPDFPage {
                    pdfAnnotationActions?.goToPage(page)
                    pendingPDFPage = nil
                }
            }
            // Scroll layout has no page turns to count, so there the
            // welcome-back line goes after a stretch of reading time instead.
            .task(id: welcomeBackScrollTimerRunning) {
                guard welcomeBackScrollTimerRunning else { return }
                try? await Task.sleep(for: .seconds(WelcomeBack.scrollReadingBeforeDismissal))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { welcomeBack = nil }
            }
    }

    private var welcomeBackScrollTimerRunning: Bool {
        welcomeBack != nil && layout == .scroll
    }

    // MARK: - Inspector

    enum InspectorTab { case highlights, ask }

    /// Where ✦ Ask lives: the inspector column on the Mac and on a regular
    /// iPad, its own sheet on iPhone (an iPhone in landscape reports a
    /// regular width; the idiom, not the width, is the decision).
    private var usesAskInspector: Bool {
        #if os(macOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom != .phone && isRegularWidth
        #endif
    }

    /// The Ask tab is shown where Ask lives in the inspector — and stays
    /// shown on an iPad that narrowed to compact with Ask open, so the
    /// conversation never vanishes behind Highlights mid-answer.
    private var inspectorShowsAskTab: Bool {
        usesAskInspector || inspectorTab == .ask
    }

    private var inspectorColumn: some View {
        VStack(spacing: 0) {
            if inspectorShowsAskTab {
                inspectorTabs
            }
            if inspectorShowsAskTab, inspectorTab == .ask {
                askColumn
            } else {
                highlightsPanel
            }
        }
        .background(style.theme.background)
    }

    /// Highlights · ✦ Ask, the selected one underlined (ink for Highlights,
    /// iris for the AI tab).
    private var inspectorTabs: some View {
        HStack(alignment: .bottom, spacing: 18) {
            inspectorTabButton(
                .highlights, title: "Highlights", count: model.annotationCount(for: book),
                id: "inspector.tab.highlights", help: "Highlights and notes (⇧⌘N)"
            )
            inspectorTabButton(
                .ask, title: "\(AppTheme.aiGlyph) Ask", count: nil,
                id: "inspector.tab.ask",
                help: isImageOnlyPDF ? ScannedPDFCopy.needsText("Ask") : "Ask the book (⇧⌘A)"
            )
            .disabled(isImageOnlyPDF)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .overlay(alignment: .bottom) { style.theme.line.frame(height: 1) }
    }

    private func inspectorTabButton(
        _ tab: InspectorTab, title: String, count: Int?, id: String, help: String
    ) -> some View {
        let selected = inspectorTab == tab
        let tint = tab == .ask ? style.theme.iris : style.theme.inkColor
        return Button {
            selectInspectorTab(tab)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? tint : style.theme.muted)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(style.theme.faint)
                }
            }
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? tint : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(id)
    }

    /// A tab tap. The Ask tab on a conversation nobody has opened yet
    /// opens it on the book so far — a conversation has a frontier only
    /// once it has been pointed somewhere.
    private func selectInspectorTab(_ tab: InspectorTab) {
        if tab == .ask, !model.askConversation(for: book).hasBeenOpened {
            model.askConversation(for: book).open(bookRequest())
        }
        inspectorTab = tab
    }

    /// The Ask column: the book's conversation, in the inspector.
    private var askColumn: some View {
        AskPanelView(
            book: book,
            conversation: model.askConversation(for: book),
            presentation: .inspector,
            onNewConversation: startNewConversation
        )
        .environmentObject(model)
    }

    private var highlightsPanel: some View {
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
                    showInspector = false
                }
                #endif
            },
            // R1: a PDF note jumps to its page through the same funnel
            // the on-page bookmarks/outline use — the controller's
            // goToPage, published up via `pdfAnnotationActions` while
            // the native PDF surface is mounted.
            onJumpPDF: { highlight in
                pdfAnnotationActions?.goToPage(highlight.pageIndex)
                // iPhone: the inspector covers the page as a sheet —
                // close it so the jump is visible, mirroring the text
                // path above. iPad/macOS side columns stay open.
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    showInspector = false
                }
                #endif
            },
            // R2: recolor/delete of a PDF highlight from the Notes
            // list must reconcile the live PDFKit overlay, not just the
            // store — route through the controller (via the published
            // actions) so the on-page paint matches after the edit.
            onRecolorPDF: pdfAnnotationActions.map { actions in
                { (highlight: PDFHighlight, color: HighlightColor) in
                    actions.recolorHighlight(highlight, color)
                }
            },
            onDeletePDF: pdfAnnotationActions.map { actions in
                { (highlight: PDFHighlight) in
                    actions.removeHighlight(highlight)
                }
            },
            onClose: { showInspector = false }
        )
    }

    /// Show the Ask panel for `request`: the inspector's Ask column where
    /// that is where Ask lives — or where it already is — else the sheet.
    /// Either way over the book's one conversation, pointed at this
    /// request; a draft in the composer and the scope choice survive.
    private func presentAsk(_ request: AskRequest) {
        pauseNarrationForAsk()
        model.askConversation(for: book).open(request)
        if usesAskInspector || (showInspector && inspectorTab == .ask) {
            inspectorTab = .ask
            showInspector = true
        } else {
            askRequest = request
        }
    }

    /// A question about the book so far: no passage, scoped to what has
    /// been read.
    private func bookRequest() -> AskRequest {
        AskRequest(selection: nil, scope: askScope(selection: nil), initialQuestion: nil)
    }

    /// Ask opened while the voice was reading: pause it. Listening to the
    /// next page while reading an answer about this one is nobody's wish.
    private func pauseNarrationForAsk() {
        guard narration.isUnderway else { return }
        narration.pause()
        narrationPausedForAsk = true
    }

    /// Ask went away: the voice picks up the sentence it paused on, if it
    /// was Ask that paused it and nothing else has moved it since (a reader
    /// who pressed pause themselves keeps their pause; a book that ran out
    /// stays finished rather than re-speaking its last sentence).
    private func resumeNarrationAfterAsk() {
        guard narrationPausedForAsk else { return }
        narrationPausedForAsk = false
        if narration.status == .paused { narration.play() }
    }

    /// While the voice reads, Ask with no selection is about the sentence
    /// being read — "what does this passage mean" means the one the reader
    /// just heard. Nil when the voice isn't reading this chapter — or has
    /// been paused by the reader, who may have read on by eye since: a
    /// question then is about the book, not a sentence from pages back.
    /// (Paused by Ask itself still counts as reading.)
    private func narratedSentenceSelection() -> (Selection, Range<Int>)? {
        guard narration.isUnderway || narrationPausedForAsk,
              let position = narration.position, position.chapterIndex == chapterIndex,
              let chapter, let sentence = narration.currentSentenceRange else { return nil }
        let start = max(0, min(sentence.lowerBound, chapter.text.count))
        let end = min(chapter.text.count, sentence.upperBound)
        guard end > start else { return nil }
        let range = start..<end
        return (model.makeSelection(in: chapter, range: range), range)
    }

    /// Start over: a fresh conversation, open on the book at large.
    private func startNewConversation() {
        model.startNewAskConversation(for: book).open(bookRequest())
    }

    /// The Highlights button (⌘⇧N): opens the inspector on Highlights, or
    /// switches an inspector that is showing Ask to Highlights, or closes
    /// an inspector already showing Highlights.
    private func toggleHighlightsPanel() {
        if showInspector, inspectorTab == .ask {
            inspectorTab = .highlights
        } else if showInspector {
            showInspector = false
        } else {
            inspectorTab = .highlights
            showInspector = true
        }
    }

    // MARK: - Reading surface

    private var content: some View {
        Group {
            if isPDFOriginal, let url = model.sourceURL(for: book) {
                PDFReaderView(
                    book: book,
                    url: url,
                    onAsk: { selection in
                        // A native PDF page is not a reading position: no
                        // frontier, so the whole document is in scope.
                        presentAsk(AskRequest(selection: selection, scope: .wholeBook, initialQuestion: nil))
                    },
                    onListen: { anchor in listen(from: anchor) },
                    annotationActions: $pdfAnnotationActions
                )
            } else if isImageOnlyPDF {
                // The retained file is gone (or was never copied), and every
                // chapter is empty: nothing to fall back on but an explanation.
                ContentUnavailableView(
                    ScannedPDFCopy.missingFileTitle,
                    systemImage: "doc.viewfinder",
                    description: Text(ScannedPDFCopy.missingFileDescription)
                )
                .accessibilityIdentifier("reader.scanMissingFile")
            } else if let chapter, model.isPDF(book), !chapter.hasText {
                imagePagePlaceholder(for: chapter)
            } else if let chapter {
                readingSurface(for: chapter)
            } else {
                ContentUnavailableView("No readable content", systemImage: "doc")
            }
        }
        // The welcome-back line insets the page from the top for the same
        // reason the Listen card insets it from the bottom: nothing floats
        // over the words.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let welcomeBack {
                welcomeBackBar(welcomeBack)
            }
        }
        // The Listen card insets the reading surface rather than floating over
        // it: the page turns itself to follow the voice, so the card must never
        // cover the sentence being read.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if narration.isActive {
                ListenBar(
                    narration: narration,
                    style: style,
                    chapterTitle: narratedChapterTitle,
                    surface: layout == .scroll ? style.theme.background : style.theme.paper
                ) {
                    narration.stop()
                }
                .onChange(of: narration.position?.chapterIndex ?? chapterIndex, initial: true) {
                    _, index in
                    narratedChapterTitle = book.chapterDisplayTitle(index)
                }
            }
        }
    }

    /// The Reading view of a PDF that has text, on a page that has none (a
    /// plate, a full-page figure). The page keeps its slot so numbering and
    /// positions stay true to the document; here it says what it is instead
    /// of rendering as an empty sheet.
    private func imagePagePlaceholder(for chapter: Chapter) -> some View {
        ContentUnavailableView {
            Label(
                ScannedPDFCopy.imagePageTitle(chapter.title ?? "This page"),
                systemImage: "photo"
            )
        } description: {
            Text(ScannedPDFCopy.imagePageDescription)
        } actions: {
            Button(ScannedPDFCopy.showOriginalPages) { pdfShowsOriginal = true }
                .accessibilityIdentifier("reader.showOriginalPages")
        }
        .accessibilityIdentifier("reader.imagePage")
    }

    private func readingSurface(for chapter: Chapter) -> some View {
        let images = model.inlineImages(for: book, chapter: chapter)
        let spans = highlightSpans(for: chapter)
        return VStack(spacing: 0) {
            if layout == .scroll {
                ScrollReadingColumn(
                    chapter: chapter,
                    style: style,
                    displayTitle: book.tocTitle(forChapterIndex: chapterIndex),
                    highlights: spans,
                    inlineImages: images,
                    scrollTarget: $scrollTarget,
                    onAnnotate: { target, action in
                        handleAnnotation(in: chapter, target: target, action: action)
                    },
                    onSelectionChange: { currentSelection.value = $0 },
                    onChromeToggle: toggleChrome,
                    onLinkTap: handleLinkTap
                )
                // Scroll mode has no pages, but a horizontal flick still
                // crosses chapters — the paged layouts flow across chapter
                // walls on swipe, and a layout offering no swipe at all
                // reads as broken navigation.
                .modifier(ChapterSwipe { direction in
                    if direction > 0, let next = linearIndex(after: chapterIndex) {
                        jump(toChapter: next, offset: 0)
                    } else if direction < 0, let previous = linearIndex(before: chapterIndex) {
                        jump(toChapter: previous, offset: 0)
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
                    displayTitle: book.tocTitle(forChapterIndex: chapterIndex),
                    highlights: spans,
                    inlineImages: images,
                    anchorOffset: $pagedAnchor,
                    onAnnotate: { target, action in
                        handleAnnotation(in: chapter, target: target, action: action)
                    },
                    onSelectionChange: { currentSelection.value = $0 },
                    onChromeToggle: toggleChrome,
                    onLinkTap: handleLinkTap,
                    canOverflowBackward: linearIndex(before: chapterIndex) != nil,
                    canOverflowForward: linearIndex(after: chapterIndex) != nil,
                    onVisibleRange: { visibleRange = $0 },
                    onOverflow: { direction in
                        // Paging past a chapter's edge flows into the next/
                        // previous LINEAR chapter: forward lands on its first
                        // page, backward on its LAST (an end-of-text offset —
                        // the paginator clamps it into the final page).
                        if direction > 0, let next = linearIndex(after: chapterIndex) {
                            jump(toChapter: next, offset: 0)
                        } else if direction < 0,
                                  let previous = linearIndex(before: chapterIndex) {
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
        // Progress counts LINEAR chapters only — a notes appendix the reader
        // never pages through must not stretch the track's denominator.
        let linearTotal = book.chapters.filter { $0.isLinear != false }.count
        let linearPosition = book.chapters.prefix(chapterIndex + 1)
            .filter { $0.isLinear != false }.count
        let fraction = linearTotal == 0
            ? 0
            : Double(linearPosition) / Double(linearTotal)
        return HStack(spacing: 14) {
            #if os(macOS)
            // Scroll layout has no page edges and no flick on the Mac, so
            // the footer carries the chapter arrows (⌥⌘← / ⌥⌘→).
            chapterArrow(direction: -1)
            #endif
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
            #if os(macOS)
            chapterArrow(direction: +1)
            #endif
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(style.theme.line).frame(height: 1)
        }
    }

    /// Previous / next chapter, for the scroll footer on the Mac.
    private func chapterArrow(direction: Int) -> some View {
        let target = direction < 0 ? linearIndex(before: chapterIndex) : linearIndex(after: chapterIndex)
        return Button {
            if let target { jump(toChapter: target) }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.theme.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .help(direction < 0 ? "Previous chapter (⌥⌘←)" : "Next chapter (⌥⌘→)")
        .accessibilityLabel(direction < 0 ? "Previous chapter" : "Next chapter")
        .accessibilityIdentifier(direction < 0 ? "prevChapter" : "nextChapter")
    }

    private func updateMinutesCache() {
        guard let chapter else {
            minutesCache = nil
            return
        }
        guard minutesCache?.chapterID != chapter.id else { return }
        // From the app's cached chapter lengths — measured once per book,
        // never re-counted here.
        let words = model.readingLengths(for: book).entries
        minutesCache = (
            chapterID: chapter.id,
            minutes: ReadingTimeEstimator().minutes(
                forWords: words.indices.contains(chapterIndex) ? words[chapterIndex].words : 0
            )
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        // The explicit way back to the library: the system back button is
        // hidden and the pop gesture disabled (see body) so right-swipes turn
        // pages. Reachable whenever chrome is shown — a page tap brings the
        // bar back, as in Apple Books.
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityIdentifier("reader.back")
            .accessibilityLabel("Back to Library")
            .help("Back to Library")
        }
        #endif
        ToolbarItemGroup(placement: .navigation) {
            // Contents and the bookmark ribbon. No chapter chevrons: the
            // page edges turn pages (and flow across chapter walls), and
            // Contents jumps anywhere — a second pair of arrows in the bar
            // was two more controls for nothing new. iPad regular width
            // carries these up top, macOS-style; compact keeps them in the
            // bottom bar below.
            #if os(macOS)
            if !isPDFOriginal {
                tocButton
                bookmarkToggle
            }
            #else
            if isRegularWidth, !isPDFOriginal {
                tocButton
                bookmarkToggle
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
                listenButton
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
                    bookmarkToggle
                    Spacer()
                    searchButton
                } else {
                    Spacer()
                }
                listenButton
                askButton
            }
        }
        #else
        // macOS trailing area: Find · Aa · Listen · ✦ Ask · Highlights. The
        // appearance controls used to sit inline here — layout segments, a
        // font stepper, a Text menu, three theme dots, a PDF display menu:
        // seventeen controls across the bar. They live behind the same Aa
        // popover iOS has (September 2026 UX review, F3).
        ToolbarItemGroup(placement: .primaryAction) {
            if !isPDFOriginal {
                searchButton
            }
            appearanceButton
            listenButton
            askButton
            notesButton
        }
        #endif
    }

    /// Read the book aloud, starting from the visible page. Pressing it again
    /// (or the bar's ✕) stops. Narration reads the book's *text*, so a PDF
    /// shown as original pages is narrated from its extracted text.
    private var listenButton: some View {
        Button { toggleListening() } label: {
            Label(
                narration.isActive ? "Stop Listening" : "Listen",
                systemImage: narration.isActive ? "headphones.circle.fill" : "headphones"
            )
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .accessibilityIdentifier("reader.listen")
        .accessibilityLabel(narration.isActive ? "Stop listening" : "Listen to this book")
        .help(
            isImageOnlyPDF
                ? ScannedPDFCopy.needsText("Listen")
                : "Read aloud from this page (\u{21E7}\u{2318}L)"
        )
        .disabled(isImageOnlyPDF)
    }

    private func toggleListening() {
        if narration.isActive {
            narration.stop()
        } else {
            // The reading anchor, so narration picks up at the top of the page
            // in view rather than at the chapter's start.
            //
            // With the original PDF pages up, the page in view is the
            // anchor: the text-mode `chapterIndex`/`pagedAnchor` are only ever
            // written by the text surface, so on a PDF read page by page they
            // still point at wherever text mode was last left (page 1, for
            // most readers) — and Listen started the document over. The
            // surface publishes the page's chapter while mounted; under a
            // sheet (the shortcut still fires) the saved page stands in.
            if model.isPDF(book), isPDFOriginal {
                let chapter = pdfAnnotationActions?.narrationChapterInView()
                    ?? model.position(for: book)?.pdfPageIndex
                guard let chapter, book.chapters.indices.contains(chapter) else {
                    DiagnosticsLog.shared.record(
                        .warning, .reader, "Narration start refused: PDF page has no chapter"
                    )
                    return
                }
                // Pressing Listen again on the page the voice stopped on picks
                // up at that sentence, as text mode does through its anchor.
                let resume = narration.position.flatMap {
                    $0.chapterIndex == chapter ? $0.sentenceStart : nil
                }
                startNarration(
                    chapter: chapter, offset: resume ?? 0, anchor: .nextSentenceStart,
                    origin: "page in view"
                )
            } else {
                startNarration(
                    chapter: chapterIndex, offset: pagedAnchor, anchor: .nextSentenceStart,
                    origin: "page top"
                )
            }
        }
    }

    /// "Listen from here": read aloud from the sentence containing a selection
    /// or highlight, on either surface. Restarts a voice already reading
    /// rather than layering a second one.
    private func listen(from anchor: ListenAnchor) {
        guard book.chapters.indices.contains(anchor.chapterIndex) else {
            DiagnosticsLog.shared.record(
                .warning, .reader,
                "Listen from here refused: chapter \(anchor.chapterIndex) is not in the book"
            )
            return
        }
        holdsPageForSelectionStart = true
        heldSentenceStart = nil
        startNarration(
            chapter: anchor.chapterIndex, offset: anchor.characterOffset,
            anchor: .sentenceContaining,
            origin: anchor.isExact ? "selection" : "selection, approximate"
        )
    }

    /// The one place narration is started from this view. Recorded because a
    /// device test saw narration begin near the top of the chapter after
    /// paging to its last page, and every route that turns a page does write
    /// the anchor — so the next report of it needs the number that was
    /// actually handed over, not another description of where the page
    /// looked. A chapter index, an offset and where they came from — never
    /// any of the text (see DiagnosticsLog).
    private func startNarration(
        chapter: Int, offset: Int, anchor: SpeechPlaylist.SeekAnchor, origin: String
    ) {
        if anchor == .nextSentenceStart {
            holdsPageForSelectionStart = false
            heldSentenceStart = nil
        }
        DiagnosticsLog.shared.record(
            .info, .reader,
            "Narration start (\(origin)): chapter \(chapter) offset \(offset)"
        )
        narration.start(book: book, chapterIndex: chapter, characterOffset: offset, anchor: anchor)
    }

    /// Keep the page under the voice. Narration reports each sentence it moves
    /// to; setting the anchor re-derives the visible page from it, so the page
    /// turns exactly when the reading crosses onto the next one — and the
    /// position that gets persisted is where the reader actually listened to.
    private func followNarration(_ position: NarrationPosition) {
        guard book.chapters.indices.contains(position.chapterIndex) else { return }
        // Original PDF pages: the surface owns the page, so it turns the page
        // (once per page the voice crosses onto) and the text-mode state —
        // `chapterIndex`, `pagedAnchor`, their saves — is left alone; a
        // `jump` here would count as a reader move and drop the resume
        // anchor and the selection on every page. Cheap check first: the
        // actions exist only while the PDF surface is mounted, and
        // `isPDFOriginal` touches the filesystem.
        if pdfAnnotationActions != nil || (model.isPDF(book) && isPDFOriginal) {
            pdfAnnotationActions?.followNarration(position.chapterIndex)
            return
        }
        guard position.chapterIndex == chapterIndex else {
            jump(toChapter: position.chapterIndex, offset: position.characterOffset)
            return
        }
        narrationResumeAnchor = position.sentenceStart
        if holdsPageForSelectionStart {
            // Still inside the selected sentence and behind the page the
            // reader is on: hold the page. Anything else releases the hold.
            if position.characterOffset < pagedAnchor,
               heldSentenceStart == nil || heldSentenceStart == position.sentenceStart {
                heldSentenceStart = position.sentenceStart
                return
            }
            holdsPageForSelectionStart = false
            heldSentenceStart = nil
        }
        guard position.characterOffset != pagedAnchor else { return }
        narrationMove.isActive = true
        pagedAnchor = position.characterOffset
        if layout == .scroll {
            scrollTarget = position.characterOffset
        }
    }

    /// The offset to write down: the start of the sentence being narrated if a
    /// voice is reading, otherwise the top of the visible page.
    private var anchorToPersist: Int {
        narrationResumeAnchor ?? pagedAnchor
    }

    /// How far the reader has got, for Ask. Answers are built only from the
    /// text before this point, so "recap what I've read" can't spoil — but
    /// the point must never sit behind the page in front of the reader.
    ///
    /// Paged layouts: the top of the visible page (the same anchor the
    /// reading position uses), pushed forward to the end of `selection` when
    /// the question is about one — a passage the reader can see is read.
    ///
    /// Scroll layout: `pagedAnchor` only moves on restore and on jumps, and
    /// the scrolling text view reports no visible range, so there is no
    /// character anchor to use. The whole current chapter counts as read:
    /// the reader may be anywhere in it, and hiding the text they are looking
    /// at is the worse error. (If the scroll surface ever reports the end of
    /// its visible text, that is the anchor to use here instead.)
    ///
    /// Native PDF pages have no text position at all, so they get no frontier
    /// and the whole document, as before. An image-only PDF also never gets a
    /// frontier, including when its retained source is missing.
    private func askScope(selection: Range<Int>?) -> ReadingScope {
        guard !isPDFOriginal, !isImageOnlyPDF else { return .wholeBook }
        var frontier: ReadingFrontier
        if layout == .scroll {
            frontier = ReadingFrontier(chapterIndex: chapterIndex, characterOffset: chapter?.text.count ?? 0)
        } else {
            frontier = ReadingFrontier(chapterIndex: chapterIndex, characterOffset: anchorToPersist)
        }
        if let selection {
            frontier = frontier.extended(toInclude: selection)
        }
        return .upTo(frontier)
    }

    /// True while something is presented over the reader.
    private var isPresentingOverlay: Bool {
        askRequest != nil || showInspector || showTOC || showSearch || showAppearance
            || editingNote != nil || footnotePopup != nil
    }

    /// Persist the reading anchor off the hot path.
    ///
    /// Reader page turns arrive in bursts and then stop, so they **debounce** —
    /// each turn pushes the save back a second and only the last one lands.
    /// Narration's page turns never stop arriving (a sentence every few seconds
    /// for as long as the reader listens), and every save rewrites the whole
    /// library JSON: debouncing those would either never fire or rewrite the
    /// file at sentence rate for an hour. They **throttle** instead — one save
    /// per window, whatever the voice is doing in between.
    private func scheduleAnchorSave(after seconds: Double, throttled: Bool) {
        if throttled {
            guard savePositionTask == nil else { return }
        } else {
            savePositionTask?.cancel()
        }
        savePositionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Reads the anchor at fire time, so a throttled save records where
            // the voice actually got to, not where it was a window ago.
            saveTextPosition(chapterIndex: chapterIndex, characterOffset: anchorToPersist)
            savePositionTask = nil
        }
    }

    private var tocButton: some View {
        Button { showTOC = true } label: {
            Label("Contents", systemImage: "list.bullet")
        }
        .accessibilityIdentifier("reader.toc")
        .accessibilityLabel("Table of contents")
        .help("Table of contents")
        .popover(isPresented: $showTOC) {
            contentsPopover
        }
    }

    /// Marginalia-themed contents on the elevated surface, sized to its rows
    /// (`contentsPopoverFrame`) and a half sheet on iPhone. Bookmarks list
    /// first — every one of them, page bookmarks included, so a bookmark
    /// made on a PDF's original pages is still there (and removable) from
    /// the Reading view — then the chapter list. There is no bookmarks
    /// menu (September 2026 UX review, F9).
    private var contentsPopover: some View {
        let toc = book.flattenedTOC
        let text = textBookmarks
        let pages = pageBookmarks
        let bookmarkedRows = bookmarkedRows(in: toc, bookmarks: text)
        let bookmarkedChapters = Set(text.map(\.chapterIndex))
        return LazyVStack(alignment: .leading, spacing: 0) {
            if !text.isEmpty || !pages.isEmpty {
                ContentsSectionHeader(title: "BOOKMARKS", theme: style.theme)
                ForEach(text) { bookmark in
                    ContentsBookmarkRow(
                        kicker: book.chapterDisplayTitle(bookmark.chapterIndex),
                        snippet: bookmark.snippet,
                        theme: style.theme,
                        accessibilityLabel: bookmarkLabel(for: bookmark),
                        onJump: {
                            showTOC = false
                            jump(toChapter: bookmark.chapterIndex, offset: bookmark.characterOffset)
                        },
                        onRemove: { model.removeBookmark(bookmark) }
                    )
                }
                ForEach(pages) { bookmark in
                    let page = (bookmark.pdfPageIndex ?? 0) + 1
                    ContentsBookmarkRow(
                        kicker: "Page \(page)",
                        snippet: bookmark.snippet == "Page \(page)" ? "" : bookmark.snippet,
                        theme: style.theme,
                        accessibilityLabel: "Bookmark on page \(page) of the original pages",
                        onJump: {
                            // A page is the original pages' place: show them,
                            // and go to the page once the surface is up.
                            showTOC = false
                            pendingPDFPage = bookmark.pdfPageIndex
                            pdfShowsOriginal = true
                        },
                        onRemove: { model.removeBookmark(bookmark) }
                    )
                }
            }
            ContentsSectionHeader(title: "CONTENTS", theme: style.theme)
            if toc.isEmpty {
                // No parsed TOC (plain text, PDFs): fall back to the spine,
                // one row per chapter.
                ForEach(0..<book.chapters.count, id: \.self) { index in
                    tocRow(
                        title: book.chapterDisplayTitle(index),
                        depth: 0,
                        isCurrent: index == chapterIndex,
                        hasBookmark: bookmarkedChapters.contains(index)
                    ) {
                        jump(toChapter: index)
                    }
                }
            } else {
                // The book's REAL table of contents — the spine list
                // mislabeled front matter and multi-entry documents as
                // "Chapter N". Current row: the last entry at/before the
                // reading position's chapter.
                let currentID = toc.last(
                    where: { $0.entry.chapterIndex <= chapterIndex }
                )?.id
                ForEach(toc) { row in
                    tocRow(
                        title: row.entry.title,
                        depth: row.depth,
                        isCurrent: row.id == currentID,
                        hasBookmark: bookmarkedRows.contains(row.id)
                    ) {
                        jump(toTOCEntry: row.entry)
                    }
                }
            }
        }
        .padding(.top, 6)
        .contentsPopoverFrame(theme: style.theme)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    /// Which TOC rows hold a bookmark: the last row at or before each
    /// bookmark's place — not every row that happens to share the
    /// bookmark's spine document (a Part's six sub-entries are six places,
    /// and one bookmark is in one of them).
    private func bookmarkedRows(in toc: [FlatTOCEntry], bookmarks: [Bookmark]) -> Set<Int> {
        guard !toc.isEmpty else { return [] }
        let places: [(chapter: Int, offset: Int)] = toc.map { row in
            let offset = row.entry.fragment
                .flatMap { book.chapters.indices.contains(row.entry.chapterIndex)
                    ? book.chapters[row.entry.chapterIndex].anchors?[$0] : nil } ?? 0
            return (row.entry.chapterIndex, offset)
        }
        var marked: Set<Int> = []
        for bookmark in bookmarks {
            var hit: Int?
            for (index, place) in places.enumerated()
            where (place.chapter, place.offset) <= (bookmark.chapterIndex, bookmark.characterOffset) {
                hit = toc[index].id
            }
            if let hit { marked.insert(hit) }
        }
        return marked
    }
    /// One Contents row, shared by the real-TOC and fallback lists. Nested
    /// TOC entries indent by depth; a row holding a bookmark shows a faint
    /// ribbon (decorative: the row's label stays the title).
    private func tocRow(
        title: String, depth: Int, isCurrent: Bool, hasBookmark: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            showTOC = false
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14.5, design: .serif))
                    .fontWeight(isCurrent ? .bold : .regular)
                    .foregroundStyle(style.theme.inkColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasBookmark {
                    ContentsBookmarkMarker(theme: style.theme)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 12 + CGFloat(depth) * 14)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hasBookmark ? "Has a bookmark" : "")
    }

    /// Text-mode bookmarks in reading order.
    private var textBookmarks: [Bookmark] {
        model.bookmarks(for: book)
            .filter { $0.pdfPageIndex == nil }
            .sorted {
                ($0.chapterIndex, $0.characterOffset) < ($1.chapterIndex, $1.characterOffset)
            }
    }

    /// PDF page bookmarks in page order (a PDF read in the Reading view
    /// still has them).
    private var pageBookmarks: [Bookmark] {
        model.bookmarks(for: book)
            .filter { $0.pdfPageIndex != nil }
            .sorted { ($0.pdfPageIndex ?? 0) < ($1.pdfPageIndex ?? 0) }
    }

    /// TOC jump: the entry's chapter, at its fragment anchor when it carries
    /// one (several entries can share a single spine document) — the same
    /// anchor resolution as internal links (`handleLinkTap`).
    private func jump(toTOCEntry entry: TOCEntry) {
        guard book.chapters.indices.contains(entry.chapterIndex) else { return }
        let offset = entry.fragment
            .flatMap { book.chapters[entry.chapterIndex].anchors?[$0] } ?? 0
        jump(toChapter: entry.chapterIndex, offset: offset)
    }

    /// The ribbon: filled on a bookmarked page, and a single tap (⌘D) adds
    /// or removes the bookmark. The list of bookmarks lives in Contents —
    /// a menu of submenus here was two clicks to jump anywhere.
    private var bookmarkToggle: some View {
        BookmarkRibbonButton(
            isBookmarked: currentBookmark != nil,
            identifier: "reader.bookmarks",
            action: toggleBookmark
        )
    }

    private var searchButton: some View {
        Button { showSearch = true } label: {
            Label("Find in Book", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityIdentifier("reader.search")
        .accessibilityLabel("Find in book")
        .help(
            isImageOnlyPDF
                ? ScannedPDFCopy.needsText("Find")
                : "Find in book (⌘F)"
        )
        .disabled(isImageOnlyPDF)
        .popover(isPresented: $showSearch) {
            ReaderSearchPopover(book: book) { index, offset in
                showSearch = false
                jump(toChapter: index, offset: offset)
            }
        }
    }

    /// The Aa popover — text size, theme, font, spacing, layout, and the
    /// PDF pages/text switch — on both platforms.
    ///
    /// iOS presents it from the toolbar button. macOS presents it from an
    /// anchor in the content (`appearancePopoverAnchor`) in an AppKit
    /// popover of its own: SwiftUI's bridged `.popover` re-showed itself
    /// on every re-render of the presenter — from the toolbar item, and
    /// from the content too — until AppKit gave up with an exception from
    /// `_postWindowNeedsUpdateConstraints`; the app hung, then died, on
    /// every Aa click in CI's macOS lane (crash reports and thread samples
    /// in the ci-screenshots branch). See `MacPopover`.
    private var appearanceButton: some View {
        let button = Button {
            // The Voice section needs the book's voices resolved — before
            // the first Listen too, since this is where the narrator is
            // chosen. Once per book; nothing starts reading.
            narration.prepareVoices(for: book)
            showAppearance = true
        } label: {
            Label("Appearance", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("reader.appearance")
        .accessibilityLabel("Appearance")
        .help("Appearance — theme, text size (⌘+ / ⌘−), layout")
        #if os(iOS)
        return button.popover(isPresented: $showAppearance) { appearancePopover }
        #else
        return button
        #endif
    }

    private var appearancePopover: some View {
        AppearancePopover(
            themeRaw: $themeRaw,
            layoutRaw: $layoutRaw,
            fontSize: $fontSize,
            fontRaw: $fontRaw,
            lineSpacingRaw: $lineSpacingRaw,
            isJustified: $isJustified,
            // An image-only PDF has no Reading view to offer.
            isPDF: model.isPDF(book) && !isImageOnlyPDF,
            pdfShowsOriginal: $pdfShowsOriginal,
            narration: narration
        )
    }

    #if os(macOS)
    /// A one-point anchor under the toolbar's Aa button, so the popover
    /// hangs from where it was asked for — in an AppKit popover of its own
    /// (`MacPopover`), not SwiftUI's bridged one (see `appearanceButton`).
    private var appearancePopoverAnchor: some View {
        MacPopover(isPresented: $showAppearance) {
            appearancePopover
                .environment(\.popoverDismiss, PopoverDismiss { showAppearance = false })
        }
        .frame(width: 1, height: 1)
        .padding(.trailing, 150)
        .accessibilityHidden(true)
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
        .help(
            isImageOnlyPDF
                ? ScannedPDFCopy.needsText("Ask")
                : "Ask the book (⇧⌘A) — asks about the selection when text is selected"
        )
        .disabled(isImageOnlyPDF)
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
            presentAsk(AskRequest(
                selection: pdfAnnotationActions?.askSelection(), scope: .wholeBook, initialQuestion: nil
            ))
        } else if let chapter, let selected = currentSelection.value {
            presentAsk(AskRequest(
                selection: model.makeSelection(in: chapter, range: selected),
                scope: askScope(selection: selected),
                initialQuestion: nil
            ))
        } else if let (selection, range) = narratedSentenceSelection() {
            // Listening: the question is about the sentence being read.
            presentAsk(AskRequest(
                selection: selection, scope: askScope(selection: range), initialQuestion: nil
            ))
        } else {
            // No selection: a question about the book — scoped to what has
            // been read, with the panel's switch to widen it.
            presentAsk(bookRequest())
        }
    }

    /// Recap: Ask, with "recap what I've read so far" already sent. The
    /// answer stops where the reader stopped (`askScope`), and the panel
    /// says where that is. Reached from the welcome-back line; the Ask
    /// panel's first starter row is the recap too, so the toolbar carries
    /// one ✦ entry point, not two doors into the same panel (owner
    /// feedback, 3.3.1). A native PDF page is not a reading position, so a
    /// PDF never gets a recap.
    private func openRecap() {
        let scope = askScope(selection: nil)
        guard scope.isScoped else { return }
        welcomeBack = nil
        presentAsk(AskRequest(selection: nil, scope: scope, initialQuestion: AskPanelView.recapQuestion))
    }

    // MARK: - Welcome back

    /// One page turn by the reader, counted once per new page (see
    /// `lastCountedPage`). After `WelcomeBack.pageTurnsBeforeDismissal` the
    /// line goes: the reader has evidently picked the thread up.
    private func noteReaderTurnedPage() {
        guard welcomeBack != nil else { return }
        let page = PagePosition(chapter: chapterIndex, anchor: pagedAnchor)
        guard page != lastCountedPage else { return }
        lastCountedPage = page
        pageTurnsSinceWelcome += 1
        if pageTurnsSinceWelcome >= WelcomeBack.pageTurnsBeforeDismissal {
            withAnimation(.easeOut(duration: 0.2)) { welcomeBack = nil }
        }
    }

    /// "✦ Welcome back — it’s been 6 days · Chapter 1 of 12 · 31% · Recap ›"
    /// on the elevated surface, sized to the reading measure.
    private func welcomeBackBar(_ line: WelcomeBackLine) -> some View {
        HStack(spacing: 12) {
            Text(AppTheme.aiGlyph)
                .font(.system(size: 17))
                .foregroundStyle(style.theme.iris)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome back \u{2014} \(line.absence)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.theme.inkColor)
                    .accessibilityIdentifier("reader.welcomeBack")
                if let caption = line.caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(style.theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: openRecap) {
                HStack(spacing: 3) {
                    Text("Recap")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.theme.iris)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Recap what you've read so far, spoiler-free")
            .accessibilityLabel("Recap what you've read so far")
            .accessibilityIdentifier("reader.welcomeRecap")
            Button {
                withAnimation(.easeOut(duration: 0.2)) { welcomeBack = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(style.theme.faint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("reader.welcomeDismiss")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(style.theme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style.theme.line, lineWidth: 1)
        )
        .frame(maxWidth: 620)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(layout == .scroll ? style.theme.background : style.theme.paper)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var notesButton: some View {
        Button(action: toggleHighlightsPanel) {
            Label("Highlights", systemImage: "highlighter")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .accessibilityIdentifier("reader.notes")
        .accessibilityLabel("Highlights")
        .help("Highlights (⇧⌘N) — from the Ask tab, switches to Highlights")
    }

    /// Invisible buttons so ⌘+/⌘− resize text without opening the Appearance
    /// popover — a shortcut registered inside a popover is only live while
    /// that popover is on screen.
    private var hiddenFontShortcuts: some View {
        Group {
            // Chapter navigation from the keyboard in every layout.
            Button("Next chapter") {
                if let next = linearIndex(after: chapterIndex) { jump(toChapter: next) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous chapter") {
                if let previous = linearIndex(before: chapterIndex) { jump(toChapter: previous) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
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
        // A reader's move to another chapter while the voice reads takes the
        // voice along — Contents is the card's chapter skip. Without this the
        // voice kept reading where it was and `followNarration` turned the
        // page straight back. The voice's own chapter crossings arrive here
        // with its chapter, so they are left alone; a paused voice moves but
        // stays paused.
        if narration.isActive, let position = narration.position, position.chapterIndex != index {
            let wasUnderway = narration.isUnderway
            narration.start(book: book, chapterIndex: index, characterOffset: offset)
            if !wasUnderway { narration.pause() }
        }
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

    /// A tapped link in chapter text. A noteref whose fragment names a lifted
    /// footnote opens as a popup in place (the note body was extracted out of
    /// the chapter text). Other internal links resolve their archive path
    /// against `Chapter.sourcePath` and their fragment against
    /// `Chapter.anchors`, then ride the same `jump` as TOC/bookmarks/search.
    /// External links normally never reach here (the platform text views hand
    /// them to the system), but route through `openURL` if one ever does.
    private func handleLinkTap(_ target: LinkTarget) {
        switch target {
        case let .external(url):
            if let url = URL(string: url) { openURL(url) }
        case let .internalDoc(path, fragment):
            if let fragment,
               let note = Self.resolveFootnote(
                   id: fragment, targetPath: path,
                   chapters: book.chapters, currentChapter: chapter
               ) {
                footnotePopup = FootnotePopup(note: note)
                return
            }
            guard let index = Self.spineIndex(forPath: path, in: book.chapters)
            else { return }
            let offset = fragment.flatMap { book.chapters[index].anchors?[$0] } ?? 0
            jump(toChapter: index, offset: offset)
        }
    }

    /// Spine entry whose `sourcePath` matches an internal link's archive
    /// path: exact match first, then case-insensitive — the parser tolerates
    /// case drift between hrefs and archive paths the same way
    /// (`EPUBBookParser.lowercasedChapterIndex`). Percent-decoding already
    /// happened on both sides.
    private static func spineIndex(forPath path: String, in chapters: [Chapter]) -> Int? {
        if let exact = chapters.firstIndex(where: { $0.sourcePath == path }) {
            return exact
        }
        let lowercased = path.lowercased()
        return chapters.firstIndex { $0.sourcePath?.lowercased() == lowercased }
    }

    /// The lifted footnote a noteref resolves to: the TARGET document's notes
    /// when the path resolves to a spine entry, the current chapter's only
    /// when it resolves to none (same-document refs) or back to the current
    /// chapter itself. A DIFFERENT resolved target that doesn't lift the id
    /// returns nil — footnote ids (fn1…) recur per document, so falling back
    /// would hijack a legitimate cross-document link into an unrelated
    /// same-id popup; the tap falls through to navigation instead. Internal
    /// for the snapshot-suite tests.
    static func resolveFootnote(
        id: String, targetPath: String, chapters: [Chapter], currentChapter: Chapter?
    ) -> Footnote? {
        guard let index = spineIndex(forPath: targetPath, in: chapters),
              chapters[index].id != currentChapter?.id
        else {
            return currentChapter?.footnotes?.first { $0.id == id }
        }
        return chapters[index].footnotes?.first { $0.id == id }
    }

    /// Next linear chapter after `index` — spine documents marked
    /// `linear="no"` (notes files, nav docs) are skipped by every
    /// next/previous move; they stay reachable through internal links and
    /// the Contents list. Nil at the reading order's end.
    private func linearIndex(after index: Int) -> Int? {
        var candidate = index + 1
        while book.chapters.indices.contains(candidate) {
            if book.chapters[candidate].isLinear != false { return candidate }
            candidate += 1
        }
        return nil
    }

    /// Previous linear chapter before `index` (see `linearIndex(after:)`).
    private func linearIndex(before index: Int) -> Int? {
        var candidate = index - 1
        while book.chapters.indices.contains(candidate) {
            if book.chapters[candidate].isLinear != false { return candidate }
            candidate -= 1
        }
        return nil
    }

    /// Restore once; later re-appears (e.g. after dismissing a sheet) must not
    /// clobber the chapter the reader navigated to.
    private func restoreOnce() {
        guard !didRestorePosition else { return }
        didRestorePosition = true
        // The stamp this open replaced decides the welcome-back line. Taken
        // BEFORE the reader stamps again, and taken once — a reopen later in
        // the session measures from now, not from an absence already greeted.
        let lastOpened = model.takeLastOpenedBeforeOpen(for: book)
        model.markOpened(book)
        let position = model.position(for: book)
        if let position {
            pagedAnchor = max(0, position.characterOffset)
            chapterIndex = min(max(0, position.chapterIndex), max(0, book.chapters.count - 1))
        }
        // The restored page is where the count starts: the writes above
        // report as changes, and they must not count as page turns.
        lastCountedPage = PagePosition(chapter: chapterIndex, anchor: pagedAnchor)
        let now = Date()
        // A native PDF page is not a reading position: no frontier, no recap.
        guard !isPDFOriginal, !isImageOnlyPDF,
              WelcomeBack.shouldOffer(
                  lastOpenedAt: lastOpened, now: now, hasProgress: WelcomeBack.hasProgress(position)
              ),
              let lastOpened, let position else { return }
        let caption = ReadingPositionSummary(
            book: book, position: position, lengths: model.readingLengths(for: book)
        )?.caption
        welcomeBack = WelcomeBackLine(
            absence: WelcomeBack.absencePhrase(from: lastOpened, to: now), caption: caption
        )
    }

    // MARK: - Bookmarks

    /// The anchor a bookmark toggles at: the visible page start in paged
    /// modes, the chapter start in scroll mode. Matching on the exact offset
    /// keeps ⌘D a true toggle — it removes exactly the bookmark it added.
    private var currentAnchorOffset: Int {
        layout == .scroll ? 0 : pagedAnchor
    }

    /// The bookmark on the page in view — the one the ribbon shows and ⌘D
    /// removes. Paged layouts: a text bookmark whose offset falls in the
    /// visible spread (so a repagination never unfills a bookmarked page).
    /// Scroll layout: any text bookmark in this chapter — a scrolling
    /// chapter has no page to be more precise about. Never a PDF page
    /// bookmark: those belong to the original pages.
    private var currentBookmark: Bookmark? {
        textBookmarks.first { bookmark in
            guard bookmark.chapterIndex == chapterIndex else { return false }
            if layout == .scroll { return true }
            if let visibleRange { return visibleRange.contains(bookmark.characterOffset) }
            return bookmark.characterOffset == pagedAnchor
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
        let title = book.chapterDisplayTitle(bookmark.chapterIndex)
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
            let range = self.range(for: target)
            presentAsk(AskRequest(
                selection: model.makeSelection(in: chapter, range: range),
                scope: askScope(selection: range),
                initialQuestion: nil
            ))

        case .listen:
            // The chapter the menu was opened in, like every sibling case —
            // not the view's current one, which a chapter turn could move.
            let index = book.chapters.firstIndex { $0.id == chapter.id } ?? chapterIndex
            listen(from: ListenAnchor(
                chapterIndex: index, characterOffset: range(for: target).lowerBound, isExact: true
            ))

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

    /// The live range a menu target stands for: a selection as given, a
    /// highlight's stored range (which may have been re-ranged since the span
    /// was painted), falling back to the span's.
    private func range(for target: AnnotationTarget) -> Range<Int> {
        switch target {
        case let .selection(selected):
            return selected
        case let .span(span):
            return highlight(withID: span.id)?.range ?? span.range
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

// MARK: - Welcome back

/// What the welcome-back line says: the absence ("it’s been 6 days") and
/// where the reader is ("Chapter 1 of 12 · 31% · Down the Rabbit-Hole").
struct WelcomeBackLine: Equatable {
    var absence: String
    var caption: String?
}

/// A page, as the reader's chapter and anchor identify one — what the
/// welcome-back count compares to tell a new page from the same one
/// reported twice.
private struct PagePosition: Equatable {
    var chapter: Int
    var anchor: Int
}

// MARK: - Footnote popup

/// Identifiable wrapper for the sheet/popover item binding — `Footnote.id`
/// is the source element id, unique per chapter but not globally.
struct FootnotePopup: Identifiable {
    let id = UUID()
    let note: Footnote
}

/// Footnote body presented in place of navigating to a notes document. The
/// text renders through the shared attributed builder, so emphasis inside
/// the note (its own `formatSpans`, nil ⇒ plain) styles like the page.
struct FootnoteView: View {
    let note: Footnote
    let style: ReaderStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FOOTNOTE")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(style.theme.faint)
                .padding(.bottom, 10)
            SelectableTextView(
                text: note.text,
                highlights: [],
                style: style,
                formatSpans: note.formatSpans ?? []
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.theme.elevated)
    }
}

// MARK: - TOC & chapter display titles

/// One row of the flattened TOC. Identity is the row's position — stable for
/// a given parse, which is all the Contents list needs.
struct FlatTOCEntry: Identifiable {
    let id: Int
    let entry: TOCEntry
    let depth: Int
}

extension Book {
    /// The real TOC flattened to rows in document order (parents before
    /// their children), with nesting depth for indentation. Empty when the
    /// book carries no parsed TOC.
    var flattenedTOC: [FlatTOCEntry] {
        var rows: [FlatTOCEntry] = []
        func walk(_ entries: [TOCEntry], depth: Int) {
            for entry in entries {
                rows.append(FlatTOCEntry(id: rows.count, entry: entry, depth: depth))
                walk(entry.children, depth: depth + 1)
            }
        }
        walk(metadata.tableOfContents, depth: 0)
        return rows
    }

    // `tocTitle(forChapterIndex:)` and `chapterDisplayTitle(_:)` live in
    // ReadrKit (Book.swift) so the reader header, the Contents list, the
    // "where am I" caption and the prompt anchor share one lookup and one
    // fallback wording.
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

/// Render-inert marker for "this anchor move came from narration, not the
/// reader" (see `SelectionMirror` for why it is a class in a `@State` slot).
final class NarrationMoveFlag {
    var isActive = false
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
    /// Contents-derived kicker title for a chapter without its own (the host
    /// resolves it from the TOC; nil keeps an untitled chapter kicker-less).
    var displayTitle: String? = nil
    /// Highlights in chapter coordinates.
    let highlights: [HighlightSpan]
    /// Inline images keyed by character offset in chapter coordinates.
    var inlineImages: [Int: InlineImage] = [:]
    /// Programmatic jump target (see SelectableTextView.scrollToOffset).
    var scrollTarget: Binding<Int?>? = nil
    var onAnnotate: (AnnotationTarget, AnnotationAction) -> Void = { _, _ in }
    /// The committed selection in chapter coordinates (nil ⇒ none) — feeds the
    /// host's selection-dependent keyboard shortcuts.
    var onSelectionChange: (Range<Int>?) -> Void = { _ in }
    /// A clean tap on the page (no selection, no annotation bar): the host
    /// toggles its chrome, Apple-Books-style. iOS only; nil ⇒ ignored.
    var onChromeToggle: (() -> Void)? = nil
    /// A tapped internal link — the host resolves and jumps.
    var onLinkTap: ((LinkTarget) -> Void)? = nil

    /// The shared appearance plus plate presentation for an image-only
    /// chapter, so a cover fills the column here exactly as it fills the page
    /// in paged layout — switching layout must not resize the artwork.
    ///
    /// `maxImageHeight` stays nil: a scrolling column has no page to overflow,
    /// so the plate sizes to the column width and grows as tall as its aspect
    /// requires, which is what a scrolling reader should do with a cover.
    private var renderStyle: ReaderStyle {
        guard ReaderStyle.isPlate(chapter.text) else { return style }
        var plate = style
        plate.platePresentation = true
        return plate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = chapter.title ?? displayTitle {
                // Displayed in caps, but exposed to accessibility under the
                // original title so UI tests (and VoiceOver) still find e.g.
                // "Chapter One".
                Text(title.uppercased())
                    .font(.system(size: 11))
                    .kerning(2)
                    .foregroundStyle(style.theme.faint)
                    .lineLimit(1)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("reader.kicker")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 26)
            }
            SelectableTextView(
                text: chapter.text,
                highlights: highlights,
                style: renderStyle,
                inlineImages: inlineImages,
                formatSpans: chapter.formatSpans ?? [],
                scrollToOffset: scrollTarget,
                onAnnotate: onAnnotate,
                onSelectionChange: onSelectionChange,
                // Scroll mode has no page-turn zones — any clean page tap
                // just toggles the chrome.
                onPageTap: { _, _ in onChromeToggle?() },
                onLinkTap: onLinkTap
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        // ~65–70 characters per line: measure = 33 em (avg glyph ≈ 0.5 em for
        // the serif content font) + the 48pt of column padding above — the
        // book measure Apple Books holds on wide panes (PagedChapterView
        // shares the same em count).
        //
        // Modifier ORDER is load-bearing: cap the column at the measure (and
        // let it fill the height) FIRST, paint `paper` on that capped column,
        // and only THEN expand to an infinite width to CENTER it. Painting the
        // paper after the infinite-width frame (the earlier bug) bled the page
        // surface edge-to-edge instead of a centered measure column — the
        // surplus window width should stay the deeper chrome `background`
        // (ReaderView draws it behind), exactly like paged mode centers its
        // page block over full-bleed paper.
        .frame(maxWidth: style.fontSize * 33 + 48, maxHeight: .infinity)
        .background(style.theme.paper)
        .frame(maxWidth: .infinity)
    }
}
