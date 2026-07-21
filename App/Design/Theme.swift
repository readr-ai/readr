import SwiftUI
import ReadrKit
// SFNT feature constants (kLowerCaseType/kLowerCaseSmallCapsSelector) for the
// small-caps font variant.
import CoreText

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#endif

// MARK: - "Marginalia" design language
//
// From the Claude Design handoff (scratch: ebook-reader-with-ai-margin-notes):
// warm paper surfaces, serif for the page and headings, sans for chrome, a
// muted literary highlight palette (amber/sage/slate/clay), and ONE reserved
// mark for AI moments — ✦ in the iris accent. All UI colors/typography come
// from here; never hard-code them in views.

private extension Color {
    /// sRGB color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

private extension PlatformColor {
    /// sRGB platform color from a 0xRRGGBB literal.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum AppTheme {
    /// The reserved AI accent ("Iris"). Used ONLY for AI moments — the ✦
    /// glyph, Ask affordances, citation chips, streaming carets — never for
    /// generic chrome. Light-surface value; `ReadingTheme.iris` adapts per
    /// reading theme.
    static let iris = Color(hex: 0x5B57C7)

    /// App-wide interactive accent = iris (matches Assets AccentColor).
    static let accent = iris

    /// The AI glyph. One mark, everywhere AI acts.
    static let aiGlyph = "✦"
    /// The note marker used in annotation lists.
    static let noteGlyph = "❋"

    /// Cover art corner radius and shadow, shared by shelf and detail views.
    static let coverRadius: CGFloat = 6
    static func coverShadow(_ content: some View) -> some View {
        content.shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 6)
    }

    /// Flat tinted placeholder covers (Marginalia style): a deep, muted field
    /// with light ink for the serif title + small-caps author.
    /// (title-hash-picked; index 0 matches the design's Moby-Dick #2F4356).
    static let coverTints: [(field: Color, ink: Color)] = [
        (Color(hex: 0x2F4356), Color(hex: 0xEDE6D6)),
        (Color(hex: 0x584434), Color(hex: 0xF0E7D4)),
        (Color(hex: 0x3E4A33), Color(hex: 0xEAE8D5)),
        (Color(hex: 0x5A3B3B), Color(hex: 0xF1E4DA)),
        (Color(hex: 0x3B3B55), Color(hex: 0xE8E6F0)),
        (Color(hex: 0x6B5A2E), Color(hex: 0xF3EBD3)),
    ]
    static func coverTint(for title: String) -> (field: Color, ink: Color) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in title.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return coverTints[Int(hash % UInt64(coverTints.count))]
    }

    /// Legacy gradient API — kept so existing call sites compile; prefer
    /// `coverTint(for:)` flat fields for new work.
    static func coverGradient(for title: String) -> [Color] {
        let tint = coverTint(for: title)
        return [tint.field, tint.field]
    }
}

/// Reading themes: Paper (light), Sepia, Dark. Raw values keep their v1 names
/// (`paper`/`sepia`/`night`) so persisted @AppStorage selections survive.
enum ReadingTheme: String, CaseIterable, Codable, Identifiable {
    case paper, sepia, night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .night: return "Dark"
        }
    }

    // MARK: Surfaces

    /// Window/chrome background (slightly deeper than the page).
    var background: Color {
        switch self {
        case .paper: return Color(hex: 0xEFEBE1)
        case .sepia: return Color(hex: 0xE4D8BD)
        case .night: return Color(hex: 0x131109)
        }
    }

    /// The page itself — reading surfaces, cards.
    var paper: Color {
        switch self {
        case .paper: return Color(hex: 0xFAF7F0)
        case .sepia: return Color(hex: 0xF3E9D0)
        case .night: return Color(hex: 0x1E1B14)
        }
    }

    /// Elevated surfaces: popovers, menus, dialogs.
    var elevated: Color {
        switch self {
        case .paper: return .white
        case .sepia: return Color(hex: 0xFAF2DD)
        case .night: return Color(hex: 0x282419)
        }
    }

    // MARK: Text

    var ink: PlatformColor {
        switch self {
        case .paper: return PlatformColor(hex: 0x26221C)
        case .sepia: return PlatformColor(hex: 0x3B3020)
        case .night: return PlatformColor(hex: 0xE7E0D1)
        }
    }
    var inkColor: Color { Color(ink) }

    /// Secondary text.
    var muted: Color {
        switch self {
        case .paper: return Color(hex: 0x7E7669)
        case .sepia: return Color(hex: 0x83745B)
        case .night: return Color(hex: 0x9C9483)
        }
    }

    /// Tertiary text: captions, section labels, disabled.
    var faint: Color {
        switch self {
        case .paper: return Color(hex: 0xA89F8F)
        case .sepia: return Color(hex: 0xA29170)
        case .night: return Color(hex: 0x6F6857)
        }
    }

    /// Hairline borders and dividers.
    var line: Color {
        switch self {
        case .paper: return Color(hex: 0x26221C, opacity: 0.14)
        case .sepia: return Color(hex: 0x3B3020, opacity: 0.17)
        case .night: return Color(hex: 0xE7E0D1, opacity: 0.15)
        }
    }

    /// The AI accent, adapted for the surface (brighter on dark paper).
    var iris: Color {
        self == .night ? Color(hex: 0x938EE9) : Color(hex: 0x5B57C7)
    }

    /// Platform color for tappable links in chapter text — the accent (iris)
    /// adapted per surface, as a `PlatformColor` because it's applied through
    /// `NSAttributedString` attributes, not SwiftUI styles.
    var linkInk: PlatformColor {
        self == .night ? PlatformColor(hex: 0x938EE9) : PlatformColor(hex: 0x5B57C7)
    }

    /// Secondary text as a `PlatformColor` (same values as `muted`) — used
    /// for blockquote runs in the attributed chapter text.
    var mutedInk: PlatformColor {
        switch self {
        case .paper: return PlatformColor(hex: 0x7E7669)
        case .sepia: return PlatformColor(hex: 0x83745B)
        case .night: return PlatformColor(hex: 0x9C9483)
        }
    }

    // MARK: Highlight markers ("muted literary" palette)

    /// Legacy single-color marker; prefer `marker(_:)`.
    var highlight: PlatformColor { marker(.yellow) }

    /// Rendered background for a highlight marker in this theme. Light/sepia
    /// use opaque muted fields (the design's look); dark uses alpha washes so
    /// text stays luminous.
    func marker(_ color: ReadrKit.HighlightColor) -> PlatformColor {
        switch self {
        case .paper:
            switch color {
            case .yellow: return PlatformColor(hex: 0xEAD8A2) // amber
            case .green: return PlatformColor(hex: 0xCBD6B2)  // sage
            case .blue: return PlatformColor(hex: 0xC2D3E0)   // slate
            case .pink: return PlatformColor(hex: 0xE9C8B8)   // clay
            case .purple: return PlatformColor(hex: 0xD8CCE4) // lavender
            }
        case .sepia:
            switch color {
            case .yellow: return PlatformColor(hex: 0xE4CE8F)
            case .green: return PlatformColor(hex: 0xC4CFA3)
            case .blue: return PlatformColor(hex: 0xBCCAD2)
            case .pink: return PlatformColor(hex: 0xE3BFA9)
            case .purple: return PlatformColor(hex: 0xCFC2DC)
            }
        case .night:
            switch color {
            case .yellow: return PlatformColor(hex: 0xE2BC68, alpha: 0.32)
            case .green: return PlatformColor(hex: 0xA3C078, alpha: 0.30)
            case .blue: return PlatformColor(hex: 0x7AA8CC, alpha: 0.30)
            case .pink: return PlatformColor(hex: 0xE29876, alpha: 0.30)
            case .purple: return PlatformColor(hex: 0xB296DC, alpha: 0.30)
            }
        }
    }

    /// Solid swatch for UI dots (popover, chips, notes panel) — the light
    /// theme's opaque values read as the palette everywhere.
    static func markerBase(_ color: ReadrKit.HighlightColor) -> PlatformColor {
        switch color {
        case .yellow: return PlatformColor(hex: 0xEAD8A2)
        case .green: return PlatformColor(hex: 0xCBD6B2)
        case .blue: return PlatformColor(hex: 0xC2D3E0)
        case .pink: return PlatformColor(hex: 0xE9C8B8)
        case .purple: return PlatformColor(hex: 0xD8CCE4)
        }
    }

    /// SwiftUI swatch for a marker color.
    static func markerSwatch(_ color: ReadrKit.HighlightColor) -> Color {
        Color(markerBase(color))
    }

    /// The design's annotation menu shows four dots; purple stays renderable
    /// for legacy highlights but isn't offered for new ones.
    static let pickerColors: [ReadrKit.HighlightColor] = [.yellow, .green, .blue, .pink]
}

/// The reader's body typefaces, Apple-Books-style: a short curated list of
/// faces that ship on every iOS/macOS device (no bundling). Raw values are
/// persisted in @AppStorage — don't rename cases.
enum ReaderFont: String, CaseIterable, Codable, Identifiable {
    case newYork, charter, georgia, palatino, sanFrancisco

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newYork: return "New York"
        case .charter: return "Charter"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .sanFrancisco: return "San Francisco"
        }
    }

    /// The installed family name to instantiate, or nil for the system font
    /// paths (New York via the serif design descriptor, SF directly).
    fileprivate var familyName: String? {
        switch self {
        case .newYork, .sanFrancisco: return nil
        case .charter: return "Charter"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        }
    }
}

/// Line-height presets (the extra leading above the glyph box, as a fraction
/// of the font size). The system serif's natural line box is ~1.2 em, so
/// these land at ~1.3×/1.45×/1.7× overall — "normal" matches the comfortable
/// book default (Apple Books sits around 1.4×); the old hard-coded 0.52
/// (1.7×) is what read as "too far apart" and survives as `.relaxed` for
/// readers who liked it. Raw values are persisted — don't rename cases.
enum ReaderLineSpacing: String, CaseIterable, Codable, Identifiable {
    case compact, normal, relaxed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .normal: return "Normal"
        case .relaxed: return "Relaxed"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .compact: return 0.10
        case .normal: return 0.24
        case .relaxed: return 0.52
        }
    }
}

/// Everything the text renderer needs to draw a page of a book.
struct ReaderStyle: Equatable {
    var theme: ReadingTheme = .paper
    var fontSize: CGFloat = 18
    var font: ReaderFont = .newYork
    var spacing: ReaderLineSpacing = .normal
    /// Book-style full justification (with hyphenation) — the Apple Books
    /// default. Off ⇒ natural (ragged-right) alignment.
    var isJustified = true
    /// Cap for inline image height (paged mode sets it to the page's text
    /// height so a figure can never exceed a page and break pagination).
    /// nil ⇒ uncapped (scroll mode, where the column just grows).
    var maxImageHeight: CGFloat? = nil

    static let fontSizeRange: ClosedRange<CGFloat> = 13...30

    var contentFont: PlatformFont {
        let system = PlatformFont.systemFont(ofSize: fontSize)
        if let family = font.familyName,
           let named = Self.resolveFont(family: family, size: fontSize) {
            return named
        }
        if font == .newYork {
            // New York via the system serif design; falls back to the system
            // font if the descriptor can't be realized.
            if let descriptor = system.fontDescriptor.withDesign(.serif) {
                #if canImport(UIKit)
                return PlatformFont(descriptor: descriptor, size: fontSize)
                #else
                return PlatformFont(descriptor: descriptor, size: fontSize) ?? system
                #endif
            }
        }
        return system
    }

    /// Family-name font resolution. UIFont(name:) accepts family names;
    /// NSFont(name:) wants a face name, so macOS goes through a family
    /// descriptor — verifying the result (an unknown family silently
    /// resolves to Helvetica, which must fall through to the system font
    /// instead of masquerading as the picked face).
    private static func resolveFont(family: String, size: CGFloat) -> PlatformFont? {
        #if canImport(UIKit)
        if let direct = UIFont(name: family, size: size) { return direct }
        let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        let resolved = UIFont(descriptor: descriptor, size: size)
        return resolved.familyName == family ? resolved : nil
        #else
        if let direct = NSFont(name: family, size: size) { return direct }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        guard let resolved = NSFont(descriptor: descriptor, size: size),
              resolved.familyName == family else { return nil }
        return resolved
        #endif
    }

    // MARK: Derived formatting fonts (no stored state — Equatable unaffected)

    /// Heading font for `formatSpans`: the content face scaled per level and
    /// bolded. Bold (not semibold) at every level on purpose — semibold
    /// weights don't exist across the curated device families (Charter,
    /// Georgia, Palatino), and a per-family weight lookup that silently lands
    /// on a different face is worse than a uniform bold.
    func headingFont(level: Int) -> PlatformFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.6
        case 2: scale = 1.35
        case 3: scale = 1.2
        default: scale = 1.05
        }
        var scaled = self
        scaled.fontSize = (fontSize * scale).rounded()
        return Self.fontMergingTraits(into: scaled.contentFont, bold: true, italic: false)
    }

    var boldFont: PlatformFont {
        Self.fontMergingTraits(into: contentFont, bold: true, italic: false)
    }

    var italicFont: PlatformFont {
        Self.fontMergingTraits(into: contentFont, bold: false, italic: true)
    }

    var boldItalicFont: PlatformFont {
        Self.fontMergingTraits(into: contentFont, bold: true, italic: true)
    }

    /// Merge symbolic traits into an EXISTING font (which may already carry
    /// traits — bold inside italic, bold inside a heading keeps the heading
    /// size), via font descriptors like `resolveFont`. Graceful fallback: a
    /// face without the requested variant returns the base font unchanged
    /// rather than a substituted family.
    static func fontMergingTraits(
        into font: PlatformFont, bold: Bool, italic: Bool
    ) -> PlatformFont {
        #if canImport(UIKit)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    /// Scale an EXISTING font to a new point size, keeping its family and
    /// traits (super/subscript runs shrink whatever composed font the range
    /// already carries — bold inside a heading stays bold at heading scale).
    static func fontResized(_ font: PlatformFont, to size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        return UIFont(descriptor: font.fontDescriptor, size: size)
        #else
        return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        #endif
    }

    /// Small-caps variant of an EXISTING font via the lowercase→small-caps
    /// AAT feature (the descriptor route `fontMergingTraits` uses for
    /// traits). Faces without the feature render unchanged — the setting is
    /// inert — so there is no fallback branch to get wrong.
    static func fontAddingSmallCaps(to font: PlatformFont) -> PlatformFont {
        #if canImport(UIKit)
        let feature: [UIFontDescriptor.FeatureKey: Int] = [
            .type: kLowerCaseType,
            .selector: kLowerCaseSmallCapsSelector,
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        let feature: [NSFontDescriptor.FeatureKey: Int] = [
            .typeIdentifier: kLowerCaseType,
            .selectorIdentifier: kLowerCaseSmallCapsSelector,
        ]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [feature]])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }

    /// Extra leading above the glyph box, from the spacing preset.
    var lineSpacing: CGFloat { fontSize * spacing.multiplier }

    /// Space between paragraphs (chapter text separates them with a single
    /// newline). ~0.35 em: a visible break without the airy blank-line look —
    /// the book convention Apple Books renders for most EPUBs.
    var paragraphSpacing: CGFloat { fontSize * 0.35 }
}

// MARK: - Touch targets

extension View {
    /// R5: expand a control's tappable area to at least 44×44pt on touch
    /// platforms (Apple HIG minimum) without changing its visual size. macOS
    /// is pointer-driven and keeps the compact hit target. Applied via
    /// `contentShape` so the whole 44pt frame is hit-testable, not just the
    /// (smaller) rendered glyph.
    @ViewBuilder
    func annotationTouchTarget() -> some View {
        #if os(iOS)
        self
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        #else
        self
        #endif
    }
}
