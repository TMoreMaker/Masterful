import Foundation
import MasterfulKit
import os

/// Applies clean-up according to the user's chosen mode.
///
/// Structured as a ladder rather than a switch so that the AI stages added in a
/// later milestone slot in behind the same guard rails: rules always run, the
/// model stage is always optional, always time-boxed, and always discarded if
/// `TranscriptGuard` rejects it.
public struct RefinementPipeline: Refiner {
    private let rules: RuleBasedRefiner
    private let model: (any Refiner)?
    private let budget: Duration

    public init(
        rules: RuleBasedRefiner = .init(),
        model: (any Refiner)? = nil,
        budget: Duration = .milliseconds(600)
    ) {
        self.rules = rules
        self.model = model
        self.budget = budget
    }

    public func refine(_ text: String, context: RefinementContext) async -> String {
        let tidied = await rules.refine(text, context: context)
        guard let model else { return tidied }

        guard let candidate = await withBudget(budget, operation: {
            await model.refine(tidied, context: context)
        }) else {
            Log.refinement.notice("Model stage exceeded budget — using rule output")
            return tidied
        }

        guard TranscriptGuard.isTrustworthy(
            original: tidied, candidate: candidate, profile: context.profile
        ) else {
            Log.refinement.warning("Model output rejected by guard — using rule output")
            return tidied
        }
        return candidate
    }

    /// Races the operation against a deadline, returning the instant either wins.
    ///
    /// The obvious implementation — two child tasks in a `withTaskGroup`, take
    /// `group.next()`, `cancelAll()` — is wrong, and wrong in a way that hides
    /// itself: a task group implicitly awaits every child before it returns, so
    /// the timeout produces the correct *value* while still blocking for the
    /// full duration of the model call. Cancellation does not save it either,
    /// because inference does not check for it. The deadline appears to work and
    /// enforces nothing, which is the worst kind of latency bug.
    ///
    /// So the race is resolved on a continuation instead, claimed by whichever
    /// side finishes first. The losing model call is cancelled and abandoned —
    /// it may run on briefly and waste a little work, which is the correct trade
    /// against making the user wait for text they have already finished saying.
    private func withBudget(
        _ budget: Duration,
        operation: @escaping @Sendable () async -> String
    ) async -> String? {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        func claim() -> Bool {
            claimed.withLock { alreadyClaimed in
                if alreadyClaimed { return false }
                alreadyClaimed = true
                return true
            }
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let work = Task {
                let value = await operation()
                if claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: budget)
                if claim() {
                    work.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
