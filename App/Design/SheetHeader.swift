import SwiftUI

/// The header every AI surface wears in its principal toolbar slot — ✦ in
/// iris, then the title in caps — so Ask and Article (and the next one)
/// cannot drift apart. Reading surfaces keep their plain title; Done sits
/// on the right of every sheet. (September 2026 UX review, F4.)
struct AISheetHeader: View {
    let title: String
    let theme: ReadingTheme

    var body: some View {
        HStack(spacing: 8) {
            Text(AppTheme.aiGlyph)
                .font(.subheadline)
                .foregroundStyle(theme.iris)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
    }
}
