import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A book jacket in the Marginalia style: real cover art when the book
/// carries it, otherwise a flat tinted placeholder jacket (title-keyed muted
/// field, short top rule, serif title, small-caps author). Always 2:3, with
/// the shared cover radius/shadow.
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
    /// determines the width and the height follows from the 2:3 aspect.
    var width: CGFloat?

    var body: some View {
        AppTheme.coverShadow(
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: width)
                .overlay(coverContent)
                .overlay(sheen)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        )
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
