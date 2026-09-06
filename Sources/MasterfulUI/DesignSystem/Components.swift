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
    public static let accent = Color(red: 0.16, green: 0.72, blue: 0.55)
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
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
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
                Text(title).font(.system(size: 12))
                if let help {
                    Text(help)
                        .font(.system(size: 11))
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
            .font(.system(size: isEmphasised ? 15 : 12, weight: .medium, design: .rounded))
            .padding(.horizontal, isEmphasised ? Token.Space.md : Token.Space.sm)
            .padding(.vertical, isEmphasised ? Token.Space.sm : Token.Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                    .fill(AppSurface.card)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
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
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
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
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
