import AppKit
import SwiftUI

/// How full a usage window is, and the colour that says so.
///
/// Bands: under 50% green, 50–75% amber, 75–90% orange, 90% and up red.
/// Each colour has a darker light-mode variant (readable as text on white)
/// and a brighter dark-mode variant (readable on the dark panel).
enum UsageLevel {
    case low, medium, high, critical

    init(_ pct: Double) {
        switch pct {
        case ..<50: self = .low
        case ..<75: self = .medium
        case ..<90: self = .high
        default: self = .critical
        }
    }

    var color: Color {
        switch self {
        case .low:
            return Theme.dynamic(light: (0.11, 0.56, 0.27), dark: (0.30, 0.82, 0.47))
        case .medium:
            return Theme.dynamic(light: (0.74, 0.50, 0.00), dark: (1.00, 0.78, 0.22))
        case .high:
            return Theme.dynamic(light: (0.87, 0.37, 0.05), dark: (1.00, 0.58, 0.26))
        case .critical:
            return Theme.dynamic(light: (0.82, 0.14, 0.14), dark: (1.00, 0.42, 0.40))
        }
    }
}

enum Theme {
    /// A colour that follows the system light/dark appearance.
    static func dynamic(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Card fill: white in light mode, raised dark grey in dark mode, so the
    /// cards stand out from the panel's translucent background.
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.10)
    static let track = Color.primary.opacity(0.10)
    static let activeAccent = dynamic(light: (0.16, 0.42, 0.90), dark: (0.40, 0.62, 1.00))
    static let success = UsageLevel.low.color
}

struct CardStyle: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardFill)
                    .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        highlighted ? Theme.activeAccent : Theme.cardBorder,
                        lineWidth: highlighted ? 1.5 : 1
                    )
            )
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View {
        modifier(CardStyle(highlighted: highlighted))
    }
}
