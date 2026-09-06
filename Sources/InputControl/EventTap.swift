import CoreGraphics
import Foundation
import MasterfulKit
import os

/// A single low-level input event, flattened into something `Sendable` that the
/// rest of the app can reason about without touching CoreGraphics.
public struct RawInputEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown, keyUp, flagsChanged, mouseDown, mouseUp
    }

    public var kind: Kind
    public var keyCode: UInt16
    public var rawFlags: UInt64
    public var mouseButton: Int
    /// Monotonic seconds. Never wall-clock: the hold/double-tap logic must not
    /// be perturbed by NTP steps or the user changing timezone mid-sentence.
    public var timestamp: TimeInterval

    public var modifiers: ModifierSet {
        var set = ModifierSet()
        if rawFlags & CGEventFlags.maskCommand.rawValue != 0 { set.insert(.command) }
        if rawFlags & CGEventFlags.maskShift.rawValue != 0 { set.insert(.shift) }
        if rawFlags & CGEventFlags.maskAlternate.rawValue != 0 { set.insert(.option) }
        if rawFlags & CGEventFlags.maskControl.rawValue != 0 { set.insert(.control) }
        if rawFlags & CGEventFlags.maskSecondaryFn.rawValue != 0 { set.insert(.function) }
        return set
    }

    /// Whether the specific *physical* key that this `flagsChanged` refers to is
    /// currently held.
    ///
    /// The general masks (`maskShift`) cannot answer this: with both shifts down,
    /// releasing one leaves `maskShift` set and a naive reader sees a second
    /// press. The device-dependent bits in the low word identify each side, so
    /// this is the only correct way to track a bare modifier as a hotkey.
    public func isHeld(_ key: ModifierKey) -> Bool {
        rawFlags & key.deviceMask != 0
    }
}

extension ModifierKey {
    /// Device-dependent modifier bits from `IOKit/hidsystem/IOLLEvent.h`.
    /// `fn` and Caps Lock have no sides, so they use their general masks.
    public var deviceMask: UInt64 {
        switch self {
        case .leftControl:  0x0000_0001
        case .leftShift:    0x0000_0002
        case .rightShift:   0x0000_0004
        case .leftCommand:  0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption:   0x0000_0020
        case .rightOption:  0x0000_0040
        case .rightControl: 0x0000_2000
        case .function:     CGEventFlags.maskSecondaryFn.rawValue
        case .capsLock:     CGEventFlags.maskAlphaShift.rawValue
        }
    }
}

/// Installs a session-level `CGEventTap` and delivers events to a handler.
///
/// Three things about this class are load-bearing:
///
/// 1. It runs on a dedicated thread with its own run loop. The tap callback is
///    invoked synchronously by the window server; parking it on the main thread
///    means every dropped frame in our UI becomes input latency system-wide.
/// 2. The handler returns `true` to swallow the event. It runs on the tap thread
///    and must stay allocation-free and lock-light — anything slow here and
///    macOS disables the tap out from under us.
/// 3. It re-arms itself on `tapDisabledByTimeout`. Skipping this is why some
///    hotkey utilities mysteriously stop working after a few hours.
public final class EventTapMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (RawInputEvent) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private let started = OSAllocatedUnfairLock(initialState: false)

    /// Set `MASTERFUL_LOG_INPUT=1` to log every observed event.
    ///
    /// "My hotkey does nothing" has several indistinguishable causes — macOS
    /// swallowing the key, the wrong binding stored, a modifier the tap never
    /// sees — and they are impossible to tell apart from the outside. Reading it
    /// once at startup keeps the check off the hot path.
    nonisolated static let isTracingEnabled =
        ProcessInfo.processInfo.environment["MASTERFUL_LOG_INPUT"] == "1"

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var isRunning: Bool { started.withLock { $0 } }

    /// - Returns: `false` when Accessibility permission is missing, which is the
    ///   only reason `CGEvent.tapCreate` realistically fails.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard AccessibilityPermission.isGranted else {
            Log.input.error("Event tap refused: Accessibility permission not granted")
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.process(type: type, event: event)
            },
            userInfo: context
        ) else {
            Log.input.error("CGEvent.tapCreate returned nil")
            return false
        }

        self.tap = tap
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        let thread = Thread { [weak self] in
            // Reached through `self` rather than captured: CFMachPort is not
            // Sendable, and this class vouches for its own thread safety.
            guard let self, let source = self.source, let tap = self.tap else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.started.withLock { $0 = true }
            Log.input.info("Event tap running")
            // Parks here for the lifetime of the app.
            CFRunLoopRun()
        }
        thread.name = "com.tlotliso.masterful.eventtap"
        // Input latency is perceptual. This thread does almost nothing, but when
        // it does, it must not wait behind a background download.
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopSourceInvalidate(source) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        started.withLock { $0 = false }
        Log.input.info("Event tap stopped")
    }

    // Called on the tap thread, for every matching event in the session.
    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // We were too slow, or the system was busy. Re-arm rather than
            // silently dying.
            Log.input.warning("Event tap disabled by timeout — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .tapDisabledByUserInput:
            Log.input.warning("Event tap disabled by user input — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        default:
            break
        }

        let kind: RawInputEvent.Kind? = switch type {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .flagsChanged: .flagsChanged
        case .otherMouseDown: .mouseDown
        case .otherMouseUp: .mouseUp
        default: nil
        }
        guard let kind else { return Unmanaged.passUnretained(event) }

        // Ignore keystrokes we posted ourselves — see `SyntheticEvent.marker`.
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.marker {
            return Unmanaged.passUnretained(event)
        }

        let raw = RawInputEvent(
            kind: kind,
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            rawFlags: event.flags.rawValue,
            mouseButton: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            timestamp: MonotonicClock.now
        )

        if Self.isTracingEnabled {
            Log.input.debug(
                "tap \(String(describing: raw.kind), privacy: .public) code=\(raw.keyCode) flags=0x\(String(raw.rawFlags, radix: 16), privacy: .public) button=\(raw.mouseButton)"
            )
        }

        return handler(raw) ? nil : Unmanaged.passUnretained(event)
    }
}

/// Monotonic seconds since boot, cheap enough to call on the tap thread.
public enum MonotonicClock {
    private static let base: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    public static var now: TimeInterval {
        Double(mach_absolute_time()) * base.numer / base.denom / 1_000_000_000
    }
}
