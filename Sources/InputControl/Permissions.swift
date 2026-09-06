import AppKit
import ApplicationServices
import Foundation
import MasterfulKit

/// Accessibility (`AXIsProcessTrusted`) gates two things we cannot work without:
/// installing a `CGEventTap`, and reading/writing the focused element's text.
/// There is no partial grant and no way to request it programmatically — the
/// system prompt is the only path, and the user must return to the app after.
public enum AccessibilityPermission {
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt if we have never asked. Returns the state *now*;
    /// a grant will not be reflected until the user acts, so callers poll.
    @discardableResult
    public static func request() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is an imported mutable C global, which
        // Swift 6 will not let us touch concurrently. Its value is a documented
        // constant, so we use it directly.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}

/// The Globe/fn key is claimed by macOS unless the user sets it to do nothing.
/// If we do not check this, binding dictation to fn appears to silently fail —
/// the input-source switcher eats it — and the user blames us.
public enum GlobeKeyBehaviour: Int, Sendable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmoji = 2
    case startDictation = 3

    /// Reads `com.apple.HIToolbox AppleFnUsageType`. When the key is absent
    /// macOS uses its own default, which is *not* "do nothing".
    public static var current: GlobeKeyBehaviour {
        guard let value = UserDefaults(suiteName: "com.apple.HIToolbox")?
            .object(forKey: "AppleFnUsageType") as? Int
        else {
            return .changeInputSource
        }
        return GlobeKeyBehaviour(rawValue: value) ?? .changeInputSource
    }

    public static var conflictsWithDictation: Bool { current != .doNothing }

    public var displayName: String {
        switch self {
        case .doNothing: "Do Nothing"
        case .changeInputSource: "Change Input Source"
        case .showEmoji: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        }
    }

    public static func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
