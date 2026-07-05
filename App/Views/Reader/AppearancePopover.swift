import SwiftUI
import ReadrKit

/// The Aa popover (iOS keeps it; macOS shows the same controls inline in the
/// toolbar), Marginalia style: a serif A / A font stepper, three theme dots
/// (paper swatches, ink ring when selected), a hairline segmented layout
/// picker, and — for PDFs — the original-pages ↔ reading-view switch.
///
/// A popover, not a menu, so themes preview live. The layout segments keep
/// their exact labels ("Scroll" / "Single page" / "Two pages") and the theme
/// dots their display names — the UI screenshot test taps them by label.
struct AppearancePopover: View {
    @Binding var themeRaw: String
    @Binding var layoutRaw: String
    @Binding var fontSize: Double
    var isPDF: Bool = false
    @Binding var pdfShowsOriginal: Bool

    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                fontStepper
                Spacer()
                HStack(spacing: 8) {
                    ForEach(ReadingTheme.allCases) { option in
                        themeDot(option)
                    }
                }
            }

            layoutPicker

            if isPDF {
                Rectangle().fill(theme.line).frame(height: 1)
                Picker("PDF display", selection: $pdfShowsOriginal) {
                    Text("Original pages").tag(true)
                    Text("Reading view").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Show the PDF's original pages, or its extracted text with highlights")
            }
        }
        .padding(16)
        .frame(width: 288)
        .background(theme.elevated)
        .presentationBackground(theme.elevated)
    }

    // MARK: - Font stepper (serif A / A with a hairline divider)

    private var fontStepper: some View {
        HStack(spacing: 0) {
            Button { adjust(-1) } label: {
                Text("A")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(theme.inkColor)
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fontSize <= Double(ReaderStyle.fontSizeRange.lowerBound))
            .help("Smaller text (⌘−)")
            .accessibilityLabel("Smaller text")
            .accessibilityIdentifier("appearance.textSmaller")

            Rectangle().fill(theme.line).frame(width: 1, height: 30)

            Button { adjust(+1) } label: {
                Text("A")
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(theme.inkColor)
                    .frame(width: 40, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(fontSize >= Double(ReaderStyle.fontSizeRange.upperBound))
            .help("Larger text (⌘+)")
            .accessibilityLabel("Larger text")
            .accessibilityIdentifier("appearance.textLarger")
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
    }

    // MARK: - Theme dots (18pt paper swatches; selected = ink ring)

    private func themeDot(_ option: ReadingTheme) -> some View {
        let selected = option == theme
        return Button { themeRaw = option.rawValue } label: {
            ZStack {
                Circle()
                    .fill(option.paper)
                    .overlay(Circle().strokeBorder(theme.line, lineWidth: 1))
                    .frame(width: 18, height: 18)
                if selected {
                    Circle()
                        .strokeBorder(theme.inkColor, lineWidth: 1.5)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(option.displayName) theme")
        .accessibilityLabel(option.displayName)
        .accessibilityIdentifier("appearance.theme.\(option.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Layout segments

    private var layoutPicker: some View {
        HStack(spacing: 2) {
            layoutSegment("Scroll", .scroll)
            layoutSegment("Single page", .singlePage)
            layoutSegment("Two pages", .doublePage)
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        .help("Reading layout")
    }

    private func layoutSegment(_ label: String, _ value: PageLayout) -> some View {
        let selected = layoutRaw == value.rawValue
        return Button { layoutRaw = value.rawValue } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? theme.inkColor : theme.muted)
                .lineLimit(1)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? theme.paper : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("appearance.layout.\(value.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func adjust(_ delta: Double) {
        fontSize = min(
            max(fontSize + delta, Double(ReaderStyle.fontSizeRange.lowerBound)),
            Double(ReaderStyle.fontSizeRange.upperBound)
        )
    }
}
