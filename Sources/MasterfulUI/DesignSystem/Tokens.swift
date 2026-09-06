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

    /// The island — the black shape at the top of the screen.
    ///
    /// Two sizes, and the whole HUD is the interpolation between them. Compact
    /// is the notch wearing a slightly wider coat; expanded is the card it
    /// unfolds into when there is something to read.
    public enum Island {
        /// Height of the compact bar where the display has no notch to match.
        public static let compactHeight: CGFloat = 30
        /// Minimum width of each flank beside the notch, so a single glyph on
        /// one side does not leave the bar looking lopsided.
        public static let flankMinWidth: CGFloat = 38
        /// Breathing room between a flank's content and the notch's edge.
        public static let flankPadding: CGFloat = 12

        public static let expandedWidth: CGFloat = 360
        /// Icon tile in the expanded card, sized like a Now Playing artwork.
        public static let tile: CGFloat = 42

        public static let compactCorner: CGFloat = 16
        public static let expandedCorner: CGFloat = 30
        /// Corner used when the island floats free of the bezel and therefore
        /// has to round its top edge too.
        public static let floatingCompactCorner: CGFloat = 15
    }

    public enum Size {
        /// Bars actually drawn in the HUD waveform. Four is enough to read as
        /// "your voice is arriving" and few enough to stay legible at 14pt tall.
        public static let waveformBars: Int = 4
        /// Loudness samples retained. Longer than the bar count on purpose: the
        /// bars sample this history at a stagger, which is what makes the shape
        /// travel rather than pump in unison.
        public static let levelHistory: Int = 16
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
///
/// **Recording is white; outcomes carry colour.** Listening is the state you see
/// every single time you use the app, often for several seconds, so it stays
/// neutral and refuses to compete with the work behind it — white in the notch
/// reads as the system, a saturated tint reads as an app announcing itself. The
/// other states are brief and rare, and there colour is doing real work: it says
/// how the dictation ended before you have finished reading the words.
///
/// **Nothing casts a shadow.** A shadow is a claim to be floating above the
/// screen, and the island is not floating — it is cut into the top of the
/// display. The black shape is its own separation. This is a rule, not a
/// default: if something appears to need a shadow to be legible, the shape or
/// the contrast is wrong.
public enum Palette {
    /// The island's fill. Pure black, and not negotiable: on a notched display
    /// the island shares an edge with the bezel, and anything lighter turns
    /// that join into a visible seam.
    public static let island = Color.black
    public static let surface = Color(red: 0.07, green: 0.07, blue: 0.08)
    public static let surfaceRaised = Color(red: 0.13, green: 0.13, blue: 0.145)
    public static let stroke = Color.white.opacity(0.10)

    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.62)

    /// Listening. White — see above.
    public static let live = Color.white
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

    /// Expanded card. Sized against the system's own alert typography rather
    /// than the HUD's, because here the user is genuinely reading.
    public static let islandTitle = Font.system(size: 14, weight: .semibold)
    public static let islandDetail = Font.system(size: 12, weight: .regular)
    /// The compact flank's trailing readout — a word count, never prose.
    public static let islandReadout = Font.system(size: 12, weight: .semibold, design: .rounded)
        .monospacedDigit()
}
