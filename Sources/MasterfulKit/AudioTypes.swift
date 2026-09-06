import Foundation

/// A normalised loudness sample, produced by the capture layer and consumed by
/// the HUD waveform. Deliberately not an `AVAudioPCMBuffer`: the UI has no
/// business knowing about audio frameworks.
public struct AudioLevel: Sendable, Equatable {
    /// Root-mean-square loudness, already mapped from dBFS into `0...1`.
    public var rms: Float
    /// Instantaneous peak in the same range. Drives the waveform's tips.
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silence = AudioLevel(rms: 0, peak: 0)
}

/// Why a dictation attempt could not start or finish.
public enum DictationError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case speechModelUnavailable(String)
    case audioEngineFailed(String)
    case transcriptionFailed(String)
    case insertionFailed(String)
    case noSpeechDetected

    public var userMessage: String {
        switch self {
        case .microphonePermissionDenied: "Microphone access needed"
        case .accessibilityPermissionDenied: "Accessibility access needed"
        case .speechModelUnavailable(let detail): detail
        case .audioEngineFailed: "Microphone unavailable"
        case .transcriptionFailed: "Couldn't transcribe"
        case .insertionFailed: "Couldn't insert text"
        case .noSpeechDetected: "Didn't catch that"
        }
    }
}

/// Conditions under which we refuse to listen at all.
public enum BlockReason: Sendable, Equatable {
    /// macOS secure input is active — a password field owns the keyboard.
    /// Capturing here would be a genuine security problem, so we don't.
    case secureInputActive
    case missingPermission(DictationError)

    public var userMessage: String {
        switch self {
        case .secureInputActive: "Password field — not listening"
        case .missingPermission(let error): error.userMessage
        }
    }
}

/// Marks `CGEvent`s that Masterful itself posted.
///
/// We both synthesise keystrokes (to paste) and watch every keystroke (for
/// hotkeys). Without a marker those two facts form a loop: a user who binds
/// dictation to a chord we happen to emit would trigger themselves. Tagging our
/// own events and ignoring them at the tap closes it.
public enum SyntheticEvent {
    /// Arbitrary but stable — "MSTF" in ASCII.
    public static let marker: Int64 = 0x4D53_5446
}
