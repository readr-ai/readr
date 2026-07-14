import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A book jacket in the Marginalia style: real cover art when the book
/// carries it, otherwise a flat tinted placeholder jacket (title-keyed muted
/// field, short top rule, serif title, small-caps author), with the shared
/// cover radius/shadow.
///
/// Real artwork keeps its own aspect ratio (clamped to a sane book range) —
/// forcing every cover into 2:3 cropped off titles and edges, nothing like a
/// real shelf. Placeholders stay 2:3. Shelves that need uniform cells wrap
/// this in `BookCoverSlot`, which bottom-aligns jackets in a fixed 2:3 slot
/// (Apple-Books-style: books standing on a shelf).
///
/// The cover is treated as decorative for accessibility — the surrounding cell
/// supplies the book's title/author as text, so the jacket's painted text is
/// hidden to avoid duplicate elements.
struct BookCoverView: View {
    let book: Book
    /// Pre-decoded cover artwork (from `AppModel.coverImage(for:)`, which
    /// caches decodes) — decoding `Data` per render made shelf scrolling hitch.
    var coverImage: PlatformImage?
    /// Optional fixed width; when nil the container (e.g. a grid cell)
    /// determines the width and the height follows from the aspect ratio.
    var width: CGFloat?

    /// Width/height. Real art within 0.55…1.0 renders uncropped; anything
    /// beyond clamps (a hair of fill-crop) so a banner or strip "cover" can't
    /// wreck the shelf. Placeholders are the classic 2:3.
    private var aspect: CGFloat {
        if let coverImage, coverImage.size.width > 0, coverImage.size.height > 0 {
            return min(max(coverImage.size.width / coverImage.size.height, 0.55), 1.0)
        }
        return 2.0 / 3.0
    }

    var body: some View {
        let jacket = AppTheme.coverShadow(
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .frame(width: width)
                .overlay(coverContent)
                .overlay(sheen)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        )
        #if os(iOS)
        // iPad trackpad/mouse affordance: the jacket lifts under the pointer.
        // Every BookCoverView call site is a tappable plain-style button (the
        // library grid cell, Home's Continue Reading and Recently Added
        // cards), so the effect never lands on a non-interactive cover.
        // `.hoverEffect` is UIKit-backed — unavailable on macOS SwiftUI,
        // where LibraryGridView draws its own hover lift — and inert on
        // touch-only iPhones, so no idiom gate is needed. The content shape
        // keeps the effect hugging the jacket's own corner radius instead of
        // the default system rounding.
        return jacket
            .contentShape(
                .hoverEffect,
                RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous)
            )
            .hoverEffect(.lift)
        #else
        return jacket
        #endif
    }

    /// A fixed-proportion 2:3 shelf slot with the jacket resting on its
    /// bottom edge. Grids and shelf rows use this so every cell is the same
    /// size while covers keep their true shapes — bottoms aligned, like books
    /// standing on a shelf (the Apple Books grid convention). A cover wider
    /// than 2:3 fits the slot's width and leaves air above; a (clamped)
    /// narrower one fits the height.
    struct Slot: View {
        let book: Book
        var coverImage: PlatformImage?
        var width: CGFloat?

        var body: some View {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: width)
                .overlay(alignment: .bottom) {
                    BookCoverView(book: book, coverImage: coverImage)
                }
        }
    }

    /// A faint diagonal gloss over real artwork so it reads as a printed
    /// cover. Placeholder jackets stay flat (the Marginalia look).
    @ViewBuilder
    private var sheen: some View {
        if coverImage != nil {
            LinearGradient(
                colors: [Color.white.opacity(0.10), .clear, Color.black.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var coverContent: some View {
        if let coverImage {
            #if canImport(UIKit)
            Image(uiImage: coverImage).resizable().scaledToFill()
            #elseif canImport(AppKit)
            Image(nsImage: coverImage).resizable().scaledToFill()
            #endif
        } else {
            generatedCover
        }
    }

    /// The flat tinted placeholder jacket: a deep muted field keyed off the
    /// title, a short 2px rule in the cover ink, the serif title, and the
    /// author in tracked small caps pinned to the foot.
    private var generatedCover: some View {
        let tint = AppTheme.coverTint(for: book.metadata.title)
        return ZStack {
            tint.field
            VStack(alignment: .leading, spacing: 10) {
                Rectangle()
                    .fill(tint.ink.opacity(0.55))
                    .frame(width: 26, height: 2)
                Text(book.metadata.title)
                    .font(.system(size: 15.5, weight: .semibold, design: .serif))
                    .foregroundStyle(tint.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if let author = book.metadata.authors.first {
                    Text(author.uppercased())
                        .font(.system(size: 9.5))
                        .tracking(1.24)
                        .foregroundStyle(tint.ink.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(14)
            // The cell's own title/author text carries the accessible name;
            // hiding the painted text avoids duplicate static-text elements
            // (the UI tests tap `staticTexts["Sample Book"]`).
            .accessibilityHidden(true)
        }
    }
}
