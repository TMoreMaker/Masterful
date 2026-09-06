import Foundation

/// A modifier, identified by side. `flagsChanged` events carry a key code, so we
/// can tell left Option from right Option — which matters, because binding
/// dictation to right-Option while leaving left-Option usable is a common setup.
public enum ModifierKey: String, Sendable, Codable, Hashable, CaseIterable {
    case function
    case capsLock
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand

    /// Virtual key codes as reported by `CGEvent` on `flagsChanged`.
    public var keyCode: UInt16 {
        switch self {
        case .leftShift: 56
        case .rightShift: 60
        case .leftControl: 59
        case .rightControl: 62
        case .leftOption: 58
        case .rightOption: 61
        case .leftCommand: 55
        case .rightCommand: 54
        case .capsLock: 57
        case .function: 63
        }
    }

    public init?(keyCode: UInt16) {
        guard let match = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = match
    }

    public var symbol: String {
        switch self {
        case .function: "🌐"
        case .capsLock: "⇪"
        case .leftShift, .rightShift: "⇧"
        case .leftControl, .rightControl: "⌃"
        case .leftOption, .rightOption: "⌥"
        case .leftCommand, .rightCommand: "⌘"
        }
    }

    public var displayName: String {
        switch self {
        case .function: "Globe (fn)"
        case .capsLock: "Caps Lock"
        case .leftShift: "Left Shift"
        case .rightShift: "Right Shift"
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        }
    }
}

public struct ModifierSet: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let command  = ModifierSet(rawValue: 1 << 0)
    public static let shift    = ModifierSet(rawValue: 1 << 1)
    public static let option   = ModifierSet(rawValue: 1 << 2)
    public static let control  = ModifierSet(rawValue: 1 << 3)
    public static let function = ModifierSet(rawValue: 1 << 4)

    /// Ordered the way macOS renders them in menus.
    public var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        if contains(.function) { out += "🌐" }
        return out
    }
}

/// What the user actually pressed.
///
/// One type covers all three binding kinds so the event tap, the recorder UI and
/// the settings store never need to branch on "is this a key or a mouse button".
/// That uniformity is the whole reason a mouse side-button is a first-class
/// dictation trigger here rather than a special case bolted on later.
public enum Trigger: Sendable, Codable, Hashable {
    /// A normal key, optionally with modifiers. e.g. ⌥Space.
    case key(code: UInt16, modifiers: ModifierSet)
    /// A bare modifier held on its own. This is the only way to bind Globe/fn,
    /// which never produces a `keyDown` event at all.
    case modifier(ModifierKey)
    /// Mouse button by index. 0 and 1 are left/right and are never bindable;
    /// 2 is middle, 3+ are the side buttons most gaming/productivity mice expose.
    case mouseButton(Int)

    public var isBindable: Bool {
        if case .mouseButton(let n) = self { return n >= 2 }
        return true
    }
}

/// A binding, plus how it behaves when pressed.
public struct Shortcut: Sendable, Codable, Hashable {
    public var trigger: Trigger
    public init(trigger: Trigger) { self.trigger = trigger }

    public var displayString: String {
        switch trigger {
        case .key(let code, let modifiers):
            modifiers.symbols + (KeyCodeNames.name(for: code) ?? "Key \(code)")
        case .modifier(let key):
            key.symbol + " " + key.displayName
        case .mouseButton(let index):
            "Mouse \(index + 1)"
        }
    }

    /// The user's stated default: hold Globe to talk.
    public static let globeKey = Shortcut(trigger: .modifier(.function))
}

/// Human-readable names for the virtual key codes a recorder can capture.
public enum KeyCodeNames {
    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func name(for code: UInt16) -> String? { table[code] }
}
