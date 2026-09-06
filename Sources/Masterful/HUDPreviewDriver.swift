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

    public static func run(on hud: HUDController) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await cycle(on: hud)
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
    }

    private static func cycle(on hud: HUDController) async {
        let script: [(DictationPhase, String, Duration)] = [
            (.listening(.pushToTalk), "", .milliseconds(700)),
            (.listening(.pushToTalk), "the quick brown", .milliseconds(900)),
            (.listening(.latched), "the quick brown fox jumps over the lazy dog", .milliseconds(1400)),
            (.transcribing, "the quick brown fox jumps over the lazy dog", .milliseconds(700)),
            (.refining, "the quick brown fox jumps over the lazy dog", .milliseconds(500)),
            (.delivered(Delivery(characterCount: 44, wordCount: 9, destination: .focusedField)),
             "", .milliseconds(1200)),
            (.blocked(.secureInputActive), "", .milliseconds(1200)),
            (.failed(.noSpeechDetected), "", .milliseconds(1200)),
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
