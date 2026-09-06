import InputControl
import MasterfulKit
import SwiftUI

/// Edits the set of bindings that start dictation.
///
/// A list rather than a single recorder because the bindings are additive, not
/// alternatives: the Globe key and a mouse side button are both live at the same
/// time, so docking the laptop does not mean re-recording anything.
public struct TriggerListEditor: View {
    @Binding var triggers: [Shortcut]
    private let onRecordingChanged: (Bool) -> Void

    @State private var isAdding = false
    @State private var duplicateWarning = false

    public init(
        triggers: Binding<[Shortcut]>,
        onRecordingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._triggers = triggers
        self.onRecordingChanged = onRecordingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.sm) {
            if triggers.isEmpty {
                Text("No shortcut set — dictation cannot be started.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }

            ForEach(triggers, id: \.self) { shortcut in
                row(for: shortcut)
            }

            if isAdding {
                HotkeyRecorderView(
                    shortcut: Binding(
                        get: { triggers.first ?? .globeKey },
                        set: { captured in add(captured) }
                    ),
                    onRecordingChanged: onRecordingChanged,
                    startsRecording: true
                )
                Button("Cancel") {
                    isAdding = false
                    onRecordingChanged(false)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else {
                Button {
                    duplicateWarning = false
                    isAdding = true
                } label: {
                    Label("Add another shortcut", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppSurface.accent)
            }

            if duplicateWarning {
                Text("That shortcut is already in the list.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            globeConflictNoticeIfNeeded
        }
        .animation(Motion.honouringPreferences(Motion.content), value: triggers)
        .animation(Motion.honouringPreferences(Motion.content), value: isAdding)
    }

    private func row(for shortcut: Shortcut) -> some View {
        HStack(spacing: Token.Space.sm) {
            KeyCapView(shortcut: shortcut)
            Text(describe(shortcut))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                triggers.removeAll { $0 == shortcut }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            // Removing the last binding would leave dictation unreachable with
            // no way back except the menu bar, so the last one is not removable.
            .disabled(triggers.count <= 1)
            .help(triggers.count <= 1 ? "Add another shortcut before removing this one" : "Remove")
        }
    }

    /// Names the device a binding belongs to, since the point of a list is that
    /// different bindings suit different setups.
    private func describe(_ shortcut: Shortcut) -> String {
        switch shortcut.trigger {
        case .mouseButton: "mouse — works in clamshell"
        case .modifier(.function): "built-in keyboard"
        case .modifier, .key: "any keyboard"
        }
    }

    @ViewBuilder
    private var globeConflictNoticeIfNeeded: some View {
        let usesGlobe = triggers.contains { if case .modifier(.function) = $0.trigger { true } else { false } }
        if usesGlobe, GlobeKeyBehaviour.conflictsWithDictation {
            HStack(alignment: .top, spacing: Token.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: Token.Space.xxs) {
                    Text("macOS is using the Globe key for “\(GlobeKeyBehaviour.current.displayName)”")
                        .font(.system(size: 11, weight: .medium))
                    Text("Set it to “Do Nothing”, or Masterful will never see the press.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard settings") { GlobeKeyBehaviour.openKeyboardSettings() }
                        .controlSize(.small)
                }
            }
            .padding(Token.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                    .fill(Palette.warning.opacity(0.12))
            )
        }
    }

    private func add(_ shortcut: Shortcut) {
        isAdding = false
        guard !triggers.contains(shortcut) else {
            duplicateWarning = true
            return
        }
        duplicateWarning = false
        triggers.append(shortcut)
    }
}
