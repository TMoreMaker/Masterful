import CoreGraphics
import Foundation
import MasterfulKit

/// Performs a spoken command as real key presses.
///
/// Synthesised rather than routed through the Accessibility API because these
/// are *actions*, not text: pressing Return in a chat app has to trigger the
/// same handling a physical Return would, and setting an attribute cannot do
/// that. Every event carries `SyntheticEvent.marker` so our own event tap knows
/// to ignore it — otherwise a user who bound dictation to a chord we emit would
/// trigger themselves.
public struct KeyCommandExecutor: Sendable {

    public init() {}

    private struct Keystroke {
        let keyCode: CGKeyCode
        var flags: CGEventFlags = []
    }

    private enum Key {
        static let a: CGKeyCode = 0
        static let s: CGKeyCode = 1
        static let z: CGKeyCode = 6
        static let x: CGKeyCode = 7
        static let c: CGKeyCode = 8
        static let v: CGKeyCode = 9
        static let ret: CGKeyCode = 36
        static let tab: CGKeyCode = 48
        static let delete: CGKeyCode = 51
        static let escape: CGKeyCode = 53
    }

    private func keystrokes(for command: VoiceCommand) -> [Keystroke] {
        switch command {
        case .enter: [Keystroke(keyCode: Key.ret)]
        case .send: [Keystroke(keyCode: Key.ret, flags: .maskCommand)]
        // Shift-Return is "new line without sending" in every chat app, which is
        // the only place the distinction matters.
        case .newLine: [Keystroke(keyCode: Key.ret, flags: .maskShift)]
        case .tab: [Keystroke(keyCode: Key.tab)]
        case .escape: [Keystroke(keyCode: Key.escape)]
        case .delete: [Keystroke(keyCode: Key.delete)]
        case .deleteWord: [Keystroke(keyCode: Key.delete, flags: .maskAlternate)]
        case .clear: [
            Keystroke(keyCode: Key.a, flags: .maskCommand),
            Keystroke(keyCode: Key.delete),
        ]
        case .selectAll: [Keystroke(keyCode: Key.a, flags: .maskCommand)]
        case .copy: [Keystroke(keyCode: Key.c, flags: .maskCommand)]
        case .paste: [Keystroke(keyCode: Key.v, flags: .maskCommand)]
        case .cut: [Keystroke(keyCode: Key.x, flags: .maskCommand)]
        case .undo: [Keystroke(keyCode: Key.z, flags: .maskCommand)]
        case .save: [Keystroke(keyCode: Key.s, flags: .maskCommand)]
        }
    }

    @MainActor
    public func perform(_ command: VoiceCommand) async -> Bool {
        guard !SecureInput.isActive else {
            Log.insertion.notice("Refusing to send keys while secure input is active")
            return false
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        for stroke in keystrokes(for: command) {
            guard let down = CGEvent(
                    keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: true),
                  let up = CGEvent(
                    keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: false)
            else { return false }

            down.flags = stroke.flags
            up.flags = stroke.flags
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
            // A multi-key command like "clear" is two separate keystrokes; the
            // app needs a moment to process the selection before the delete.
            try? await Task.sleep(for: .milliseconds(24))
        }

        Log.insertion.info("Performed command \(command.rawValue, privacy: .public)")
        return true
    }
}
