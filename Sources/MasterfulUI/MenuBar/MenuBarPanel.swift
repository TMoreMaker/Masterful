import AppKit
import MasterfulKit
import SwiftUI

/// What the menu bar panel shows, and what its rows do.
///
/// Values and closures rather than the coordinator, for the same reason as
/// `UIServices`: this layer must not depend on the composition root. It is also
/// what lets `WindowPreview` draw the panel in any state without a microphone.
public struct MenuBarPanelModel {
    /// Something stopping dictation, and the one action that fixes it.
    public struct Remedy: Identifiable {
        public var title: String
        public var action: () -> Void
        public var id: String { title }

        public init(title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
    }

    /// An ordinary command at the foot of the panel.
    public struct Command: Identifiable {
        public var title: String
        public var key: KeyEquivalent?
        public var action: () -> Void
        public var id: String { title }

        public init(title: String, key: KeyEquivalent? = nil, action: @escaping () -> Void) {
            self.title = title
            self.key = key
            self.action = action
        }
    }

    public var status: String
    public var hint: String?
    public var remedies: [Remedy]

    public var workMode: Bool
    public var workModeNote: String?
    public var setWorkMode: (Bool) -> Void

    public var refinement: RefinementMode
    public var setRefinement: (RefinementMode) -> Void

    public var lastDictation: String?
    public var commands: [Command]

    public init(
        status: String,
        hint: String?,
        remedies: [Remedy],
        workMode: Bool,
        workModeNote: String?,
        setWorkMode: @escaping (Bool) -> Void,
        refinement: RefinementMode,
        setRefinement: @escaping (RefinementMode) -> Void,
        lastDictation: String?,
        commands: [Command]
    ) {
        self.status = status
        self.hint = hint
        self.remedies = remedies
        self.workMode = workMode
        self.workModeNote = workModeNote
        self.setWorkMode = setWorkMode
        self.refinement = refinement
        self.setRefinement = setRefinement
        self.lastDictation = lastDictation
        self.commands = commands
    }
}

/// The panel under the menu bar icon, built the way macOS builds its own camera
/// and Control Centre modules: a column of round buttons that light up.
///
/// It replaced a menu with a submenu in it, where finding out which clean-up
/// mode was on took two levels of hovering. The settings that change from one
/// dictation to the next now say their state at a glance and take one click.
///
/// **Plum, where the system would use green or blue.** The same documented
/// deviation as `AppSurface`: this is somewhere Masterful is opened, not part of
/// the display like the island. White on `accent` measures 6.0:1 in light and
/// 4.55:1 in dark. A lit button also fills its glyph, so state is never carried
/// by colour alone.
public struct MenuBarPanel: View {
    private let model: MenuBarPanelModel
    @Environment(\.dismiss) private var dismiss
    @State private var justCopied = false

    public init(model: MenuBarPanelModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.xs) {
            header

            ForEach(model.remedies) { remedy in
                PanelRow(symbol: "exclamationmark.triangle", title: remedy.title, tint: Palette.warning) {
                    run(remedy.action)
                }
            }

            PanelDivider()

            PanelRow(
                symbol: "briefcase",
                title: "Work Mode",
                subtitle: model.workModeNote,
                isOn: model.workMode
            ) {
                model.setWorkMode(!model.workMode)
            }
            .accessibilityAddTraits(.isToggle)

            cleanUp

            PanelDivider()

            copyLast

            PanelDivider()

            VStack(spacing: 0) {
                ForEach(model.commands) { command in
                    CommandRow(command: command) { run(command.action) }
                }
            }
        }
        .padding(Token.Space.xs)
        .frame(width: Token.Size.menuBarPanelWidth)
        .tint(AppSurface.accent)
        .background(PanelKeyRequest())
        // Escape. A hidden button because `onExitCommand` needs a focused view,
        // and with Full Keyboard Access off nothing in here ever holds focus.
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Token.Space.hairline) {
            Text(model.status)
                .font(Typeface.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = model.hint {
                Text(hint)
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Token.Space.sm)
        .padding(.top, Token.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var cleanUp: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clean-up")
                .font(Typeface.secondaryEmphasised)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Token.Space.sm)
                .padding(.vertical, Token.Space.xxs)
                .accessibilityAddTraits(.isHeader)

            ForEach(RefinementMode.allCases, id: \.self) { mode in
                // Work mode locks clean-up to Tidy, so that is what lights up:
                // the panel shows what the next dictation will actually get. The
                // stored choice is untouched and returns when Work mode goes off.
                let isOn = (model.workMode ? RefinementMode.rules : model.refinement) == mode
                PanelRow(symbol: mode.symbolName, title: mode.displayName, isOn: isOn) {
                    guard !model.workMode else { return }
                    model.setRefinement(mode)
                }
                // The lit row dodges `disabled`, which would wash out the one
                // row still answering the question. It just stops taking clicks.
                .disabled(model.workMode && !isOn)
                .allowsHitTesting(!model.workMode)
                .accessibilityHint(model.workMode ? "Locked by Work Mode" : "")
            }
        }
    }

    private var copyLast: some View {
        PanelRow(
            symbol: justCopied ? "checkmark" : "doc.on.doc",
            title: justCopied ? "Copied" : "Copy Last Dictation",
            subtitle: model.lastDictation ?? "Nothing dictated yet",
            subtitleLines: 1,
            key: "c"
        ) {
            guard let text = model.lastDictation else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            justCopied = true
            // Long enough to see the tick, short enough not to be waited for.
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                dismiss()
                justCopied = false
            }
        }
        .disabled(model.lastDictation == nil)
    }

    /// Closes first, so a window the action opens is not fighting the panel for
    /// key status.
    private func run(_ action: () -> Void) {
        dismiss()
        action()
    }
}

extension RefinementMode {
    /// Raw is the voice as heard; Tidy a filter rather than sparkles, because it
    /// is rules taking things out, not a model writing anything.
    fileprivate var symbolName: String {
        switch self {
        case .off: "waveform"
        case .rules: "line.3.horizontal.decrease"
        case .onDevice: "laptopcomputer"
        case .remote: "cloud"
        }
    }
}

/// A round button and its label. Lit means on; `tint` is for a row that is not a
/// state at all but a warning.
private struct PanelRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var subtitleLines = 2
    var isOn: Bool?
    var tint: Color?
    var key: KeyEquivalent?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Token.Space.sm) {
                icon
                VStack(alignment: .leading, spacing: 0) {
                    // Wraps: a remedy's title is the instruction, and cut short
                    // it no longer says what is wrong.
                    Text(title)
                        .font(Typeface.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typeface.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(subtitleLines)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if let key {
                    Text("⌘\(String(key.character).uppercased())")
                        .font(Typeface.secondary)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Token.Space.xs)
            .padding(.vertical, Token.Space.xxs)
            .background(rowHighlight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key.map { KeyboardShortcut($0) })
        .accentFocusRing(cornerRadius: Token.Radius.sm)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn == true ? .isSelected : [])
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(Typeface.body)
            .symbolVariant(isOn == true ? .fill : .none)
            .foregroundStyle(isOn == true || tint != nil ? Color.white : Color.primary)
            .frame(width: Token.Size.menuBarPanelButton, height: Token.Size.menuBarPanelButton)
            .background { circle }
            .animation(Motion.honouringPreferences(.easeOut(duration: 0.15)), value: isOn)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var circle: some View {
        if let tint {
            Circle().fill(tint)
        } else if isOn == true {
            Circle().fill(AppSurface.accent)
        } else {
            Circle().fill(.quaternary)
        }
    }

    @ViewBuilder
    private var rowHighlight: some View {
        if isHovering, isEnabled {
            RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                .fill(.quinary)
        }
    }
}

/// A plain line of text: these are commands, with no state for a button to show.
private struct CommandRow: View {
    let command: MenuBarPanelModel.Command
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(command.title)
                    .font(Typeface.body)
                Spacer(minLength: 0)
                if let key = command.key {
                    Text("⌘\(String(key.character).uppercased())")
                        .font(Typeface.secondary)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Token.Space.sm)
            .padding(.vertical, Token.Space.xxs)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: Token.Radius.sm - 2, style: .continuous)
                        .fill(.quinary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(command.key.map { KeyboardShortcut($0) })
        .accentFocusRing(cornerRadius: Token.Radius.sm - 2)
        .onHover { isHovering = $0 }
    }
}

/// Makes the panel key when it opens, so Escape and the ⌘ shortcuts reach it.
///
/// The system opens it without doing so, and every keystroke carries on to the
/// app behind. `makeKey` rather than activating: the app the user was dictating
/// into stays frontmost, and has its text field back when the panel closes.
private struct PanelKeyRequest: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { KeyRequestView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class KeyRequestView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeKey() }
        }
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, Token.Space.sm)
    }
}
