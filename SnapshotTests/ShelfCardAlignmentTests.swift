import XCTest
import SwiftUI
import AppKit
import ReadrKit
@testable import Readr

/// Cards on a shelf must line up row for row.
///
/// Home lays Continue Reading and Recently Added out as horizontal rows of
/// fixed-width cards, and the library grid stacks them in columns. The
/// caption under each jacket used to size itself to its own text, so a book
/// whose title wrapped to two lines — or one with no author at all — pushed
/// its own progress hairline, percentage and Continue pill below its
/// neighbour's. Reported from a device screenshot: two cards side by side
/// with their Continue pills a full line apart.
///
/// The caption now reserves two title lines and one author line regardless of
/// content, so a card's height depends only on its cover slot, never on its
/// metadata. These tests pin that: identical heights for wildly different
/// books, and — because "the numbers said aligned, the pixels disagreed" is
/// the recurring failure here — the rendered pill lands on the same row.
final class ShelfCardAlignmentTests: XCTestCase {
    private let theme = ReadingTheme.paper

    // MARK: - Fixtures

    private func book(title: String, authors: [String]) -> Book {
        Book(
            metadata: BookMetadata(title: title, authors: authors),
            chapters: [Chapter(title: "One", order: 0, text: "Body text.")],
            estimatedTokenCount: 12
        )
    }

    /// A one-line title with an author — the short card.
    private var shortBook: Book {
        book(title: "The Book of Elon", authors: ["Eric Jorgenson"])
    }

    /// A title that wraps to the caption's two-line limit, with an author.
    private var wrappingBook: Book {
        book(
            title: "Why Has Nobody Told Me This Before?",
            authors: ["Dr Julie Smith"]
        )
    }

    /// The other extreme: short title, no author line to draw at all.
    private var authorlessBook: Book {
        book(title: "Walden", authors: [])
    }

    /// `chapterLine` stands in for the card's "where am I" line: present
    /// for a text book, absent (nil) for a PDF — the row must not change
    /// height between the two.
    private func continueCard(_ book: Book, chapterLine: Bool) -> ContinueReadingCard {
        ContinueReadingCard(
            book: book,
            coverImage: nil,
            progress: 0.34,
            theme: theme,
            action: {},
            position: chapterLine
                ? ReadingPositionSummary(book: book, frontier: ReadingFrontier(chapterIndex: 0, characterOffset: 0))
                : nil
        )
    }

    // MARK: - Measuring

    /// The height SwiftUI would give `view` at its ideal size.
    private func fittingHeight(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.background(theme.background)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func luminance(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat? {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return 0.299 * color.redComponent
            + 0.587 * color.greenComponent
            + 0.114 * color.blueComponent
    }

    /// Text ink, sitting in the gap between the muted author line (0.47) and
    /// the darkest a jacket's drop shadow can make the paper background
    /// (0.92 × (1 − 0.16) ≈ 0.77) — so a scan that starts just below a cover
    /// never mistakes its shadow for the title.
    private func isText(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        (luminance(rep, x: x, y: y) ?? 1) < 0.65
    }

    /// Near-black: the Continue pill's ink fill. The generated placeholder
    /// jackets are tinted but nowhere near this dark.
    private func isPillInk(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        (luminance(rep, x: x, y: y) ?? 1) < 0.22
    }

    /// Top row of the LOWEST matching run in a vertical strip: scanned from
    /// the bottom of the render upward and stopped at the first clear row
    /// above the run, so whatever sits higher up the card is never reached.
    private func topRowOfLowestRun(
        _ rep: NSBitmapImageRep,
        xRange: Range<Int>,
        matching: (Int, Int) -> Bool
    ) -> Int? {
        var top: Int?
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            let hit = xRange.contains { matching($0, y) }
            if hit {
                top = y
            } else if top != nil {
                return top
            }
        }
        return top
    }

    /// First matching row at or below `fromRow` — used to find the title's
    /// first line by starting the scan just under the cover slot.
    private func firstRow(
        _ rep: NSBitmapImageRep,
        xRange: Range<Int>,
        fromRow: Int,
        matching: (Int, Int) -> Bool
    ) -> Int? {
        let start = max(0, fromRow)
        guard start < rep.pixelsHigh else { return nil }
        for y in start..<rep.pixelsHigh where xRange.contains(where: { matching($0, y) }) {
            return y
        }
        return nil
    }

    // MARK: - Continue Reading

    /// The bug as reported: a wrapping title next to a one-line title.
    func testContinueCardHeightIsIndependentOfTitleLength() {
        let short = fittingHeight(continueCard(shortBook, chapterLine: true))
        let wrapping = fittingHeight(continueCard(wrappingBook, chapterLine: true))
        XCTAssertEqual(
            short, wrapping, accuracy: 0.5,
            "A wrapping title must not make its card taller — the whole row "
                + "below the jacket shifts with it (\(short) vs \(wrapping))"
        )
    }

    /// A book with no author must still reserve the author's line.
    func testContinueCardHeightIsIndependentOfMissingAuthor() {
        let withAuthor = fittingHeight(continueCard(shortBook, chapterLine: true))
        let without = fittingHeight(continueCard(authorlessBook, chapterLine: true))
        XCTAssertEqual(
            withAuthor, without, accuracy: 0.5,
            "An author-less book must reserve the author line, not collapse it "
                + "(\(withAuthor) vs \(without))"
        )
    }

    /// A missing minutes-left estimate (PDFs never get one) must not resize
    /// the Continue row either.
    func testContinueCardHeightIsIndependentOfChapterLine() {
        let withEstimate = fittingHeight(continueCard(shortBook, chapterLine: true))
        let without = fittingHeight(continueCard(shortBook, chapterLine: false))
        XCTAssertEqual(
            withEstimate, without, accuracy: 0.5,
            "The Continue pill sets the row height; the estimate must not "
                + "(\(withEstimate) vs \(without))"
        )
    }

    // MARK: - Recently Added

    func testRecentlyAddedCardHeightIsIndependentOfMetadata() {
        let heights = [shortBook, wrappingBook, authorlessBook].map { book in
            fittingHeight(
                RecentlyAddedCard(book: book, coverImage: nil, theme: theme, action: {})
            )
        }
        XCTAssertEqual(
            heights[0], heights[1], accuracy: 0.5,
            "Recently Added cards must share one height (\(heights))"
        )
        XCTAssertEqual(
            heights[0], heights[2], accuracy: 0.5,
            "Recently Added cards must share one height (\(heights))"
        )
    }

    // MARK: - Caption primitive

    /// The grid uses the same caption with its own spacing; its height must
    /// still be metadata-independent.
    func testGridCaptionHeightIsIndependentOfMetadata() {
        let heights = [shortBook, wrappingBook, authorlessBook].map { book in
            fittingHeight(
                CardCaption(book: book, theme: theme, spacing: 3, showsAllAuthors: true)
                    .frame(width: 150)
            )
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "\(heights)")
        XCTAssertEqual(heights[0], heights[2], accuracy: 0.5, "\(heights)")
    }

    // MARK: - Cover slots

    /// A solid-blue jacket image, `aspect` wide for its height.
    private func coverArt(aspect: CGFloat) -> NSImage {
        let size = NSSize(width: 200 * aspect, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        // Explicit sRGB, not a dynamic system color: the sample below keys off
        // the exact channels and must not follow the runner's appearance.
        NSColor(srgbRed: 0, green: 0.3, blue: 1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// A jacket narrower than its 2:3 slot must hug the slot's leading edge,
    /// not float in the middle of it: centered jackets sat a few points in
    /// from their own card's title and from the neighbouring jacket.
    func testNarrowCoverHugsTheSlotsLeadingEdge() throws {
        let slot = BookCoverView.Slot(
            book: shortBook,
            coverImage: coverArt(aspect: 0.55),
            width: 150
        )
        let size = CGSize(width: 150, height: 225)
        let rep = try render(slot, size: size)

        let scale = CGFloat(rep.pixelsWide) / size.width
        // Mid-height, clear of the jacket's rounded corners.
        let midY = Int(CGFloat(rep.pixelsHigh) * 0.5)

        func isJacket(atPointX x: CGFloat) -> Bool {
            guard let color = rep.colorAt(x: Int(x * scale), y: midY)?
                .usingColorSpace(.sRGB) else { return false }
            // The jacket carries a faint sheen over the blue, but stays far
            // bluer than the paper background.
            return color.blueComponent > color.redComponent + 0.2
        }

        // 0.55 aspect in a 150×225 slot → a jacket ~124pt wide.
        XCTAssertTrue(isJacket(atPointX: 4), "jacket does not start at the slot's leading edge")
        XCTAssertTrue(isJacket(atPointX: 100), "jacket does not span its own width")
        XCTAssertFalse(isJacket(atPointX: 140), "jacket is not leading-aligned — air belongs on the trailing side")
    }

    // MARK: - Pixels

    /// Card geometry shared by the rendered-row tests: 24pt of padding, two
    /// 150pt cards, a 24pt gap.
    private let rowPadding: CGFloat = 24
    private let cardWidth: CGFloat = 150
    private let cardGap: CGFloat = 24
    /// The 2:3 cover slot at the top of every card.
    private var coverSlotHeight: CGFloat { cardWidth * 1.5 }

    private var rowWidth: CGFloat { rowPadding * 2 + cardWidth * 2 + cardGap }

    private func cardLeading(_ index: Int) -> CGFloat {
        rowPadding + CGFloat(index) * (cardWidth + cardGap)
    }

    /// Renders `row` at exactly its ideal height, so the content starts at the
    /// top of the bitmap instead of being centred in a taller frame — point
    /// coordinates below the cover can then be computed, not guessed.
    private func renderRow(_ row: some View) throws -> (NSBitmapImageRep, CGFloat) {
        let height = fittingHeight(row)
        let rep = try render(row, size: CGSize(width: rowWidth, height: height))
        return (rep, CGFloat(rep.pixelsWide) / rowWidth)
    }

    /// Full-width band over one card, for finding its text.
    private func textBand(_ index: Int, scale: CGFloat) -> Range<Int> {
        Int(cardLeading(index) * scale)..<Int((cardLeading(index) + cardWidth) * scale)
    }

    /// The reported bug: a one-line title next to a two-line one moved the
    /// author beneath it. Both authors must render on the same row.
    func testAuthorLinesShareATopEdgeAcrossRecentlyAddedCards() throws {
        let row = HStack(alignment: .top, spacing: cardGap) {
            RecentlyAddedCard(book: wrappingBook, coverImage: nil, theme: theme, action: {})
            RecentlyAddedCard(book: shortBook, coverImage: nil, theme: theme, action: {})
        }
        .padding(rowPadding)

        let (rep, scale) = try renderRow(row)

        // The author is the last thing on a Recently Added card, so the lowest
        // text run in each band is it.
        let left = try XCTUnwrap(
            topRowOfLowestRun(rep, xRange: textBand(0, scale: scale)) { isText(rep, x: $0, y: $1) },
            "no author text found under the two-line-title card"
        )
        let right = try XCTUnwrap(
            topRowOfLowestRun(rep, xRange: textBand(1, scale: scale)) { isText(rep, x: $0, y: $1) },
            "no author text found under the one-line-title card"
        )

        XCTAssertEqual(
            CGFloat(left), CGFloat(right), accuracy: 2 * scale,
            "Author lines must sit on the same row whatever the titles do "
                + "(left y=\(left), right y=\(right))"
        )

        attach(rep, named: "m-home-recently-added-alignment")
    }

    /// The titles themselves must start on the same row too: a reserved-space
    /// Text centres a short title in its box, which would drop the first line
    /// of the one-line card.
    func testTitlesShareATopEdgeAcrossRecentlyAddedCards() throws {
        let row = HStack(alignment: .top, spacing: cardGap) {
            RecentlyAddedCard(book: wrappingBook, coverImage: nil, theme: theme, action: {})
            RecentlyAddedCard(book: shortBook, coverImage: nil, theme: theme, action: {})
        }
        .padding(rowPadding)

        let (rep, scale) = try renderRow(row)

        // Start below the jacket so the tinted placeholder cover is skipped.
        let belowCover = Int((rowPadding + coverSlotHeight + 4) * scale)
        let left = try XCTUnwrap(
            firstRow(rep, xRange: textBand(0, scale: scale), fromRow: belowCover) {
                isText(rep, x: $0, y: $1)
            },
            "no title text found under the left jacket"
        )
        let right = try XCTUnwrap(
            firstRow(rep, xRange: textBand(1, scale: scale), fromRow: belowCover) {
                isText(rep, x: $0, y: $1)
            },
            "no title text found under the right jacket"
        )

        XCTAssertEqual(
            CGFloat(left), CGFloat(right), accuracy: 2 * scale,
            "Titles must start on the same row — a short title must sit at the "
                + "TOP of its two-line box, not centred (left y=\(left), right y=\(right))"
        )
    }

    /// Renders the real two-card Continue Reading row and checks the pills
    /// share a top edge — the first thing the screenshots showed going wrong.
    func testContinuePillsShareATopEdgeAcrossCards() throws {
        let row = HStack(alignment: .top, spacing: cardGap) {
            continueCard(shortBook, chapterLine: true)
            continueCard(wrappingBook, chapterLine: true)
        }
        .padding(rowPadding)

        let (rep, scale) = try renderRow(row)

        // Identical 20…60pt bands measured from each card's leading edge —
        // inside the capsule's flat top, clear of its rounded ends, and clear
        // of the "~N min left" text trailing it.
        func pillBand(_ index: Int) -> Range<Int> {
            Int((cardLeading(index) + 20) * scale)..<Int((cardLeading(index) + 60) * scale)
        }

        let left = try XCTUnwrap(
            topRowOfLowestRun(rep, xRange: pillBand(0)) { isPillInk(rep, x: $0, y: $1) },
            "no pill in the left card"
        )
        let right = try XCTUnwrap(
            topRowOfLowestRun(rep, xRange: pillBand(1)) { isPillInk(rep, x: $0, y: $1) },
            "no pill in the right card"
        )

        XCTAssertEqual(
            CGFloat(left), CGFloat(right), accuracy: 2 * scale,
            "Continue pills must sit on the same row (left y=\(left), right y=\(right))"
        )

        attach(rep, named: "m-home-continue-reading-alignment")
    }

    private func attach(_ rep: NSBitmapImageRep, named name: String) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
