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

/// Something worth a glance that is not part of a dictation.
///
/// Shown only while the island is otherwise at rest, as a bar — never a card,
/// because nothing here needs acting on. It exists for one reason: a fix made
/// after a dictation changes what the next one will hear, and that is worth
/// knowing happened.
public enum IslandNotice: Equatable, Sendable {
    /// A name or term was added to the vocabulary from a fix.
    case learned(String)

    /// Read across the camera: the verb on the left of the notch, the word on
    /// the right. One string on one side would size *both* flanks to all of it
    /// — they must match to keep the gap over the camera — and the bar grew
    /// wide enough to cover the app's menus.
    public var leading: String {
        switch self {
        case .learned: "Learned"
        }
    }

    /// Long names are cut rather than the island widened without limit.
    public var trailing: String {
        switch self {
        case .learned(let term):
            term.count > 14 ? String(term.prefix(13)) + "…" : term
        }
    }

    public var spoken: String {
        switch self {
        case .learned(let term): "Learned \(term)"
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
    /// Drawn only while `phase` is `.idle`. Owned by `HUDController`.
    public internal(set) var notice: IslandNotice?
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
    public static func posed(
        phase: DictationPhase,
        levels: [Float] = [],
        coalescence: Double? = nil,
        clock: TimeInterval? = nil,
        presented: Bool = true,
        notice: IslandNotice? = nil
    ) -> HUDModel {
        let model = HUDModel()
        model.phase = phase
        model.notice = notice
        // `false` poses the island at rest — collapsed to exactly the notch,
        // which is the one state that cannot be photographed on real hardware
        // and the one that explains all the others.
        model.isPresented = presented
        model.posedCoalescence = coalescence
        model.posedClock = clock
        if !levels.isEmpty {
            model.levels = Array(levels.suffix(Token.Size.levelHistory))
        }
        return model
    }

    /// The activity indicator's morph, held still.
    ///
    /// `VoiceIndicator` normally gets this from the phase and lets SwiftUI's
    /// spring carry it from 0 to 1, which cannot be photographed: a renderer
    /// asks for one frame and the spring has not run. Posing it here — beside
    /// `isPresented`, the seam that already exists for exactly this — lets the
    /// motion strip walk the real spring's own values through the real view.
    /// `nil` in the running app, always.
    public internal(set) var posedCoalescence: Double?

    /// The instant to freeze the indicator's own clock at. `nil` runs live.
    public internal(set) var posedClock: TimeInterval?

    public func push(level: AudioLevel) {
        levels.removeFirst()
        levels.append(min(1, max(level.rms, level.peak * 0.7)))
    }

    public func resetLevels() {
        levels = Array(repeating: 0, count: Token.Size.levelHistory)
    }
}
