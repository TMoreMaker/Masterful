import Foundation
import MasterfulKit

/// Builds the refinement ladder for a given mode and destination.
///
/// One place decides which stages run, so the guarantee holds uniformly: rules
/// always run, any model stage is time-boxed, and `TranscriptGuard` vets its
/// output before it can reach the user's text field.
public enum RefinerFactory {

    /// Headroom over the measured p95, so a slightly slow run still lands.
    public static let onDeviceBudget = Duration.milliseconds(1_200)

    public static func make(
        mode: RefinementMode,
        profile: FormattingProfile,
        provider: RemoteProvider,
        budget: Duration = .milliseconds(600)
    ) -> any Refiner {
        switch mode {
        case .off:
            return PassthroughRefiner()

        case .rules:
            return RefinementPipeline(budget: budget)

        case .onDevice:
            // Falls back to rules-only rather than failing when Apple
            // Intelligence is off, so choosing this mode can never leave the
            // user worse off than not choosing it.
            guard FoundationModelsRefiner.availability.isAvailable else {
                Log.refinement.notice("On-device model unavailable — rules only")
                return RefinementPipeline(budget: budget)
            }
            return RefinementPipeline(
                model: FoundationModelsRefiner(profile: profile),
                // Measured, not guessed: the on-device model runs p50 ~700ms and
                // p95 ~875ms on this corpus (`make eval`). A 600ms deadline
                // rejected 8 of 12 results, which does not make the app fast —
                // it makes the on-device stage dead code that costs latency and
                // returns the rule output anyway.
                budget: Self.onDeviceBudget
            )

        case .remote:
            guard Keychain.has(account: provider.keychainAccount) else {
                Log.refinement.notice("Remote mode selected without a key — rules only")
                return RefinementPipeline(budget: budget)
            }
            return RefinementPipeline(
                model: RemoteRefiner(provider: provider, profile: profile),
                // A network round trip legitimately needs longer than the local
                // model, but not so long that the user notices waiting.
                budget: .milliseconds(1_400)
            )
        }
    }

    /// What the settings UI should tell the user about a mode before they pick it.
    public static func availabilityNote(for mode: RefinementMode, provider: RemoteProvider) -> String? {
        switch mode {
        case .off, .rules:
            return nil
        case .onDevice:
            let availability = FoundationModelsRefiner.availability
            return availability.isAvailable ? nil : availability.userMessage
        case .remote:
            return Keychain.has(account: provider.keychainAccount)
                ? nil
                : "Add a \(provider.displayName) API key below"
        }
    }
}
