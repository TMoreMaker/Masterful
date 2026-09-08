import Foundation
import OSLog

/// The latency budget, instrumented.
///
/// `docs/latency.md` states a budget for each stage of a dictation. This is the
/// thing that makes that document a measurement rather than an intention: every
/// stage opens an `OSSignposter` interval under
/// `com.tlotliso.masterful:latency`, which Instruments reads directly. "Did that
/// regress" is then answered by a trace against real hardware rather than by
/// re-reading the code and hoping.
///
/// **The budgets live here, not only in the document.** The table in
/// `docs/latency.md` is these numbers. Keeping them in one place is the only way
/// a prose budget and a running app stay honest with each other — the previous
/// version of that table named six signpost intervals that did not exist.
///
/// Nothing here is on the critical path it measures: a signpost is a few
/// nanoseconds, and the wall-clock comparison happens after the interval has
/// already closed.
@MainActor
public final class LatencyTrace {

    /// The stages the budget is written against. Each maps to one signpost
    /// interval, named exactly as `docs/latency.md` names it.
    public enum Stage: CaseIterable, Sendable {
        /// Hotkey edge → the island is on screen.
        case hudPresent
        /// Hotkey edge → the first audio buffer reaches the recogniser.
        case captureStart
        /// Key release → the final transcript.
        case transcribeFinalize
        /// Final transcript → refined text.
        case refine
        /// Refined text → characters in the field.
        case insert
        /// Key release → text on screen. The only one the user actually feels;
        /// the rest exist to say which part of it went wrong.
        case sessionTotal

        public var budget: Duration {
            switch self {
            case .hudPresent: .milliseconds(50)
            case .captureStart: .milliseconds(80)
            case .transcribeFinalize: .milliseconds(400)
            // The on-device model's ceiling, set from measurement — see the
            // note in `docs/latency.md` about the 600 ms figure that made the
            // whole stage dead code. The rules path returns in about 5 ms.
            case .refine: .milliseconds(1200)
            case .insert: .milliseconds(100)
            // With on-device clean-up. Rules-only comes in under a second.
            case .sessionTotal: .milliseconds(1800)
            }
        }

        public var name: String {
            switch self {
            case .hudPresent: "hud.present"
            case .captureStart: "capture.start"
            case .transcribeFinalize: "transcribe.finalize"
            case .refine: "refine"
            case .insert: "insert"
            case .sessionTotal: "session.total"
            }
        }
    }

    private var open: [Stage: OSSignpostIntervalState] = [:]
    private var startedAt: [Stage: ContinuousClock.Instant] = [:]

    public init() {}

    public func begin(_ stage: Stage) {
        // A restart can arrive while the previous interval is still open — the
        // user pressing the key again mid-flight is a real and supported thing.
        // Close the stale one so the trace stays balanced, and say nothing about
        // it: it did not overrun, it was abandoned.
        if let stale = open.removeValue(forKey: stage) {
            Self.endInterval(stage, stale)
            startedAt[stage] = nil
        }
        open[stage] = Self.beginInterval(stage, id: Log.signposter.makeSignpostID())
        startedAt[stage] = ContinuousClock.now
    }

    /// Closes the interval, and logs when the stage overran its budget.
    ///
    /// The signpost is for Instruments; the log line is so that a breach is also
    /// visible in a plain `log show` export, which is all anyone has when the
    /// report is "it felt slow this morning".
    public func end(_ stage: Stage) {
        guard let state = open.removeValue(forKey: stage) else { return }
        Self.endInterval(stage, state)

        guard let start = startedAt.removeValue(forKey: stage) else { return }
        let elapsed = ContinuousClock.now - start
        guard elapsed > stage.budget else { return }
        Log.latency.notice(
            """
            \(stage.name, privacy: .public) over budget: \
            \(elapsed.milliseconds, privacy: .public)ms > \
            \(stage.budget.milliseconds, privacy: .public)ms
            """
        )
    }

    /// Closes everything still open, for a session that was cancelled or failed.
    ///
    /// An interval left open sits unterminated in the trace for ever, which is
    /// worse than a short one: it makes every later reading of that stage
    /// suspect. These durations are real up to the point it went wrong.
    public func endAll() {
        for stage in Array(open.keys) { end(stage) }
    }

    // MARK: - Signpost names
    //
    // `OSSignposter` takes a `StaticString`, so the name has to be a literal at
    // the call site rather than something read off the stage. These two switches
    // are the price of that, and the reason `Stage.name` exists separately.

    private static func beginInterval(_ stage: Stage, id: OSSignpostID) -> OSSignpostIntervalState {
        switch stage {
        case .hudPresent: Log.signposter.beginInterval("hud.present", id: id)
        case .captureStart: Log.signposter.beginInterval("capture.start", id: id)
        case .transcribeFinalize: Log.signposter.beginInterval("transcribe.finalize", id: id)
        case .refine: Log.signposter.beginInterval("refine", id: id)
        case .insert: Log.signposter.beginInterval("insert", id: id)
        case .sessionTotal: Log.signposter.beginInterval("session.total", id: id)
        }
    }

    private static func endInterval(_ stage: Stage, _ state: OSSignpostIntervalState) {
        switch stage {
        case .hudPresent: Log.signposter.endInterval("hud.present", state)
        case .captureStart: Log.signposter.endInterval("capture.start", state)
        case .transcribeFinalize: Log.signposter.endInterval("transcribe.finalize", state)
        case .refine: Log.signposter.endInterval("refine", state)
        case .insert: Log.signposter.endInterval("insert", state)
        case .sessionTotal: Log.signposter.endInterval("session.total", state)
        }
    }
}

extension Duration {
    /// Whole milliseconds. Used for budget reporting, where sub-millisecond
    /// precision would be noise.
    public var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}
