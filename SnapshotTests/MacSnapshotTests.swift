import XCTest
import SwiftUI
import ReadrKit
@testable import Readr

/// macOS visual coverage: renders the key SwiftUI surfaces offscreen via
/// `NSHostingView` and attaches PNGs to the result bundle, where CI's xcparse
/// step publishes them to the `ci-screenshots` branch alongside the iOS walk
/// (m-prefixed names). Deterministic by design — no window server, no XCUITest
/// automation session — so it can gate merges without runner flakiness.
///
/// What it covers: the `#if os(macOS)` layout code the iPhone walk can never
/// reach. What it can't: real toolbar/window chrome and interactions — that
/// stays a manual pass (docs/DEVELOPMENT-PLAN.md).
@MainActor
final class MacSnapshotTests: XCTestCase {

    private var model: AppModel!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        model = AppModel.uiTestSeededModel()
    }

    /// The seeded "Sample Book" (mid-read position + colored highlights).
    private var sampleBook: Book { model.books[0] }

    private var sampleChapter: Chapter { sampleBook.chapters[0] }

    /// Highlight spans for the seeded chapter, exactly as ReaderView builds
    /// them.
    private var sampleSpans: [HighlightSpan] {
        model.highlights(for: sampleBook)
            .filter { $0.chapterID == sampleChapter.id }
            .map {
                HighlightSpan(
                    id: $0.id,
                    range: $0.range,
                    color: $0.markerColor,
                    hasNote: !($0.note ?? "").isEmpty
                )
            }
    }

    // MARK: - Rendering

    /// Renders `view` at `size` into an offscreen bitmap. The hosting view goes
    /// into an offscreen (never-shown) window so AppKit controls that require a
    /// window backing still draw. Returns the rep so callers can both attach a
    /// PNG and sample individual pixels for layout/theming assertions.
    @discardableResult
    private func render(_ view: some View, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Renders `view` at `size` into a PNG attachment named `name`.
    private func snapshot(_ view: some View, size: CGSize, name: String) {
        guard let rep = render(view, size: size) else {
            XCTFail("\(name): could not create bitmap rep")
            return
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("\(name): could not encode PNG")
            return
        }
        // Sanity floor: a blank render encodes to almost nothing.
        XCTAssertGreaterThan(png.count, 4_000, "\(name): suspiciously small render")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The sRGB color at a fractional position (0…1 across width/height) of the
    /// rendered bitmap. Fractions insulate the sample from the rep's backing
    /// scale (Retina reps are 2× the point size).
    private func color(
        in rep: NSBitmapImageRep, atFractionX fx: CGFloat, fractionY fy: CGFloat
    ) -> NSColor? {
        let x = min(rep.pixelsWide - 1, max(0, Int(CGFloat(rep.pixelsWide) * fx)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(CGFloat(rep.pixelsHigh) * fy)))
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// Two colors are visually the same channel-wise within `tolerance` (0…1).
    private func colorsClose(
        _ lhs: NSColor?, _ rhs: NSColor?, tolerance: CGFloat = 0.05
    ) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs?.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) <= tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }

    /// Euclidean sRGB distance, or a large sentinel if either is unreadable.
    /// Used to pick the NEAREST of two candidate surfaces when they differ by
    /// only a few percent (paper vs. chrome background), which is too tight for
    /// a fixed tolerance but still unambiguous as "which is closer".
    private func distance(_ lhs: NSColor?, _ rhs: NSColor?) -> CGFloat {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs?.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }
        let dr = lhs.redComponent - rhs.redComponent
        let dg = lhs.greenComponent - rhs.greenComponent
        let db = lhs.blueComponent - rhs.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    // MARK: - Reader

    func testPagedReaderPaperSinglePage() {
        snapshot(
            PagedChapterView(
                chapter: sampleChapter,
                layout: .singlePage,
                style: ReaderStyle(theme: .paper, fontSize: 18),
                highlights: sampleSpans,
                anchorOffset: .constant(0)
            )
            .background(ReadingTheme.paper.background),
            size: CGSize(width: 900, height: 700),
            name: "m01-paged-paper-single"
        )
    }

    func testPagedReaderSepiaSpread() {
        snapshot(
            PagedChapterView(
                chapter: sampleChapter,
                layout: .doublePage,
                style: ReaderStyle(theme: .sepia, fontSize: 16),
                highlights: sampleSpans,
                anchorOffset: .constant(0)
            )
            .background(ReadingTheme.sepia.background),
            size: CGSize(width: 1200, height: 760),
            name: "m02-paged-sepia-spread"
        )
    }

    func testPagedReaderDarkSinglePage() {
        snapshot(
            PagedChapterView(
                chapter: sampleChapter,
                layout: .singlePage,
                style: ReaderStyle(theme: .night, fontSize: 18),
                highlights: sampleSpans,
                anchorOffset: .constant(0)
            )
            .background(ReadingTheme.night.background),
            size: CGSize(width: 900, height: 700),
            name: "m03-paged-dark-single"
        )
    }

    func testScrollReaderPaper() {
        snapshot(
            VStack(spacing: 0) {
                ScrollReadingColumn(
                    chapter: sampleChapter,
                    style: ReaderStyle(theme: .paper, fontSize: 18),
                    highlights: sampleSpans
                )
            }
            .background(ReadingTheme.paper.background),
            size: CGSize(width: 1100, height: 760),
            name: "m08-scroll-paper"
        )
    }

    /// R9: scroll mode must paint the paper as a CENTERED measure column, not
    /// full-width. On a window far wider than the measure the outer margins
    /// stay the deeper chrome `background`, and only the centered column is
    /// `paper`. The pre-fix modifier order (`.background` after the infinite
    /// frame) bled paper edge-to-edge, so both edges and center read as paper.
    func testScrollColumnIsCenteredNotFullWidth() {
        let theme = ReadingTheme.paper
        // Width is well beyond the measure (fontSize 18 ⇒ 18*33+48 = 642pt), so
        // symmetric background margins must remain (~229pt each side at 1100).
        let size = CGSize(width: 1100, height: 760)
        guard let rep = render(
            ScrollReadingColumn(
                chapter: sampleChapter,
                style: ReaderStyle(theme: theme, fontSize: 18),
                highlights: sampleSpans
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background),
            size: size
        ) else {
            XCTFail("scroll column: could not render")
            return
        }
        let background = NSColor(theme.background)
        let paper = NSColor(theme.paper)
        XCTAssertGreaterThan(
            distance(background, paper), 0.0,
            "test premise: paper and chrome background must differ"
        )
        // paper (0xFAF7F0) and background (0xEFEBE1) differ by only a few
        // percent, too tight for a fixed tolerance, so classify each sample by
        // whichever surface it is NEAREST. Outer margins must be background;
        // the centered column must be paper.
        let left = color(in: rep, atFractionX: 0.02, fractionY: 0.5)
        let right = color(in: rep, atFractionX: 0.98, fractionY: 0.5)
        // Sample low in the column to clear the kicker / first text lines.
        let center = color(in: rep, atFractionX: 0.5, fractionY: 0.9)
        XCTAssertLessThan(
            distance(left, background), distance(left, paper),
            "scroll column left edge should be chrome background, not full-width paper"
        )
        XCTAssertLessThan(
            distance(right, background), distance(right, paper),
            "scroll column right edge should be chrome background, not full-width paper"
        )
        XCTAssertLessThan(
            distance(center, paper), distance(center, background),
            "scroll column center should be the paper surface"
        )
    }

    // MARK: - PDF popover theming (R10)

    /// R10: the find-in-PDF popover adopts the reading theme's elevated surface
    /// in every theme, rather than a system material that reads as stark
    /// white/gray chrome on sepia/dark. Asserts a corner (bare chrome, clear of
    /// the field and empty-state text) matches `theme.elevated`.
    func testPDFSearchPopoverThemedPerTheme() {
        for option in ReadingTheme.allCases {
            UserDefaults.standard.set(option.rawValue, forKey: "readingTheme")
            let controller = PDFReaderController()
            guard let rep = render(
                PDFSearchView(controller: controller, onDismiss: {}),
                size: CGSize(width: 360, height: 420)
            ) else {
                XCTFail("pdf search (\(option.rawValue)): could not render")
                continue
            }
            // Bottom-left corner: below the centered empty-state text, so it is
            // the popover's own elevated background.
            XCTAssertTrue(
                colorsClose(
                    color(in: rep, atFractionX: 0.03, fractionY: 0.96),
                    NSColor(option.elevated)
                ),
                "pdf search popover should use \(option.rawValue) elevated surface"
            )
            snapshot(
                PDFSearchView(controller: controller, onDismiss: {}),
                size: CGSize(width: 360, height: 420),
                name: "m09-pdf-search-\(option.rawValue)"
            )
        }
        UserDefaults.standard.removeObject(forKey: "readingTheme")
    }

    /// R10: the PDF contents (outline) popover is likewise themed to the
    /// elevated reading surface in every theme.
    func testPDFOutlinePopoverThemedPerTheme() {
        for option in ReadingTheme.allCases {
            UserDefaults.standard.set(option.rawValue, forKey: "readingTheme")
            let controller = PDFReaderController()
            guard let rep = render(
                PDFOutlineList(controller: controller, dismiss: {}),
                size: CGSize(width: 260, height: 76)
            ) else {
                XCTFail("pdf outline (\(option.rawValue)): could not render")
                continue
            }
            // Top-left corner: clear of the centered "No table of contents"
            // label, so it is the popover's elevated background.
            XCTAssertTrue(
                colorsClose(
                    color(in: rep, atFractionX: 0.03, fractionY: 0.04),
                    NSColor(option.elevated)
                ),
                "pdf outline popover should use \(option.rawValue) elevated surface"
            )
        }
        UserDefaults.standard.removeObject(forKey: "readingTheme")
    }

    // MARK: - Chrome & panels

    func testAppearancePopover() {
        snapshot(
            AppearancePopover(
                themeRaw: .constant(ReadingTheme.paper.rawValue),
                layoutRaw: .constant(PageLayout.singlePage.rawValue),
                fontSize: .constant(18),
                fontRaw: .constant(ReaderFont.newYork.rawValue),
                lineSpacingRaw: .constant(ReaderLineSpacing.normal.rawValue),
                isJustified: .constant(true),
                isPDF: true,
                pdfShowsOriginal: .constant(true)
            ),
            size: CGSize(width: 320, height: 520),
            name: "m04-appearance-popover"
        )
    }

    func testAnnotationMenuCreateAndEdit() {
        snapshot(
            VStack(spacing: 16) {
                AnnotationMenuView(
                    mode: .create,
                    theme: .paper,
                    onHighlight: { _ in }, onNote: {}, onAsk: {}, onCopy: {},
                    onRemove: nil
                )
                AnnotationMenuView(
                    mode: .edit(currentColor: .green, hasNote: true),
                    theme: .paper,
                    onHighlight: { _ in }, onNote: {}, onAsk: {}, onCopy: {},
                    onRemove: {}
                )
            }
            .padding(24)
            .background(ReadingTheme.paper.paper),
            size: CGSize(width: 460, height: 180),
            name: "m05-annotation-menu"
        )
    }

    func testNotesPanel() {
        snapshot(
            NotesPanel(book: sampleBook)
                .environmentObject(model)
                .frame(width: 340),
            size: CGSize(width: 340, height: 640),
            name: "m06-notes-panel"
        )
    }

    // MARK: - R7: Create Article CTA states

    /// R7: the "Create Article" CTA is the design's one legit Iris-filled AI
    /// button — captured on a book WITH highlights (the seeded sample) so the
    /// filled-iris treatment is visible in the gallery.
    func testCreateArticleCTAReady() {
        snapshot(
            NotesHeaderActions(book: sampleBook)
                .environmentObject(model)
                .padding(16)
                .frame(width: 340)
                .background(ReadingTheme.paper.background),
            size: CGSize(width: 340, height: 120),
            name: "m10-create-article-cta-ready"
        )
    }

    /// R7: the CTA is always enabled — even on a book with NO highlights it
    /// stays a live Iris button (tapping it opens the studio's guidance state,
    /// covered by the zero-highlights snapshot below).
    func testCreateArticleCTAEmpty() {
        let (emptyBook, emptyModel) = Self.bookWithNoHighlights()
        snapshot(
            NotesHeaderActions(book: emptyBook)
                .environmentObject(emptyModel)
                .padding(16)
                .frame(width: 340)
                .background(ReadingTheme.paper.background),
            size: CGSize(width: 340, height: 120),
            name: "m11-create-article-cta-empty"
        )
    }

    /// A book with zero highlights, in a fresh in-memory store — shared by the
    /// empty-CTA and zero-highlights-studio snapshots.
    private static func bookWithNoHighlights() -> (Book, AppModel) {
        let book = Book(
            metadata: BookMetadata(title: "Unread Book", authors: ["Nobody"]),
            chapters: [Chapter(title: "One", order: 0, text: "A short chapter.")],
            estimatedTokenCount: 10
        )
        let store = InMemoryLibraryStore()
        try? store.add(book)
        return (book, AppModel(store: store))
    }

    /// R7: opening the studio for a book with zero highlights lands on the
    /// "Highlight something first" guidance (create-article-empty mockup),
    /// not a dead disabled control.
    func testArticleStudioZeroHighlights() {
        let (emptyBook, emptyModel) = Self.bookWithNoHighlights()
        snapshot(
            ArticleStudioView(book: emptyBook)
                .environmentObject(emptyModel),
            size: CGSize(width: 640, height: 560),
            name: "m12-article-studio-zero-highlights"
        )
    }

    // MARK: - R6: Iris-discipline chrome corrections

    /// R6/D1: the color-filter chips + a noted highlight card render with the
    /// neutral ❋ marker (muted, not Iris) — verifies Iris no longer leaks into
    /// generic chrome in the notes list.
    func testAnnotationListNeutralChrome() {
        snapshot(
            AnnotationListView(book: sampleBook)
                .environmentObject(model)
                .frame(width: 340)
                .background(ReadingTheme.paper.background),
            size: CGSize(width: 340, height: 520),
            name: "m13-annotation-list-neutral-chrome"
        )
    }

    /// R6/D1: the Appearance popover's Justify toggle now tints neutral ink
    /// (generic chrome), captured alongside the reset of the popover.
    func testAppearancePopoverNeutralJustify() {
        snapshot(
            AppearancePopover(
                themeRaw: .constant(ReadingTheme.night.rawValue),
                layoutRaw: .constant(PageLayout.singlePage.rawValue),
                fontSize: .constant(18),
                fontRaw: .constant(ReaderFont.newYork.rawValue),
                lineSpacingRaw: .constant(ReaderLineSpacing.normal.rawValue),
                isJustified: .constant(true),
                isPDF: false,
                pdfShowsOriginal: .constant(true)
            ),
            size: CGSize(width: 320, height: 520),
            name: "m14-appearance-popover-dark-neutral"
        )
    }

    // MARK: - Library

    // MARK: - Settings (A7/A9)

    /// Provider settings at three Dynamic Type sizes, proving the AI/settings
    /// surfaces now scale (A9) — the cards use semantic text styles / no fixed
    /// `.system(size:)`, so text grows with the environment's size. Rendered
    /// through `NSHostingView`, which honors the injected `dynamicTypeSize`.
    func testProviderSettingsDynamicTypeSmall() {
        snapshot(
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .dynamicTypeSize(.small),
            size: CGSize(width: 620, height: 760),
            name: "m15-provider-settings-dtype-small"
        )
    }

    func testProviderSettingsDynamicTypeLarge() {
        snapshot(
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .dynamicTypeSize(.large),
            size: CGSize(width: 620, height: 900),
            name: "m16-provider-settings-dtype-large"
        )
    }

    func testProviderSettingsDynamicTypeAccessibility() {
        snapshot(
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .dynamicTypeSize(.accessibility3),
            size: CGSize(width: 620, height: 1100),
            name: "m17-provider-settings-dtype-ax3"
        )
    }

    /// A9: the Ask panel now uses semantic text styles (no fixed
    /// `.system(size:)`), so its quote, input, chips, caption and answer scale
    /// with Dynamic Type. Rendered at an accessibility size to prove the AI
    /// surface grows with the environment like Settings does.
    func testAskPanelDynamicTypeAccessibility() {
        snapshot(
            AskPanelView(app: model, book: sampleBook, selection: nil)
                .environmentObject(model)
                .dynamicTypeSize(.accessibility3),
            size: CGSize(width: 620, height: 900),
            name: "m18-ask-panel-dtype-ax3"
        )
    }

    /// A9: the Article studio picker uses semantic text styles too, so its
    /// heading, highlight cards, counts and direction field scale with Dynamic
    /// Type. Rendered at an accessibility size alongside the Ask panel.
    func testArticleStudioDynamicTypeAccessibility() {
        snapshot(
            ArticleStudioView(book: sampleBook)
                .environmentObject(model)
                .dynamicTypeSize(.accessibility3),
            size: CGSize(width: 640, height: 900),
            name: "m19-article-studio-dtype-ax3"
        )
    }

    // MARK: - First-run copy logic (A6)

    /// On macOS the Local row is shown and OAuth is hidden, so the setup copy
    /// advertises the API-key and local-model paths but never "sign in".
    func testSetupGuidanceMatchesAvailablePathsOnMac() {
        let paths = SettingsModel.availableSetupPaths
        XCTAssertTrue(paths.contains("Add an API key"))
        XCTAssertFalse(
            paths.contains("sign in"),
            "Subscription OAuth is hidden, so 'sign in' must not be advertised"
        )
        XCTAssertTrue(
            paths.contains("pick a local model"),
            "The Local row is shown on Mac, so its path is a legitimate suggestion"
        )

        let guidance = SettingsModel.setupGuidance(toDo: "ask questions")
        XCTAssertTrue(guidance.hasSuffix("to ask questions."))
        XCTAssertFalse(
            guidance.lowercased().contains("sign in"),
            "Guidance must not advertise the hidden OAuth path"
        )
        // Two paths join with a plain "or" (no Oxford comma).
        XCTAssertEqual(guidance, "Add an API key or pick a local model to ask questions.")
    }

    // MARK: - Library

    func testLibraryGrid() {
        snapshot(
            LibraryGridView(
                title: "All Books",
                books: model.books,
                query: "",
                openBook: { _ in },
                showNotes: {},
                isImporting: .constant(false),
                showSettings: .constant(false)
            )
            .environmentObject(model),
            size: CGSize(width: 1100, height: 760),
            name: "m07-library-grid"
        )
    }
}
