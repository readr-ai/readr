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

    /// Renders `view` at `size` into a PNG attachment named `name`. The
    /// hosting view goes into an offscreen (never-shown) window so AppKit
    /// controls that require a window backing still draw.
    private func snapshot(_ view: some View, size: CGSize, name: String) {
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
            XCTFail("\(name): could not create bitmap rep")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
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
            name: "m09-provider-settings-dtype-small"
        )
    }

    func testProviderSettingsDynamicTypeLarge() {
        snapshot(
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .dynamicTypeSize(.large),
            size: CGSize(width: 620, height: 900),
            name: "m10-provider-settings-dtype-large"
        )
    }

    func testProviderSettingsDynamicTypeAccessibility() {
        snapshot(
            ProviderSettingsView(app: model)
                .environmentObject(model)
                .dynamicTypeSize(.accessibility3),
            size: CGSize(width: 620, height: 1100),
            name: "m11-provider-settings-dtype-ax3"
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
