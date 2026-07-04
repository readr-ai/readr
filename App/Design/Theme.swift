import SwiftUI

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

// MARK: - "Paper & Ink" design scheme
//
// Apple-Books-inspired: warm amber accent, serif reading type, cover art with
// soft shadows, and three reading themes. All UI colors/typography come from
// here — never hard-code them in views.

enum AppTheme {
    /// Warm amber, like a leather bookmark. The app-wide accent.
    static let accent = Color(red: 0.78, green: 0.55, blue: 0.18)

    /// Cover art corner radius and shadow, shared by shelf and detail views.
    static let coverRadius: CGFloat = 6
    static func coverShadow(_ content: some View) -> some View {
        content.shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 5)
    }

    /// Placeholder cover gradients, picked deterministically per title.
    static let coverGradients: [[Color]] = [
        [Color(red: 0.36, green: 0.26, blue: 0.55), Color(red: 0.16, green: 0.11, blue: 0.30)],
        [Color(red: 0.72, green: 0.32, blue: 0.24), Color(red: 0.38, green: 0.12, blue: 0.10)],
        [Color(red: 0.13, green: 0.42, blue: 0.42), Color(red: 0.05, green: 0.20, blue: 0.22)],
        [Color(red: 0.75, green: 0.53, blue: 0.16), Color(red: 0.42, green: 0.26, blue: 0.05)],
        [Color(red: 0.22, green: 0.34, blue: 0.60), Color(red: 0.09, green: 0.14, blue: 0.30)],
    ]
    static func coverGradient(for title: String) -> [Color] {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in title.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return coverGradients[Int(hash % UInt64(coverGradients.count))]
    }
}

/// Reading themes, Apple-Books style: Paper, Sepia, Night.
enum ReadingTheme: String, CaseIterable, Codable, Identifiable {
    case paper, sepia, night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .night: return "Night"
        }
    }

    var background: Color {
        switch self {
        case .paper: return Color(red: 1.0, green: 1.0, blue: 0.99)
        case .sepia: return Color(red: 0.97, green: 0.93, blue: 0.86)
        case .night: return Color(red: 0.09, green: 0.09, blue: 0.10)
        }
    }

    var ink: PlatformColor {
        switch self {
        case .paper: return PlatformColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1)
        case .sepia: return PlatformColor(red: 0.33, green: 0.25, blue: 0.16, alpha: 1)
        case .night: return PlatformColor(red: 0.88, green: 0.87, blue: 0.84, alpha: 1)
        }
    }

    var inkColor: Color { Color(ink) }

    var highlight: PlatformColor {
        switch self {
        case .paper, .sepia:
            return PlatformColor.systemYellow.withAlphaComponent(0.35)
        case .night:
            return PlatformColor.systemYellow.withAlphaComponent(0.25)
        }
    }
}

/// Everything the text renderer needs to draw a page of a book.
struct ReaderStyle: Equatable {
    var theme: ReadingTheme = .paper
    var fontSize: CGFloat = 18
    var usesSerif = true

    static let fontSizeRange: ClosedRange<CGFloat> = 13...30

    var contentFont: PlatformFont {
        if usesSerif {
            // New York via the system serif design; falls back to the system
            // font if the descriptor can't be realized.
            let system = PlatformFont.systemFont(ofSize: fontSize)
            if let descriptor = system.fontDescriptor.withDesign(.serif) {
                #if canImport(UIKit)
                return PlatformFont(descriptor: descriptor, size: fontSize)
                #else
                return PlatformFont(descriptor: descriptor, size: fontSize) ?? system
                #endif
            }
            return system
        }
        return PlatformFont.systemFont(ofSize: fontSize)
    }

    var lineSpacing: CGFloat { fontSize * 0.45 }
}
