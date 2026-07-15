import SwiftUI
import ReadrKit

#if canImport(UIKit)
import UIKit
#endif

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
    @Binding var fontRaw: String
    @Binding var lineSpacingRaw: String
    @Binding var isJustified: Bool
    var isPDF: Bool = false
    @Binding var pdfShowsOriginal: Bool
    @Environment(\.dismiss) private var dismiss
    /// Content height reported by the layout, driving the sheet's detent so
    /// the sheet always fits the controls exactly — no hand-tuned heights to
    /// drift when a section is added or Dynamic Type grows the text.
    @State private var measuredHeight: CGFloat = 0

    private var theme: ReadingTheme { ReadingTheme(rawValue: themeRaw) ?? .paper }

    /// iPhone: the toolbar popover adapts to a bottom sheet — fill the width.
    /// iPad: it stays a real popover bubble — keep a fixed tidy width.
    /// Decided by idiom, NOT horizontal size class: UIKit hands popover
    /// content a compact size class even on iPad, so the class can't tell a
    /// real popover from a sheet adaptation.
    private var isSheetPresentation: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Appearance")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(theme.inkColor)

            section("Text & theme") {
                HStack(spacing: 14) {
                    fontStepper
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(ReadingTheme.allCases) { option in
                            themeDot(option)
                        }
                    }
                }
            }

            section("Font") { fontRow }

            section("Spacing") {
                VStack(alignment: .leading, spacing: 10) {
                    spacingPicker
                    justifyToggle
                }
            }

            section("Layout") { layoutPicker }

            if isPDF {
                section("PDF") {
                    Picker("PDF display", selection: $pdfShowsOriginal) {
                        Text("Original pages").tag(true)
                        Text("Reading view").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Show the PDF's original pages, or its extracted text with highlights")
                }
            }
        }
        .padding(20)
        // Sheet (iPhone): fill the width so the controls read as a laid-out
        // sheet rather than a small island stranded in a large surface.
        // Popover (iPad): pin the bubble to a fixed width — `maxWidth` alone
        // would let the popover hug the content's ideal width and collapse
        // the Spacer-based rows.
        .frame(width: isSheetPresentation ? nil : 320, alignment: .leading)
        .frame(maxWidth: isSheetPresentation ? .infinity : nil, alignment: .leading)
        .background(theme.elevated)
        #if os(iOS)
        // Size the adapted sheet to the measured content height, so it fits
        // exactly at any Dynamic Type size and never strands the controls in
        // a half-empty screen. `.medium` is the pre-measurement fallback.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
            measuredHeight = $0
        }
        .presentationDetents(
            measuredHeight > 0 ? [.height(measuredHeight)] : [.medium]
        )
        .presentationDragIndicator(.visible)
        #endif
        .presentationBackground(theme.elevated)
    }

    /// A captioned group: a faint section label above its control row.
    @ViewBuilder
    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .kerning(1.5)
                .foregroundStyle(theme.faint)
            content()
        }
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

    // MARK: - Font & spacing (the Apple-Books text controls)

    /// Typeface menu: the current face's name in its own face, with a menu of
    /// every option (system menus render in the system font, so the row label
    /// is where the face previews).
    private var fontRow: some View {
        Menu {
            Picker("Font", selection: $fontRaw) {
                ForEach(ReaderFont.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack {
                Text(currentFont.displayName)
                    .font(previewFont(for: currentFont))
                    .foregroundStyle(theme.inkColor)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        .help("Reading typeface")
        .accessibilityLabel("Font")
        .accessibilityIdentifier("appearance.font")
    }

    private var currentFont: ReaderFont {
        ReaderFont(rawValue: fontRaw) ?? .newYork
    }

    /// A 15pt preview of the face, matching `ReaderStyle.contentFont`'s
    /// resolution (named family, or the system serif/sans designs).
    private func previewFont(for font: ReaderFont) -> Font {
        switch font {
        case .newYork: return .system(size: 15, design: .serif)
        case .sanFrancisco: return .system(size: 15)
        case .charter: return .custom("Charter", size: 15)
        case .georgia: return .custom("Georgia", size: 15)
        case .palatino: return .custom("Palatino", size: 15)
        }
    }

    /// Line-spacing presets (Compact / Normal / Relaxed), same segment
    /// treatment as the layout picker.
    private var spacingPicker: some View {
        HStack(spacing: 2) {
            ForEach(ReaderLineSpacing.allCases) { option in
                spacingSegment(option)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        .help("Line spacing")
    }

    private func spacingSegment(_ option: ReaderLineSpacing) -> some View {
        let selected = lineSpacingRaw == option.rawValue
        return Button { lineSpacingRaw = option.rawValue } label: {
            segmentLabel(option.displayName, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.displayName) line spacing")
        .accessibilityIdentifier("appearance.spacing.\(option.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Shared segment chip. The selected state must read at a glance — a
    /// paper-on-elevated fill alone was a few percent off the control
    /// background (invisible on sepia), so the active chip adds a hairline
    /// ring, a semibold label, and a whisper of lift.
    private func segmentLabel(_ label: String, selected: Bool) -> some View {
        Text(label)
            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? theme.inkColor : theme.muted)
            .lineLimit(1)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? theme.paper : .clear)
                    .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? theme.line : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    private var justifyToggle: some View {
        Toggle(isOn: $isJustified) {
            Text("Justify text")
                .font(.system(size: 13))
                .foregroundStyle(theme.inkColor)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        // R6/D1: a layout toggle is generic chrome, not an AI moment — the
        // track uses neutral ink, keeping Iris reserved for AI.
        .tint(theme.inkColor)
        .help("Book-style full justification with hyphenation")
        .accessibilityIdentifier("appearance.justify")
    }

    // MARK: - Layout segments

    private var layoutPicker: some View {
        HStack(spacing: 2) {
            layoutSegment("Scroll", .scroll)
            layoutSegment("Single page", .singlePage)
            // A facing-page spread on a handheld screen makes no sense (and
            // Apple Books offers none) — iOS keeps single page + scroll.
            #if os(macOS)
            layoutSegment("Two pages", .doublePage)
            #endif
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line, lineWidth: 1))
        .help("Reading layout")
    }

    private func layoutSegment(_ label: String, _ value: PageLayout) -> some View {
        let selected = layoutRaw == value.rawValue
        // Layout is a one-shot choice; dismissing lets the reader see the
        // result immediately (and keeps popover-covered toolbar buttons
        // tappable for the UI screenshot walk). Theme/font stay open so they
        // preview live.
        return Button { layoutRaw = value.rawValue; dismiss() } label: {
            segmentLabel(label, selected: selected)
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
