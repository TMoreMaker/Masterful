import AppKit
import MasterfulKit
import SwiftUI

/// Surfaces for the app's regular windows.
///
/// Distinct from `Palette`, which is the always-dark HUD chip. Onboarding and
/// settings are ordinary windows and follow the system appearance like any other
/// Mac app — but they are no longer dressed in the system's own colours.
///
/// **A documented deviation from the HIG.** The guidelines prefer system colours,
/// and `Palette` still uses them, because the island has to read as part of the
/// display. The windows are different: they are where Masterful is *opened*,
/// and in system grey and blue they could be any app's preferences. So they wear
/// the Masterful palette instead — warm paper, near-black ink, and plum — each
/// value resolved per appearance, as a system colour would be. Every pair below
/// was measured, and the numbers are in the comments rather than asserted.
///
/// What is lost is the user's chosen accent, inside these windows only. That is
/// the trade Apple's own apps make when they set an accent of their own (Notes,
/// Music), and it is why the colour is set once, as a `tint` at each window's
/// root, rather than sprinkled: one accent per window still holds.
public enum AppSurface {
    /// Warm paper in light, near-black ink in dark — the black of the island.
    public static let background = Color(light: 0xF7F4F1, dark: 0x0F0E12)
    /// Cards sitting on `background`.
    public static let card = Color(light: 0xFFFFFF, dark: 0x1A181E)
    /// The main window's sidebar: a step recessed from `background`, so the
    /// pages read as the surface and the navigation as the frame around them.
    public static let sidebar = Color(light: 0xEFEBE7, dark: 0x16141A)
    /// Card borders and dividers. Decorative only, never a control's sole edge.
    public static let separator = Color(light: 0xE3DED9, dark: 0x2A2730)

    /// Fills: controls, the selected radio, progress, chart bars. White text on
    /// it measures 6.0:1 in light and 4.55:1 in dark, so stock prominent buttons
    /// keep a readable label; as a shape it clears 3:1 on every surface here.
    public static let accent = Color(light: 0x9041A7, dark: 0xA653C0)

    /// Accent *text* and glyphs. The same plum in light (5.5:1 on paper); in dark
    /// the fill above is only 3.9:1 on a card, too low for small text, so text
    /// lifts to a pale plum at 9.7:1.
    public static let accentText = Color(light: 0x9041A7, dark: 0xE5AEE8)

    /// Bloom — the identity colour. A fill for things that are live (the
    /// practice waveform), never text: it is a light colour in both appearances.
    public static let bloom = Color(light: 0xE2A5E5, dark: 0xE2A5E5)

    /// A tinted wash behind a selected or highlighted row.
    public static let accentWash = Color(light: 0xF6DFF7, dark: 0x3B2340)
}

extension Color {
    /// A colour that resolves per appearance, the way a system colour does.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// The keyboard focus ring, in the window accent.
///
/// `tint` reaches every control's fill but not the focus ring, which AppKit draws
/// in the system accent regardless — so a plum window kept one blue outline on
/// whichever field had focus. This draws the same shape in `AppSurface.accent`:
/// 2pt, offset from the field the way the system's is, and only while the field
/// actually holds focus, so keyboard users lose nothing.
///
/// `focusEffectDisabled` only removes rings SwiftUI draws. A `.roundedBorder`
/// field is an `NSTextField`, whose ring survives it, so text fields use
/// `masterfulTextField()` below rather than this directly.
private struct AccentFocusRing: ViewModifier {
    let cornerRadius: CGFloat
    let outset: CGFloat
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous)
                    .strokeBorder(AppSurface.accent, lineWidth: 2)
                    .padding(-outset)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(Motion.honouringPreferences(.easeOut(duration: 0.15)), value: isFocused)
    }
}

extension View {
    /// See `AccentFocusRing`.
    public func accentFocusRing(cornerRadius: CGFloat, outset: CGFloat = 3) -> some View {
        modifier(AccentFocusRing(cornerRadius: cornerRadius, outset: outset))
    }

    /// A single-line field in the window palette: the system's rounded-border
    /// proportions, drawn by us so the focus ring can be plum. Apply to a
    /// `TextField` or `SecureField`.
    public func masterfulTextField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, Token.Space.xs)
            .padding(.vertical, Token.Space.xxs)
            // Paper, not the card colour: a field is a well cut into the card.
            .background(AppSurface.background, in: RoundedRectangle(cornerRadius: Token.Radius.sm - 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.sm - 2, style: .continuous)
                    .strokeBorder(AppSurface.separator, lineWidth: 1)
            )
            .accentFocusRing(cornerRadius: Token.Radius.sm - 2)
    }
}

/// A grouped container. The workhorse of both settings and onboarding.
public struct Card<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.md) {
            content
        }
        .padding(Token.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: Token.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.md, style: .continuous)
                .strokeBorder(AppSurface.separator, lineWidth: 0.5)
        )
    }
}

public struct SectionHeader: View {
    private let title: String
    private let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.xxs) {
            Text(title)
                .font(Typeface.sectionTitle)
            if let subtitle {
                Text(subtitle)
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label-and-control row with the control trailing.
public struct SettingRow<Control: View>: View {
    private let title: String
    private let help: String?
    private let control: Control

    public init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Space.lg) {
            VStack(alignment: .leading, spacing: Token.Space.hairline) {
                Text(title).font(Typeface.rowTitle)
                if let help {
                    Text(help)
                        .font(Typeface.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Token.Space.md)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders a shortcut the way a keyboard does.
public struct KeyCapView: View {
    private let shortcut: Shortcut
    private let isEmphasised: Bool

    public init(shortcut: Shortcut, isEmphasised: Bool = false) {
        self.shortcut = shortcut
        self.isEmphasised = isEmphasised
    }

    public var body: some View {
        Text(shortcut.displayString)
            .font(isEmphasised ? Typeface.keycapLarge : Typeface.keycap)
            .padding(.horizontal, isEmphasised ? Token.Space.md : Token.Space.sm)
            .padding(.vertical, isEmphasised ? Token.Space.sm : Token.Space.xxs)
            .background(
                // No shadow: the keycap is described by its border and its
                // fill. See `Palette` — the rule holds outside the HUD too.
                RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                    .fill(AppSurface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                    .strokeBorder(AppSurface.separator, lineWidth: 0.5)
            )
    }
}

/// Traffic-light status for a permission or capability.
public struct StatusDot: View {
    public enum State: Equatable, Sendable {
        case good, waiting, bad

        var color: Color {
            switch self {
            case .good: Palette.success
            case .waiting: Palette.warning
            case .bad: Palette.danger
            }
        }
    }

    private let state: State
    public init(_ state: State) { self.state = state }

    public var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            // Colour alone must never be the only signal.
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .good: "Granted"
        case .waiting: "Waiting"
        case .bad: "Not granted"
        }
    }
}

/// A permission or requirement, with an action when it is not satisfied.
public struct RequirementRow: View {
    private let title: String
    private let detail: String
    private let state: StatusDot.State
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        detail: String,
        state: StatusDot.State,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.state = state
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Token.Space.md) {
            StatusDot(state)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: Token.Space.hairline) {
                Text(title).font(Typeface.rowTitleEmphasised)
                Text(detail)
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Token.Space.sm)

            if state != .good, let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inline notice — a tinted symbol carrying the state, and text that does not.
///
/// The colour lives on the symbol deliberately. macOS's status colours are *fill*
/// colours: `systemOrange` measures 2.31:1 as text on a white card, well under the
/// 4.5:1 small text needs, and Apple intends them for filled shapes, dots and
/// glyphs rather than for prose. A tinted glyph reads the state at a glance and
/// leaves the words at full label contrast. It is the pattern the Globe-key
/// conflict notices already use; this makes it the easy one to reach for.
///
/// The symbol also does something colour never can: it is announced. These
/// sentences previously reached VoiceOver with no indication they were warnings
/// at all, because the only thing marking them as such was their colour.
public struct InlineNotice: View {

    public enum Level {
        /// Something is wrong, but the app still works.
        case warning
        /// Something is stopping the feature from working at all.
        case problem

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .problem: "exclamationmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .warning: Palette.warning
            case .problem: Palette.danger
            }
        }

        /// VoiceOver hears the level that sighted users read from the glyph.
        var spokenPrefix: String {
            switch self {
            case .warning: "Warning"
            case .problem: "Problem"
            }
        }
    }

    /// How loudly the notice is set. `.note` is a third-level aside inside
    /// another row; `.standard` stands on its own.
    public enum Prominence {
        case note, standard

        var font: Font {
            switch self {
            case .note: Typeface.caption
            case .standard: Typeface.secondary
            }
        }
    }

    private let level: Level
    private let message: String
    private let prominence: Prominence

    public init(_ level: Level, _ message: String, prominence: Prominence = .standard) {
        self.level = level
        self.message = message
        self.prominence = prominence
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Token.Space.xs) {
            Image(systemName: level.symbol)
                .foregroundStyle(level.tint)
            // No tint, and no `.secondary` either: a notice should be at least as
            // readable as the text it sits under. The glyph is what marks it out,
            // which is the whole point of the arrangement.
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Set on the stack so the glyph and the words share a size and a baseline.
        .font(prominence.font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level.spokenPrefix). \(message)")
    }
}

/// A single figure in the stats view.
public struct StatBlock: View {
    private let value: String
    private let label: String
    private let caption: String?

    public init(value: String, label: String, caption: String? = nil) {
        self.value = value
        self.label = label
        self.caption = caption
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.xxs) {
            Text(value)
                .font(Typeface.statValue)
                .contentTransition(.numericText())
            Text(label)
                .font(Typeface.secondaryEmphasised)
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(Typeface.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
