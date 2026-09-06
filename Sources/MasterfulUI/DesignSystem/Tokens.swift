import SwiftUI

/// The design system's primitives.
///
/// Every dimension in the app resolves to one of these. The point is not
/// tidiness — it is that when the HUD, onboarding and settings are built from
/// one vocabulary, they look related without anyone maintaining a spec.
public enum Token {

    /// A 4pt base scale. Small enough for the HUD's tight interior, regular
    /// enough that nothing ever lands on a half pixel.
    public enum Space {
        public static let hairline: CGFloat = 2
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 6
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    /// Continuous curvature throughout — squircles, matching the shapes macOS
    /// itself draws. A `.circular` corner next to a system control reads as
    /// subtly wrong even to people who cannot name why.
    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 18
        /// Sentinel for shapes that should stay fully rounded at any height.
        public static let pill: CGFloat = 999
    }

    public enum Size {
        /// The HUD's resting height. Everything else is derived from it.
        public static let hudHeight: CGFloat = 44
        public static let hudMinWidth: CGFloat = 132
        public static let hudMaxWidth: CGFloat = 460
        public static let waveformWidth: CGFloat = 56
        public static let waveformBars: Int = 24
        public static let glyph: CGFloat = 15
    }

    public enum Opacity {
        public static let subtle: Double = 0.55
        public static let muted: Double = 0.72
        public static let full: Double = 1.0
    }
}

/// Semantic colours.
///
/// The HUD is deliberately dark in both appearances rather than adopting the
/// system one. It floats over arbitrary application content — a white document,
/// a dark editor — and a surface that changes with the system theme would be
/// invisible against half of them. A consistent dark chip is always legible and
/// always reads as system chrome rather than as part of the app underneath.
public enum Palette {
    public static let surface = Color(red: 0.07, green: 0.07, blue: 0.08)
    public static let surfaceRaised = Color(red: 0.13, green: 0.13, blue: 0.145)
    public static let stroke = Color.white.opacity(0.10)

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.62)

    /// Listening. A saturated mint that survives being drawn small.
    public static let live = Color(red: 0.36, green: 0.92, blue: 0.71)
    /// Thinking — transcribing and refining.
    public static let thinking = Color(red: 0.55, green: 0.68, blue: 1.0)
    /// Delivered.
    public static let success = Color(red: 0.42, green: 0.88, blue: 0.60)
    /// Recoverable problems and refusals.
    public static let warning = Color(red: 1.0, green: 0.76, blue: 0.35)
    public static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)
}

public enum Typeface {
    /// Tabular figures so the word count does not jitter as it counts up.
    public static let hudLabel = Font.system(size: 13, weight: .medium, design: .rounded)
        .monospacedDigit()
    public static let hudTranscript = Font.system(size: 13, weight: .regular)
    public static let hudCaption = Font.system(size: 11, weight: .medium, design: .rounded)
}
