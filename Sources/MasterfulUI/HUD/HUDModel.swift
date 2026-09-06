import MasterfulKit
import Observation
import SwiftUI

/// Everything the HUD draws.
///
/// A plain projection of `DictationPhase` plus the two things that change too
/// fast to belong in the state machine: the live transcript and the waveform.
@MainActor
@Observable
public final class HUDModel {
    public var phase: DictationPhase = .idle
    public var transcript: String = ""
    public internal(set) var isPresented: Bool = false

    /// Rolling window of loudness, oldest first. Fixed length so the waveform's
    /// geometry never reflows.
    public private(set) var levels: [Float] = Array(
        repeating: 0, count: Token.Size.waveformBars
    )

    public init() {}

    public func push(level: AudioLevel) {
        levels.removeFirst()
        levels.append(min(1, max(level.rms, level.peak * 0.7)))
    }

    public func resetLevels() {
        levels = Array(repeating: 0, count: Token.Size.waveformBars)
    }
}
