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

    private func continueCard(_ book: Book, minutesLeft: Int?) -> ContinueReadingCard {
        ContinueReadingCard(
            book: book,
            coverImage: nil,
            progress: 0.34,
            minutesLeft: minutesLeft,
            theme: theme,
            action: {}
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

    /// True when the pixel is near-black — the Continue pill's ink fill. The
    /// generated placeholder jackets are tinted but nowhere near this dark,
    /// so the threshold isolates the pill.
    private func isPillInk(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * color.redComponent
            + 0.587 * color.greenComponent
            + 0.114 * color.blueComponent
        return luminance < 0.22
    }

    /// The topmost row carrying pill ink within a vertical strip. Scanned
    /// from the bottom of the render upward and stopped at the first clear
    /// row above the pill, so the ink title and the jacket further up are
    /// never reached.
    private func pillTopRow(_ rep: NSBitmapImageRep, xRange: Range<Int>) -> Int? {
        var top: Int?
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            let hasInk = xRange.contains { isPillInk(rep, x: $0, y: y) }
            if hasInk {
                top = y
            } else if top != nil {
                return top
            }
        }
        return top
    }

    // MARK: - Continue Reading

    /// The bug as reported: a wrapping title next to a one-line title.
    func testContinueCardHeightIsIndependentOfTitleLength() {
        let short = fittingHeight(continueCard(shortBook, minutesLeft: 9))
        let wrapping = fittingHeight(continueCard(wrappingBook, minutesLeft: 8))
        XCTAssertEqual(
            short, wrapping, accuracy: 0.5,
            "A wrapping title must not make its card taller — the whole row "
                + "below the jacket shifts with it (\(short) vs \(wrapping))"
        )
    }

    /// A book with no author must still reserve the author's line.
    func testContinueCardHeightIsIndependentOfMissingAuthor() {
        let withAuthor = fittingHeight(continueCard(shortBook, minutesLeft: 9))
        let without = fittingHeight(continueCard(authorlessBook, minutesLeft: 9))
        XCTAssertEqual(
            withAuthor, without, accuracy: 0.5,
            "An author-less book must reserve the author line, not collapse it "
                + "(\(withAuthor) vs \(without))"
        )
    }

    /// A missing minutes-left estimate (PDFs never get one) must not resize
    /// the Continue row either.
    func testContinueCardHeightIsIndependentOfMinutesEstimate() {
        let withEstimate = fittingHeight(continueCard(shortBook, minutesLeft: 9))
        let without = fittingHeight(continueCard(shortBook, minutesLeft: nil))
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

    /// Renders the real two-card row and checks the Continue pills share a
    /// top edge — the thing the screenshot showed going wrong.
    func testContinuePillsShareATopEdgeAcrossCards() throws {
        let row = HStack(alignment: .top, spacing: 24) {
            continueCard(shortBook, minutesLeft: 9)
            continueCard(wrappingBook, minutesLeft: 8)
        }
        .padding(24)

        // 24pt padding + two 150pt cards + the 24pt gap.
        let size = CGSize(width: 372, height: 460)
        let rep = try render(row, size: size)

        let scale = CGFloat(rep.pixelsWide) / size.width
        // Identical 20…60pt bands measured from each card's leading edge —
        // inside the capsule's flat top, clear of its rounded ends, and clear
        // of the "~N min left" text trailing it.
        func band(cardLeading: CGFloat) -> Range<Int> {
            Int((cardLeading + 20) * scale)..<Int((cardLeading + 60) * scale)
        }
        let leftBand = band(cardLeading: 24)
        let rightBand = band(cardLeading: 24 + 150 + 24)

        let left = try XCTUnwrap(pillTopRow(rep, xRange: leftBand), "no pill in the left card")
        let right = try XCTUnwrap(pillTopRow(rep, xRange: rightBand), "no pill in the right card")

        XCTAssertEqual(
            CGFloat(left), CGFloat(right), accuracy: 2 * scale,
            "Continue pills must sit on the same row (left y=\(left), right y=\(right))"
        )

        if let png = rep.representation(using: .png, properties: [:]) {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "m-home-shelf-card-alignment"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
