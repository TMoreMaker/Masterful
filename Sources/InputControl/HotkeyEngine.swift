import Foundation
import MasterfulKit
import os

/// Bridges the event tap to the dictation state machine.
///
/// Everything that touches `HotkeyResolver` happens on the main actor; the tap
/// thread only performs a cheap comparison and hands the edge across. The
/// snapshot of the current bindings lives behind an unfair lock because the tap
/// callback cannot `await` anything.
///
/// Several bindings are live at once — the Globe key on the built-in keyboard, a
/// side button on the mouse, a chord on an external keyboard — because one
/// machine is several machines over a day. A session is *owned* by whichever
/// trigger started it: only that trigger's release ends a push-to-talk hold, so
/// resting a thumb on the mouse button while holding Globe cannot end a
/// dictation half way through a sentence.
@MainActor
public final class HotkeyEngine {
    public var onIntent: (@MainActor (DictationIntent) -> Void)?

    private var resolver: HotkeyResolver
    private var monitor: EventTapMonitor?
    private var tapTimeoutTask: Task<Void, Never>?

    /// Read from the tap thread on every keystroke, written from the main actor
    /// when settings change.
    private struct TapState {
        var triggers: [Trigger] = []
        /// The trigger that started the current dictation, if any.
        var owner: Trigger?
        var engaged = false
    }
    private let tapState = OSAllocatedUnfairLock(initialState: TapState())

    /// The bindings to restore after recording ends.
    private var configuredTriggers: [Trigger] = []

    private nonisolated static let escapeKeyCode: UInt16 = 53

    public init(settings: Settings) {
        self.resolver = HotkeyResolver(configuration: .init(settings: settings))
        self.configuredTriggers = settings.triggers.map(\.trigger)
        let triggers = self.configuredTriggers
        self.tapState.withLock { $0.triggers = triggers }
    }

    public var isRunning: Bool { monitor?.isRunning ?? false }

    @discardableResult
    public func start() -> Bool {
        guard monitor == nil else { return true }
        let monitor = EventTapMonitor { [weak self] event in
            guard let self else { return false }
            return self.handleOnTapThread(event)
        }
        self.monitor = monitor
        let ok = monitor.start()
        if !ok { self.monitor = nil }
        return ok
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        tapTimeoutTask?.cancel()
        tapTimeoutTask = nil
    }

    /// Suspends hotkey matching while the user is recording a new binding.
    ///
    /// Without this the engine fights the recorder: a bound mouse button is
    /// consumed by the tap system-wide, so it never reaches the recorder's local
    /// monitor and could never be re-recorded, and pressing an existing binding
    /// to change it would start dictating instead.
    public func setRecording(_ isRecording: Bool) {
        if isRecording {
            _ = resolver.reset()
            tapTimeoutTask?.cancel()
            tapTimeoutTask = nil
            tapState.withLock {
                $0.triggers = []
                $0.owner = nil
                $0.engaged = false
            }
        } else {
            let restore = configuredTriggers
            tapState.withLock { $0.triggers = restore }
        }
    }

    public func apply(settings: Settings) {
        resolver.configuration = .init(settings: settings)
        configuredTriggers = settings.triggers.map(\.trigger)
        let triggers = configuredTriggers
        tapState.withLock {
            $0.triggers = triggers
            $0.owner = nil
        }
        emit(resolver.reset())
    }

    /// Lets the coordinator tell us a session ended for reasons we did not cause
    /// so the resolver does not stay latched.
    public func sessionDidEnd() {
        _ = resolver.reset()
        tapState.withLock {
            $0.engaged = false
            $0.owner = nil
        }
        tapTimeoutTask?.cancel()
        tapTimeoutTask = nil
    }

    // MARK: - Tap thread

    private nonisolated func handleOnTapThread(_ event: RawInputEvent) -> Bool {
        // Escape always cancels an in-flight dictation. We observe it without
        // swallowing it — other apps may legitimately want the key too.
        if event.kind == .keyDown,
           event.keyCode == Self.escapeKeyCode,
           tapState.withLock({ $0.engaged }) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.emit(self.resolver.reset())
            }
            return false
        }

        // Resolve which binding this event belongs to, and whether it is allowed
        // to act, entirely inside one lock acquisition.
        enum Action { case press, release, ignore }
        let outcome: (action: Action, consume: Bool)? = tapState.withLock { state in
            for trigger in state.triggers {
                guard let match = Self.match(event: event, against: trigger) else { continue }
                switch match.edge {
                case .press:
                    // A second binding pressed mid-session is swallowed but does
                    // nothing: the session belongs to the trigger that began it.
                    guard state.owner == nil || state.owner == trigger else {
                        return (.ignore, match.consume)
                    }
                    state.owner = trigger
                    return (.press, match.consume)
                case .release:
                    guard state.owner == trigger else { return (.ignore, match.consume) }
                    return (.release, match.consume)
                }
            }
            return nil
        }

        guard let outcome else { return false }
        guard outcome.action != .ignore else { return outcome.consume }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch outcome.action {
            case .press: self.emit(self.resolver.press(at: event.timestamp))
            case .release: self.emit(self.resolver.release(at: event.timestamp))
            case .ignore: break
            }
        }
        return outcome.consume
    }

    nonisolated enum Edge: Sendable, Equatable { case press, release }

    /// Decides whether an event is an edge of one binding, and whether we should
    /// swallow it.
    ///
    /// Modifier events are *never* swallowed: consuming a `flagsChanged` desyncs
    /// the system's idea of which modifiers are down, and the user ends up with
    /// a stuck Command key. Real keys and mouse buttons are swallowed so that
    /// binding, say, ⌥Space does not also type a space.
    nonisolated static func match(event: RawInputEvent, against trigger: Trigger) -> (edge: Edge, consume: Bool)? {
        switch trigger {
        case .modifier(let key):
            guard event.kind == .flagsChanged, event.keyCode == key.keyCode else { return nil }
            return (event.isHeld(key) ? .press : .release, false)

        case .key(let code, let modifiers):
            guard event.keyCode == code else { return nil }
            switch event.kind {
            case .keyDown:
                // Modifiers must match exactly, so ⌥Space does not fire on ⌘⌥Space.
                guard event.modifiers == modifiers else { return nil }
                return (.press, true)
            case .keyUp:
                // Modifiers are often already released by key-up; match on code.
                return (.release, true)
            default:
                return nil
            }

        case .mouseButton(let index):
            guard event.mouseButton == index else { return nil }
            switch event.kind {
            case .mouseDown: return (.press, true)
            case .mouseUp: return (.release, true)
            default: return nil
            }
        }
    }

    // MARK: - Main actor

    private func emit(_ outputs: [HotkeyResolver.Output]) {
        for output in outputs {
            switch output {
            case .intent(let intent):
                switch intent {
                case .beginListening, .promoteToLatched:
                    tapState.withLock { $0.engaged = true }
                case .endListening, .cancel:
                    // Release ownership so any binding can start the next one.
                    tapState.withLock {
                        $0.engaged = false
                        $0.owner = nil
                    }
                default:
                    break
                }
                onIntent?(intent)

            case .scheduleTapTimeout(let duration):
                tapTimeoutTask?.cancel()
                tapTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled, let self else { return }
                    self.emit(self.resolver.tapTimeoutElapsed())
                }

            case .cancelTapTimeout:
                tapTimeoutTask?.cancel()
                tapTimeoutTask = nil
            }
        }
    }
}
