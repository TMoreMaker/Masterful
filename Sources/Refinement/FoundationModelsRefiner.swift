import Foundation
import FoundationModels
import MasterfulKit

/// Clean-up on Apple's on-device model.
///
/// The preferred AI stage, and not only because it is free: the transcript never
/// leaves the machine, there is no network round trip in the latency budget, and
/// it works on a plane. Availability is genuinely conditional though — Apple
/// Intelligence must be switched on and the model downloaded — so this type
/// reports its own readiness rather than assuming it.
public struct FoundationModelsRefiner: Refiner {

    public enum Availability: Equatable, Sendable {
        case available
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady

        public var isAvailable: Bool { self == .available }

        public var userMessage: String {
            switch self {
            case .available: "Ready"
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence"
            case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings"
            case .modelNotReady: "Apple Intelligence is still downloading"
            }
        }
    }

    private let profile: FormattingProfile

    public init(profile: FormattingProfile = .prose) {
        self.profile = profile
    }

    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        // Apple may add reasons; treat anything new as "not ready" so a future
        // OS cannot turn an unknown case into a crash.
        @unknown default: .modelNotReady
        }
    }

    /// Loads the model into memory ahead of being needed.
    ///
    /// The first call after launch measured 1527ms against ~700ms warm, and that
    /// difference is entirely weight loading. Dictation gives us somewhere to
    /// hide it: the user spends a second or more actually speaking, so warming
    /// up the moment the hotkey goes down means the model is resident by the
    /// time there is a transcript to clean. Cheap and idempotent once warm.
    public static func prewarm(profile: FormattingProfile = .prose) {
        guard availability.isAvailable else { return }
        let session = LanguageModelSession(
            instructions: CleanupPrompt.instructions(for: profile)
        )
        session.prewarm()
    }

    public func refine(_ text: String, context: RefinementContext) async -> String {
        guard Self.availability.isAvailable else { return text }
        guard profile != .verbatim else { return text }

        let session = LanguageModelSession(
            instructions: CleanupPrompt.instructions(for: profile)
        )

        do {
            let response = try await session.respond(
                to: CleanupPrompt.userMessage(
                    transcript: text,
                    vocabulary: context.vocabulary
                ),
                options: GenerationOptions(
                    // Greedy decoding. This is a formatting task with one right
                    // answer; sampling would only introduce variation between
                    // runs on identical input, which reads as unreliability.
                    sampling: .greedy,
                    temperature: 0,
                    // A tidy-up cannot legitimately be much longer than its
                    // input. This is a ceiling on runaway generation, and
                    // `TranscriptGuard` catches anything that gets near it.
                    maximumResponseTokens: max(64, text.count / 2)
                )
            )
            return CleanupPrompt.sanitise(response.content)
        } catch {
            // Includes guardrail refusals on perfectly ordinary speech, which do
            // happen. The caller falls back to the deterministic rule output.
            Log.refinement.notice(
                "On-device refinement declined: \(error.localizedDescription, privacy: .public)"
            )
            return text
        }
    }
}
