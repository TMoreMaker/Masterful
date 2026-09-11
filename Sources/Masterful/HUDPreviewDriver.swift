import Foundation
import MasterfulKit
import MasterfulUI

/// Drives the HUD through every state on a timer, with no microphone involved.
///
/// Not debug scaffolding to be deleted later: iterating on motion means watching
/// the same transition forty times in a row, and doing that by talking to your
/// laptop is both slow and a poor way to judge timing. Enabled with
/// `MASTERFUL_HUD_PREVIEW=1`.
@MainActor
public enum HUDPreviewDriver {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MASTERFUL_HUD_PREVIEW"] == "1"
    }

    /// Anchor to preview, overriding the user's own setting for the run.
    /// The three anchors produce genuinely different shapes — welded to the
    /// bezel versus floating as a card — so being able to flip between them
    /// without touching real settings is the difference between checking the
    /// other two and assuming they are fine.
    private static var anchorOverride: HUDAnchor? {
        ProcessInfo.processInfo.environment["MASTERFUL_HUD_ANCHOR"]
            .flatMap(HUDAnchor.init(rawValue:))
    }

    public static func run(on hud: HUDController) -> Task<Void, Never> {
        Task { @MainActor in
            if let anchorOverride { hud.setAnchor(anchorOverride) }
            while !Task.isCancelled {
                await cycle(on: hud)
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
    }

    /// One dictation each, rather than one long morph through every state.
    ///
    /// The island retracts into the notch between them, which is not a
    /// flourish — it is what the app does. A session ends when its outcome has
    /// been shown, and the next one starts from the notch; nothing in the
    /// product ever turns a delivered card into a refusal card. A preview that
    /// slid from one outcome straight into the next was showing a transition
    /// that cannot happen, and reading it as a catalogue rather than as five
    /// separate things happening to you.
    private static let sessions: [[(DictationPhase, String, Duration)]] = [
        // The whole happy path in one breath, because it is one breath: hold,
        // talk, let go, and the words land.
        [
            (.listening(.pushToTalk), "", .milliseconds(1200)),
            (.listening(.latched), "", .milliseconds(1000)),
            (.transcribing, "the quick brown fox jumps over the lazy dog", .milliseconds(800)),
            (.refining, "the quick brown fox jumps over the lazy dog", .milliseconds(400)),
            (.delivered(Delivery(characterCount: 44, wordCount: 9, destination: .focusedField)),
             "", .milliseconds(1300)),
        ],
        // Everything below opens a card, and each one arrives on its own.
        [(.delivered(Delivery(characterCount: 88, wordCount: 18, destination: .clipboard)),
          "", .milliseconds(1900))],
        [(.blocked(.secureInputActive), "", .milliseconds(1900))],
        [(.failed(.noSpeechDetected), "", .milliseconds(1900))],
        [(.failed(.microphonePermissionDenied), "", .milliseconds(1900))],
    ]

    /// Long enough for the retraction to finish and the notch to be plainly
    /// empty before the next one climbs out of it. Shorter than this and the
    /// sessions read as one stuttering animation rather than as separate events.
    private static let betweenSessions = Duration.milliseconds(750)

    private static func cycle(on hud: HUDController) async {
        for session in sessions {
            guard !Task.isCancelled, let opening = session.first else { return }

            // Phase first, then present. The island is still holding the last
            // session's contents until something says otherwise, and setting
            // them while it is collapsed means it comes out of the notch
            // already showing the right thing instead of swapping a frame in.
            hud.apply(phase: opening.0, transcript: opening.1)
            hud.present()

            for (index, step) in session.enumerated() {
                guard !Task.isCancelled else { return }
                if index > 0 {
                    hud.apply(phase: step.0, transcript: step.1)
                }
                await dwell(step.2, phase: step.0, on: hud)
            }

            hud.dismiss(after: .zero)
            try? await Task.sleep(for: betweenSessions)
        }
    }

    /// Holds a phase on screen, feeding the waveform while the microphone would
    /// have been open.
    private static func dwell(
        _ duration: Duration, phase: DictationPhase, on hud: HUDController
    ) async {
        guard case .listening = phase else {
            try? await Task.sleep(for: duration)
            return
        }
        let tick = Duration.milliseconds(33)
        let ticks = max(1, Int(duration / tick))
        for _ in 0..<ticks {
            guard !Task.isCancelled else { return }
            // Synthetic loudness so the waveform has something to react to.
            hud.push(level: AudioLevel(
                rms: Float.random(in: 0.15...0.85),
                peak: Float.random(in: 0.2...1.0)
            ))
            try? await Task.sleep(for: tick)
        }
    }
}
