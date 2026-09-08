import AppKit
import InputControl
import MasterfulKit
import SwiftUI

/// Captures whatever the user presses next.
///
/// Uses a *local* event monitor rather than the app's `CGEventTap`, deliberately:
/// recording happens during onboarding, before Accessibility has been granted,
/// and a recorder that cannot run until the permission is in place would make
/// the setup flow circular.
///
/// The interesting problem is telling a bare modifier from the start of a chord.
/// Both begin with an identical `flagsChanged`. The resolution is to wait: a
/// modifier going down is only *pending*, and what happens next decides. A key
/// arriving makes it a chord; the modifier coming back up with no key in between
/// makes it a binding in its own right. That is what allows Globe, ⌥Space and a
/// mouse side-button to be recorded by the same control.
@MainActor
@Observable
public final class HotkeyRecorder {

    public private(set) var isRecording = false
    public private(set) var captured: Shortcut?
    /// Live feedback while a chord is being formed.
    public private(set) var pendingDescription: String?

    private var monitor: Any?
    private var pendingModifier: ModifierKey?
    private var sawKeyWhileModifierHeld = false

    public var onCapture: ((Shortcut) -> Void)?
    /// Called with `true` when recording starts and `false` when it ends, so the
    /// running hotkey engine can stand down for the duration.
    public var onRecordingChanged: ((Bool) -> Void)?

    public init() {}

    public func begin() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChanged?(true)
        captured = nil
        pendingModifier = nil
        pendingDescription = nil
        sawKeyWhileModifierHeld = false

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // Consume everything while recording, so a captured keystroke never
            // also lands in whatever field is behind the recorder.
            return self.handle(event) ? nil : event
        }
    }

    public func cancel() {
        finishMonitoring()
        isRecording = false
        onRecordingChanged?(false)
        pendingDescription = nil
    }

    private func finishMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
        sawKeyWhileModifierHeld = false
    }

    // MARK: - Event handling

    /// - Returns: `true` when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            // Escape abandons recording; Delete clears the binding entirely.
            if event.keyCode == 53 {
                cancel()
                return true
            }
            sawKeyWhileModifierHeld = true
            commit(Shortcut(trigger: .key(
                code: event.keyCode,
                modifiers: Self.modifiers(from: event)
            )))
            return true

        case .keyUp:
            return true

        case .flagsChanged:
            handleFlagsChanged(event)
            return true

        case .otherMouseDown:
            let button = event.buttonNumber
            // Left and right are never bindable: taking them would make the
            // machine unusable, and the user cannot click "Cancel" to escape.
            guard button >= 2 else { return true }
            commit(Shortcut(trigger: .mouseButton(button)))
            return true

        default:
            return false
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let key = ModifierKey(keyCode: event.keyCode) else { return }
        let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        let isDown = flags & key.deviceMask != 0

        if isDown {
            pendingModifier = key
            sawKeyWhileModifierHeld = false
            pendingDescription = "\(key.symbol) \(key.displayName) — release to bind, or press a key"
        } else if pendingModifier == key {
            defer { pendingModifier = nil }
            // A key was pressed while this modifier was held, so it was a chord
            // and has already been committed.
            guard !sawKeyWhileModifierHeld else { return }
            commit(Shortcut(trigger: .modifier(key)))
        }
    }

    private func commit(_ shortcut: Shortcut) {
        captured = shortcut
        pendingDescription = nil
        finishMonitoring()
        isRecording = false
        onCapture?(shortcut)
        // After onCapture, so the engine restores the *new* binding.
        onRecordingChanged?(false)
    }

    /// Only the modifiers that are meaningfully part of a chord. Caps Lock is
    /// excluded: it is a latch, not something a user holds.
    private static func modifiers(from event: NSEvent) -> ModifierSet {
        var set = ModifierSet()
        let flags = event.modifierFlags
        if flags.contains(.command) { set.insert(.command) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.function) { set.insert(.function) }
        return set
    }
}

/// The recorder control.
public struct HotkeyRecorderView: View {
    @Binding var shortcut: Shortcut
    private let onRecordingChanged: (Bool) -> Void
    /// Begins listening as soon as the control appears, for the "add another"
    /// flow where clicking the button *was* the intent to record.
    private let startsRecording: Bool
    @State private var recorder = HotkeyRecorder()

    public init(
        shortcut: Binding<Shortcut>,
        onRecordingChanged: @escaping (Bool) -> Void = { _ in },
        startsRecording: Bool = false
    ) {
        self._shortcut = shortcut
        self.onRecordingChanged = onRecordingChanged
        self.startsRecording = startsRecording
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.sm) {
            Button(action: toggle) {
                HStack(spacing: Token.Space.sm) {
                    if recorder.isRecording {
                        Image(systemName: "record.circle")
                            .foregroundStyle(Palette.danger)
                            .symbolEffect(.pulse, options: .repeating)
                        Text(recorder.pendingDescription ?? "Press any key, chord, or mouse button…")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.secondary)
                        Text(shortcut.displayString)
                            .font(Typeface.shortcutDisplay)
                    }
                    Spacer(minLength: Token.Space.sm)
                    Text(recorder.isRecording ? "esc to cancel" : "Change")
                        .font(Typeface.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Token.Space.md)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                        .fill(AppSurface.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                        .strokeBorder(
                            recorder.isRecording ? Palette.danger.opacity(0.8) : AppSurface.separator,
                            lineWidth: recorder.isRecording ? 1.5 : 0.5
                        )
                )
            }
            .buttonStyle(.plain)
            .animation(Motion.honouringPreferences(Motion.content), value: recorder.isRecording)

            if case .modifier(.function) = shortcut.trigger,
               GlobeKeyBehaviour.conflictsWithDictation {
                globeConflictNotice
            }
        }
        .onAppear {
            recorder.onCapture = { captured in
                shortcut = captured
            }
            recorder.onRecordingChanged = onRecordingChanged
            if startsRecording { recorder.begin() }
        }
        .onDisappear { recorder.cancel() }
    }

    /// Without this, binding the Globe key looks like a bug: macOS eats the
    /// press for its own input-source switcher and Masterful never sees it.
    private var globeConflictNotice: some View {
        HStack(alignment: .top, spacing: Token.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
                .font(Typeface.secondary)
            VStack(alignment: .leading, spacing: Token.Space.xxs) {
                Text("macOS is using the Globe key for “\(GlobeKeyBehaviour.current.displayName)”")
                    .font(Typeface.secondaryEmphasised)
                Text("Set it to “Do Nothing” or Masterful will never see the press.")
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
                Button("Open Keyboard settings") {
                    GlobeKeyBehaviour.openKeyboardSettings()
                }
                .controlSize(.small)
                .padding(.top, Token.Space.xxs)
            }
        }
        .padding(Token.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                .fill(Palette.warning.opacity(0.12))
        )
    }

    private func toggle() {
        recorder.isRecording ? recorder.cancel() : recorder.begin()
    }
}
