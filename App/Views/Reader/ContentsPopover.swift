import SwiftUI
import ReadrKit

// The pieces both Contents popovers are built from — the text reader's
// (bookmarks, then the chapter list) and the PDF reader's (bookmarks, then
// the outline). One design, one implementation: the caps section label,
// the bookmark row with its jump and ✕, the ribbon marker on a row that
// holds a bookmark, the ribbon toggle in the toolbar, and the popover's
// sizing. (September 2026 UX review, F9.)

/// The caps label above a section ("BOOKMARKS", "CONTENTS").
struct ContentsSectionHeader: View {
    let title: String
    let theme: ReadingTheme

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(1.5)
            .foregroundStyle(theme.faint)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One bookmark: where it is in caps, what it says in serif, tap to jump,
/// ✕ to remove. Two separate buttons side by side — never a row that is
/// itself a button, so ✕ can't also jump.
struct ContentsBookmarkRow: View {
    /// "DOWN THE RABBIT-HOLE" / "PAGE 12".
    let kicker: String
    /// The quoted passage; empty for a bookmark with nothing to quote.
    let snippet: String
    let theme: ReadingTheme
    /// What VoiceOver reads for the jump button.
    let accessibilityLabel: String
    let onJump: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onJump) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kicker.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(1.2)
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    if !snippet.isEmpty {
                        Text("\u{201C}\(snippet)\u{201D}")
                            .font(.system(size: 13, design: .serif))
                            .foregroundStyle(theme.inkColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("contents.bookmark")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.faint)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .padding(.top, 2)
            .help("Remove bookmark")
            .accessibilityLabel("Remove bookmark")
            .accessibilityIdentifier("contents.removeBookmark")
        }
    }
}

/// The faint ribbon beside a chapter or outline row that holds a bookmark.
struct ContentsBookmarkMarker: View {
    let theme: ReadingTheme

    var body: some View {
        Image(systemName: "bookmark")
            .font(.system(size: 11))
            .foregroundStyle(theme.faint)
            .accessibilityLabel("Has a bookmark")
    }
}

/// The toolbar ribbon: hollow on a page without a bookmark, filled on one
/// with; a tap (⌘D) adds or removes. The same control in the text and PDF
/// readers, differing only in the identifier their tests know it by.
struct BookmarkRibbonButton: View {
    let isBookmarked: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                isBookmarked ? "Bookmarked" : "Bookmark",
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
            )
        }
        .keyboardShortcut("d", modifiers: .command)
        .help(isBookmarked ? "Remove this bookmark (⌘D)" : "Bookmark this page (⌘D)")
        .accessibilityLabel(isBookmarked ? "Remove bookmark" : "Bookmark this page")
        .accessibilityAddTraits(isBookmarked ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Sizes a Contents popover to its rows — measured, not guessed, so a
/// two-row book gets a two-row popover and a long one scrolls at the cap
/// (the same measure-then-size pattern as `AppearancePopover`). iPhone's
/// sheet detents, where a host sets them, override this.
struct ContentsPopoverFrame: ViewModifier {
    let theme: ReadingTheme
    @State private var measuredHeight: CGFloat = 0

    static let width: CGFloat = 300
    static let maxHeight: CGFloat = 420

    func body(content: Content) -> some View {
        ScrollView {
            content
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    measuredHeight = $0
                }
        }
        .frame(width: Self.width)
        .frame(height: min(Self.maxHeight, max(76, measuredHeight)))
        .background(theme.elevated)
        .presentationBackground(theme.elevated)
    }
}

extension View {
    func contentsPopoverFrame(theme: ReadingTheme) -> some View {
        modifier(ContentsPopoverFrame(theme: theme))
    }
}
