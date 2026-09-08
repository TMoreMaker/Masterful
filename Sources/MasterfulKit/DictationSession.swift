import Foundation

// MARK: - Phase

/// How the current dictation was started, which determines how it ends.
public enum ListeningMode: Sendable, Equatable {
    /// Held down. Releasing the key ends it.
    case pushToTalk
    /// Latched on by a double-tap. Runs until the key is pressed again.
    case latched
}

/// Where the finished text actually went.
public enum Destination: Sendable, Equatable {
    case focusedField
    /// Nothing was focused (or the app refused our text), so we left it on the
    /// clipboard rather than dropping it on the floor.
    case clipboard
}

public struct Delivery: Sendable, Equatable {
    public var characterCount: Int
    public var wordCount: Int
    public var destination: Destination
    /// Names of any spoken commands performed, e.g. "Return". A dictation can be
    /// nothing but commands, in which case a word count would report zero and
    /// tell the user nothing about what just happened.
    public var commandSummary: String?

    public init(
        characterCount: Int,
        wordCount: Int,
        destination: Destination,
        commandSummary: String? = nil
    ) {
        self.characterCount = characterCount
        self.wordCount = wordCount
        self.destination = destination
        self.commandSummary = commandSummary
    }
}

/// The single source of truth for what the app is doing. The HUD is a pure
/// function of this value — there is no `hud.show()` anywhere in the codebase.
public enum DictationPhase: Sendable, Equatable {
    case idle
    case listening(ListeningMode)
    case transcribing
    case refining
    case inserting
    case delivered(Delivery)
    case failed(DictationError)
    case blocked(BlockReason)

    public var isActive: Bool {
        switch self {
        case .idle: false
        default: true
        }
    }

    /// True while the microphone is live. Used to gate the recording indicator.
    public var isCapturing: Bool {
        if case .listening = self { return true }
        return false
    }

    /// True once the speaking is over and the machine has the problem:
    /// transcribing, refining, or putting the text where it goes.
    ///
    /// One flag for all three because that is how it reads from outside — your
    /// words are being written down — and because they can pass in well under a
    /// second, which is not long enough to be told three separate things.
    public var isThinking: Bool {
        switch self {
        case .transcribing, .refining, .inserting: true
        default: false
        }
    }
}

// MARK: - Intents

/// Everything that can happen to a session, from any source: the hotkey engine,
/// the transcriber, the inserter, or a timer.
public enum DictationIntent: Sendable, Equatable {
    case beginListening(ListeningMode)
    /// Push-to-talk released, or a latched session toggled off.
    case endListening
    /// A double-tap arrived while a push-to-talk session was already running.
    case promoteToLatched
    case cancel

    case partialTranscript(String)
    case finalTranscript(String)
    case refined(String)
    case delivered(Delivery)

    case failed(DictationError)
    case blocked(BlockReason)
    /// The HUD's dwell timer elapsed.
    case dismiss
}

// MARK: - Effects

/// Work the outside world must perform. The reducer never performs it itself,
/// which is what keeps this type free of AVFoundation and AppKit.
public enum DictationEffect: Sendable, Equatable {
    case startCapture
    /// Keep the microphone open for `tail` after the key is released. People
    /// trail off, and clipping the last word is the most obvious way a
    /// dictation tool can feel cheap.
    case stopCapture(tail: Duration)
    case finalizeTranscription
    case cancelTranscription
    case refine(String)
    case insert(String)
    case presentHUD
    case dismissHUD(after: Duration)
    case feedback(Feedback)
}

public enum Feedback: Sendable, Equatable {
    case started
    case delivered
    case rejected
}

// MARK: - Reducer

/// The dictation state machine.
///
/// Deliberately a value type with a single `apply` entry point: given a phase and
/// an intent it yields the next phase plus the effects required to get there, and
/// nothing else. Every branch below is covered by `MasterfulKitTests` without
/// touching a microphone.
public struct DictationSession: Sendable, Equatable {
    public private(set) var phase: DictationPhase = .idle

    /// The best transcript we have so far. Volatile while listening, final after.
    public private(set) var transcript: String = ""

    public init() {}

    /// How long the HUD lingers after a terminal state, per outcome.
    public enum Dwell {
        public static let success = Duration.milliseconds(1_100)
        public static let problem = Duration.milliseconds(2_200)
    }

    /// Grace period after release before the microphone actually closes.
    public static let captureTail = Duration.milliseconds(280)

    @discardableResult
    public mutating func apply(_ intent: DictationIntent) -> [DictationEffect] {
        switch (phase, intent) {

        // MARK: Starting

        case (.idle, .beginListening(let mode)),
             (.delivered, .beginListening(let mode)),
             (.failed, .beginListening(let mode)),
             (.blocked, .beginListening(let mode)):
            transcript = ""
            phase = .listening(mode)
            return [.presentHUD, .startCapture, .feedback(.started)]

        // A press arriving mid-flight — while still listening, or while the
        // previous utterance is being transcribed, refined or inserted — is a
        // restart, not a no-op. The user pressed the key; they want to talk. We
        // abandon whatever was in progress rather than queueing behind it.
        case (.listening, .beginListening(let mode)),
             (.transcribing, .beginListening(let mode)),
             (.refining, .beginListening(let mode)),
             (.inserting, .beginListening(let mode)):
            transcript = ""
            phase = .listening(mode)
            return [.cancelTranscription, .startCapture]

        case (.listening(.pushToTalk), .promoteToLatched):
            phase = .listening(.latched)
            return []

        // Ignore promotion once we are past the listening phase; the audio is
        // already closed and re-opening it would splice two utterances.
        case (_, .promoteToLatched):
            return []

        // MARK: Live transcript

        case (.listening, .partialTranscript(let text)):
            transcript = text
            return []

        // A late volatile result can land after release. Keep it — it is still
        // the best text we have — but do not change phase.
        case (.transcribing, .partialTranscript(let text)):
            transcript = text
            return []

        case (_, .partialTranscript):
            return []

        // MARK: Ending

        case (.listening, .endListening):
            phase = .transcribing
            return [.stopCapture(tail: Self.captureTail), .finalizeTranscription]

        case (_, .endListening):
            return []

        case (.listening, .cancel), (.transcribing, .cancel), (.refining, .cancel):
            transcript = ""
            phase = .idle
            return [
                .stopCapture(tail: .zero),
                .cancelTranscription,
                .dismissHUD(after: .zero),
                .feedback(.rejected),
            ]

        case (_, .cancel):
            return []

        // MARK: Transcript → text

        case (.transcribing, .finalTranscript(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                phase = .failed(.noSpeechDetected)
                return [.dismissHUD(after: Dwell.problem), .feedback(.rejected)]
            }
            transcript = trimmed
            phase = .refining
            return [.refine(trimmed)]

        case (_, .finalTranscript):
            return []

        case (.refining, .refined(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                phase = .failed(.noSpeechDetected)
                return [.dismissHUD(after: Dwell.problem), .feedback(.rejected)]
            }
            transcript = trimmed
            phase = .inserting
            return [.insert(trimmed)]

        case (_, .refined):
            return []

        case (.inserting, .delivered(let delivery)):
            phase = .delivered(delivery)
            return [.dismissHUD(after: Dwell.success), .feedback(.delivered)]

        case (_, .delivered):
            return []

        // MARK: Problems

        case (_, .failed(let error)):
            phase = .failed(error)
            return [
                .stopCapture(tail: .zero),
                .cancelTranscription,
                .dismissHUD(after: Dwell.problem),
                .feedback(.rejected),
            ]

        case (_, .blocked(let reason)):
            phase = .blocked(reason)
            return [.presentHUD, .dismissHUD(after: Dwell.problem), .feedback(.rejected)]

        // MARK: Dismissal

        case (.delivered, .dismiss), (.failed, .dismiss), (.blocked, .dismiss):
            transcript = ""
            phase = .idle
            return []

        case (_, .dismiss):
            return []
        }
    }
}
