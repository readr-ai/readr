import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A book jacket in the "Paper & Ink" style: real cover art when the book
/// carries it, otherwise a generated placeholder cover (deterministic gradient
/// plus serif title/author). Always 2:3, with the shared cover radius/shadow.
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
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.coverRadius, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        )
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

    /// A tasteful placeholder jacket: title-keyed gradient, serif title, and
    /// the author in small type at the bottom.
    private var generatedCover: some View {
        ZStack {
            LinearGradient(
                colors: AppTheme.coverGradient(for: book.metadata.title),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(book.metadata.title)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if let author = book.metadata.authors.first {
                    Text(author)
                        .font(.caption)
                        .fontDesign(.serif)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(12)
            // The cell's own title/author text carries the accessible name;
            // hiding the painted text avoids duplicate static-text elements
            // (the UI tests tap `staticTexts["Sample Book"]`).
            .accessibilityHidden(true)
        }
    }
}
