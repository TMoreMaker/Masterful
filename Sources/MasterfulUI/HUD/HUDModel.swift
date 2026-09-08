import MasterfulKit
import Observation
import SwiftUI

/// The island's two sizes.
public enum HUDPresentation: Equatable, Sendable {
    /// A bar the size of the notch. Says only that something is happening.
    case compact
    /// A card. Says what happened and what to do about it.
    case expanded
}

extension DictationPhase {
    /// When the island opens.
    ///
    /// One rule, applied everywhere: **expand only when there is something the
    /// user has to read.** Listening, transcribing and a clean insertion all
    /// resolve without the user doing anything, so they stay in the bar — the
    /// live transcript in particular is a thing to be read while you are still
    /// speaking, which is the one moment you cannot spare the attention.
    /// Failures, refusals, and text that ended up somewhere other than where it
    /// was aimed all need a sentence, so they open.
    var hudPresentation: HUDPresentation {
        switch self {
        case .failed, .blocked:
            return .expanded
        case .delivered(let delivery):
            // The text is not where the user was looking. That is worth a line.
            return delivery.destination == .clipboard ? .expanded : .compact
        case .idle, .listening, .transcribing, .refining, .inserting:
            return .compact
        }
    }
}

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
        repeating: 0, count: Token.Size.levelHistory
    )

    public init() {}

    /// A model frozen in one state, for documentation and previews.
    ///
    /// The specimen sheet's island images are rendered from `HUDView` itself
    /// rather than screenshotted, for the same reason the app icon is drawn by
    /// `Tools/make-icon.swift`: an image generated from the real view cannot
    /// drift away from what ships, and it is reproducible from a clean checkout.
    /// This is the one seam that needs opening to do that — `isPresented` is
    /// otherwise owned by `HUDController`, which is exactly where it belongs.
    public static func posed(phase: DictationPhase, levels: [Float] = []) -> HUDModel {
        let model = HUDModel()
        model.phase = phase
        model.isPresented = true
        if !levels.isEmpty {
            model.levels = Array(levels.suffix(Token.Size.levelHistory))
        }
        return model
    }

    public func push(level: AudioLevel) {
        levels.removeFirst()
        levels.append(min(1, max(level.rms, level.peak * 0.7)))
    }

    public func resetLevels() {
        levels = Array(repeating: 0, count: Token.Size.levelHistory)
    }
}
