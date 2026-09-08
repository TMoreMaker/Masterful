import MasterfulKit
import SwiftUI

/// Surfaces for the app's regular windows.
///
/// Distinct from `Palette`, which is the always-dark HUD chip. Onboarding and
/// settings are ordinary windows and should follow the system appearance like
/// any other Mac app — using the HUD's fixed dark palette there would make them
/// look like a web app pretending to be native.
public enum AppSurface {
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let card = Color(nsColor: .controlBackgroundColor)
    public static let separator = Color(nsColor: .separatorColor)

    /// The system accent — blue out of the box, and whatever the user chose in
    /// System Settings otherwise.
    ///
    /// This app has no brand worth defending against the user's own preference:
    /// it is a menu-bar utility that spends its life inside other people's
    /// windows. More concretely, SwiftUI already tints every stock control here
    /// — toggles, radio groups, the default button — with this exact colour, so
    /// anything hand-picked put two accents in one window and lost.
    ///
    /// The teal it replaces measured 2.14:1 on a light window background, which
    /// is what a colour chosen once in Dark Mode and then frozen looks like.
    public static let accent = Color.accentColor
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
