import Foundation
import MasterfulKit

/// Turns raw press/release edges into dictation intents.
///
/// The design goal is zero perceived latency in *both* modes. The obvious
/// implementation — wait out the double-tap window before deciding what the
/// press meant — makes push-to-talk feel broken, because nothing happens for the
/// first 300 ms of every utterance.
///
/// So: recording starts on the very first press, always. The *release* decides
/// what it was. A long release was push-to-talk and ends the session. A short
/// release holds the microphone open for the double-tap window; a second press
/// inside that window promotes the running session to latched, and silence ends
/// it normally. The user never waits, and one utterance is never split in two.
public struct HotkeyResolver: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        public var minimumHold: Duration
        public var doubleTapWindow: Duration
        public var latchEnabled: Bool

        public init(
            minimumHold: Duration = .milliseconds(220),
            doubleTapWindow: Duration = .milliseconds(320),
            latchEnabled: Bool = true
        ) {
            self.minimumHold = minimumHold
            self.doubleTapWindow = doubleTapWindow
            self.latchEnabled = latchEnabled
        }

        public init(settings: Settings) {
            self.init(
                minimumHold: settings.minimumHold,
                doubleTapWindow: settings.doubleTapWindow,
                latchEnabled: settings.enableDoubleTapLatch
            )
        }
    }

    public enum Output: Sendable, Equatable {
        case intent(DictationIntent)
        /// Start (or restart) the double-tap timer.
        case scheduleTapTimeout(Duration)
        case cancelTapTimeout
    }

    enum State: Sendable, Equatable {
        case idle
        /// Trigger is physically down, recording.
        case holding(since: TimeInterval)
        /// Trigger released quickly; still recording while we wait to see if a
        /// second tap arrives.
        case awaitingSecondTap
        /// Latched on. Only a fresh press ends it.
        case latched
    }

    public var configuration: Configuration
    private(set) var state: State = .idle

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public var isEngaged: Bool { state != .idle }

    public mutating func press(at timestamp: TimeInterval) -> [Output] {
        switch state {
        case .idle:
            state = .holding(since: timestamp)
            return [.intent(.beginListening(.pushToTalk))]

        case .holding:
            // Key auto-repeat, or a duplicate flagsChanged. Already recording.
            return []

        case .awaitingSecondTap:
            state = .latched
            return [.cancelTapTimeout, .intent(.promoteToLatched)]

        case .latched:
            state = .idle
            return [.intent(.endListening)]
        }
    }

    public mutating func release(at timestamp: TimeInterval) -> [Output] {
        switch state {
        case .holding(let since):
            let held = Duration.seconds(max(0, timestamp - since))
            guard configuration.latchEnabled, held < configuration.minimumHold else {
                state = .idle
                return [.intent(.endListening)]
            }
            // Too short to be a deliberate hold. Keep the microphone open and
            // give the second tap a chance to land.
            state = .awaitingSecondTap
            return [.scheduleTapTimeout(configuration.doubleTapWindow)]

        case .latched:
            // The release belonging to the press that latched us. Not an end.
            return []

        case .idle, .awaitingSecondTap:
            return []
        }
    }

    public mutating func tapTimeoutElapsed() -> [Output] {
        guard state == .awaitingSecondTap else { return [] }
        // No second tap. Treat it as a very short push-to-talk; if nothing was
        // said, the session reports "didn't catch that" rather than inserting.
        state = .idle
        return [.intent(.endListening)]
    }

    /// Escape, a binding change, or a hard error.
    public mutating func reset() -> [Output] {
        guard state != .idle else { return [] }
        state = .idle
        return [.cancelTapTimeout, .intent(.cancel)]
    }
}
