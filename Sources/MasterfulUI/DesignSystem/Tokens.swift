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

        /// Drawn this much taller than the notch macOS reports.
        ///
        /// `safeAreaInsets.top` and the auxiliary menu-bar strips both say 33pt
        /// on a 14-inch Pro, but measured against the hardware that is a point
        /// or two short of the physical cutout. The two errors are not
        /// symmetric, which is what makes overshooting the right answer: too
        /// tall is invisible, because the island is wider than the notch and
        /// exactly the same black, so the extra height only moves an already
        /// straight bottom edge down. Too short leaves the notch protruding
        /// below the island — a small bump in the middle of the bar.
        ///
        /// It applies only while the island is showing something. At rest it
        /// goes back to the reported height, where erring *short* is the safe
        /// direction: a shape smaller than the notch is hidden by it, a shape
        /// larger than it is a black bar sitting under the camera all day.
        public static let notchOvershoot: CGFloat = 2

        /// Kept clear either side of the notch, on top of its measured width.
        ///
        /// The notch's bottom corners flare outward, and the reported strips
        /// are integers describing something that is not. Two points is cheap
        /// insurance against content that is technically beside the camera and
        /// visibly underneath it.
        public static let notchClearance: CGFloat = 2

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
        /// The menu bar panel, and the round buttons in it. The button is the
        /// size of the ones in macOS's own camera and Control Centre modules.
        public static let menuBarPanelWidth: CGFloat = 300
        public static let menuBarPanelButton: CGFloat = 28
    }

    public enum Opacity {
        public static let subtle: Double = 0.55
        public static let muted: Double = 0.72
        public static let full: Double = 1.0
    }
}

/// Semantic colours.
///
/// Every value here is a macOS system colour, and that is the whole point: the
/// system's palette is tuned per appearance, adjusted under Increase Contrast,
/// and updated when Apple retunes it. Hand-picked hexes are none of those things.
/// The two exceptions below are exceptions because a system colour cannot express
/// what they mean.
///
/// **These serve both the island and the app's ordinary windows.** That is new.
/// The old palette was hand-tuned against pure black and then also used in
/// settings and onboarding, where a light window made `success` a 2.2:1 smear.
/// A dynamic colour resolves against whatever it is drawn into, so one name is
/// now correct in both places instead of correct in one.
///
/// **The island's appearance is pinned to dark** (`HUDPanel`), which is what lets
/// these resolve correctly on it. Without that pin `labelColor` would resolve to
/// near-black in Light Mode and the island's text would vanish into it.
///
/// **Recording is not a colour.** Listening is the state you see every time you
/// use the app, often for seconds at a stretch, so it stays plain content —
/// `labelColor`, the same as any other text — and refuses to compete with the
/// work behind it. The states after it are brief and rare, and there colour is
/// doing real work: it says how the dictation ended before you have finished
/// reading the words.
///
/// **Nothing casts a shadow.** A shadow is a claim to be floating above the
/// screen, and the island is not floating — it is cut into the top of the
/// display. The black shape is its own separation. This is a rule, not a
/// default: if something appears to need a shadow to be legible, the shape or
/// the contrast is wrong.
public enum Palette {

    // MARK: - The island's own

    /// The island's fill. Pure black rather than a system colour, and not
    /// negotiable: on a notched display the island shares an edge with the
    /// bezel, and there is no dynamic colour whose job is "exactly the black of
    /// a MacBook's display housing". Anything lighter turns that join into a
    /// visible seam.
    public static let island = Color.black

    /// The hairline on a floating island. Only drawn when the shape is detached
    /// from the bezel — see `HUDView`.
    public static let stroke = Color(nsColor: .separatorColor)

    // MARK: - Content

    public static let textPrimary = Color(nsColor: .labelColor)
    public static let textSecondary = Color(nsColor: .secondaryLabelColor)

    /// Listening. Plain content, deliberately — see above.
    public static let live = textPrimary

    // MARK: - Outcomes

    /// Thinking — transcribing and refining.
    public static let thinking = Color(nsColor: .systemTeal)
    /// Delivered.
    public static let success = Color(nsColor: .systemGreen)
    /// Recoverable problems and refusals.
    public static let warning = Color(nsColor: .systemOrange)
    /// Failures.
    public static let danger = Color(nsColor: .systemRed)
}

/// The type scale.
///
/// Anchored to the macOS Human Interface Guidelines' text styles rather than to
/// point sizes we chose ourselves. `Font.callout` also resolves to 12pt — but it
/// is 12pt *because the system says so*, which means it arrives with the line
/// height, tracking and weight pairing the platform intends, it stays correct if
/// Apple retunes the scale, and it follows the user's text size setting.
/// `.system(size: 12)` is frozen at twelve points forever and pairs with nothing.
///
/// The HIG's macOS scale, and what this app uses of it:
///
/// | Role                   | HIG style   | Resolves to      |
/// |------------------------|-------------|------------------|
/// | `screenTitle`          | Large Title | 26 pt            |
/// | `featureSymbol`        | Title 2     | 17 pt            |
/// | `listSymbol`           | Title 3     | 15 pt            |
/// | `sectionTitle`         | Headline    | 13 pt bold       |
/// | `body`                 | Body        | 13 pt            |
/// | `rowTitle`             | Callout     | 12 pt            |
/// | `secondary`            | Subheadline | 11 pt            |
/// | `caption`              | Caption 1   | 10 pt            |
///
/// Title 1 is unused: nothing in the app is a document, and a 22pt heading in a
/// 560pt-wide settings window would be shouting.
///
/// Emphasis is a weight applied *to* a style, never a jump to the next size up.
/// A medium-weight callout is still a callout, and still scales with it.
public enum Typeface {

    // MARK: - Windows
    //
    // Onboarding, settings and history are ordinary Mac windows, so their type
    // behaves the way the system's does — including growing when the user turns
    // text size up in Accessibility settings.

    /// An onboarding step's heading. Large Title, weighted up: the HIG's regular
    /// Large Title is a document title, and this is a hero line.
    public static let screenTitle = Font.system(.largeTitle, weight: .semibold)

    /// A card's heading. Headline is the style that exists for precisely this,
    /// and it carries its own emphasis — no weight override needed.
    public static let sectionTitle = Font.headline

    /// Running prose: an onboarding subtitle, a transcript being read back.
    public static let body = Font.body

    /// A settings row's label, a list item, the name of a mode.
    public static let rowTitle = Font.callout
    public static let rowTitleEmphasised = Font.system(.callout, weight: .medium)

    /// Help text beneath a control, and every other supporting line. The most
    /// used role in the app by a wide margin.
    public static let secondary = Font.subheadline
    public static let secondaryEmphasised = Font.system(.subheadline, weight: .medium)

    /// Metadata and asides — the smallest type the app is permitted to set.
    public static let caption = Font.caption

    /// Spoken-command phrases. Monospaced because they are literal strings the
    /// user has to say exactly, and prose spacing makes them look approximate.
    public static let code = Font.system(.subheadline, design: .monospaced)

    /// A figure in the stats view. Rounded to match the readouts in the island,
    /// and monospaced-digit so a number ticking up does not shift its neighbours.
    public static let statValue = Font.system(.largeTitle, design: .rounded, weight: .semibold)
        .monospacedDigit()

    // MARK: Keys

    /// A shortcut rendered the way a keyboard prints it.
    public static let keycap = Font.system(.callout, design: .rounded, weight: .medium)
    /// The same, when the keycap is the thing the screen is about.
    public static let keycapLarge = Font.system(.title3, design: .rounded, weight: .medium)
    /// The captured binding inside the recorder field.
    public static let shortcutDisplay = Font.system(.body, design: .rounded, weight: .medium)

    // MARK: Symbols
    //
    // A symbol beside text takes that text's own font, so the two share a
    // baseline and grow together. Only symbols that stand alone need a size of
    // their own, and there are two.

    /// The icon leading an item in a bulleted list.
    public static let listSymbol = Font.title3
    /// The icon announcing a whole card.
    public static let featureSymbol = Font.title2

    // MARK: - The island
    //
    // The only fixed point sizes in the app, and a deliberate exception rather
    // than an oversight.
    //
    // The island's geometry is reserved, not measured: its compact height *is*
    // the notch's, and the expanded card's height is a constant the shape springs
    // to before the text inside it is laid out. Type that grew with the user's
    // text size would either clip against that reserved box or force the island
    // to resize after it had finished moving — and the whole effect rests on the
    // shape's edge landing exactly on the notch's. macOS's own menu bar does not
    // scale either, for the same reason: chrome pinned to a physical bezel cannot.
    //
    // The cost is stated rather than hidden. Someone who has turned system text
    // up gets larger type in every window of this app but not in the island —
    // which is showing them a glyph and a word count, and is the one surface
    // whose meaning survives being small.

    /// The expanded card's headline. 14pt sits between Body and Title 3 because
    /// the card is neither: it is denser than a window and louder than the bar.
    public static let islandTitle = Font.system(size: 14, weight: .semibold)
    /// The card's second line — what to do about what just happened.
    public static let islandDetail = Font.system(size: 12)
    /// The compact bar's trailing readout. A word count, never prose, so the
    /// digits are monospaced and the face is rounded to match the system's own
    /// status chrome.
    public static let islandReadout = Font.system(size: 12, weight: .semibold, design: .rounded)
        .monospacedDigit()
    /// The glyph leading the compact bar.
    public static let islandGlyph = Font.system(size: 12, weight: .semibold)
    /// The symbol inside the expanded card's icon tile.
    public static let islandSymbol = Font.system(size: 19, weight: .medium)
}
