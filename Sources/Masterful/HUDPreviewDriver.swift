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

    private static func cycle(on hud: HUDController) async {
        // Ordered to show the two shapes against each other: the compact bar
        // for everything that resolves itself, then each way the island has of
        // opening into a card.
        let script: [(DictationPhase, String, Duration)] = [
            (.listening(.pushToTalk), "", .milliseconds(1200)),
            (.listening(.latched), "", .milliseconds(1400)),
            (.transcribing, "the quick brown fox jumps over the lazy dog", .milliseconds(700)),
            (.refining, "the quick brown fox jumps over the lazy dog", .milliseconds(500)),
            (.delivered(Delivery(characterCount: 44, wordCount: 9, destination: .focusedField)),
             "", .milliseconds(1400)),
            (.delivered(Delivery(characterCount: 44, wordCount: 9, destination: .clipboard)),
             "", .milliseconds(2000)),
            (.blocked(.secureInputActive), "", .milliseconds(2000)),
            (.failed(.noSpeechDetected), "", .milliseconds(2000)),
            (.failed(.microphonePermissionDenied), "", .milliseconds(2000)),
        ]

        hud.present()
        for (phase, transcript, dwell) in script {
            guard !Task.isCancelled else { return }
            hud.apply(phase: phase, transcript: transcript)
            // Synthetic loudness so the waveform has something to react to.
            if case .listening = phase {
                for _ in 0..<Int(dwell.components.seconds * 30 + 20) {
                    hud.push(level: AudioLevel(
                        rms: Float.random(in: 0.15...0.85),
                        peak: Float.random(in: 0.2...1.0)
                    ))
                    try? await Task.sleep(for: .milliseconds(33))
                }
            } else {
                try? await Task.sleep(for: dwell)
            }
        }
        hud.dismiss(after: .zero)
    }
}
