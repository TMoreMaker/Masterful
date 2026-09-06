import Foundation
import MasterfulKit

/// What the text is for. Formatting that suits an email is wrong in a terminal,
/// and we already know the frontmost app when we insert.
public struct RefinementContext: Sendable, Equatable {
    public var applicationBundleID: String?
    public var applicationName: String?
    public var vocabulary: [String]
    /// Resolved from the frontmost app before refinement starts, so every stage
    /// in the ladder shapes the text the same way.
    public var profile: FormattingProfile

    public init(
        applicationBundleID: String? = nil,
        applicationName: String? = nil,
        vocabulary: [String] = [],
        profile: FormattingProfile = .prose
    ) {
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.vocabulary = vocabulary
        self.profile = profile
    }

    public static let none = RefinementContext()
}

public protocol Refiner: Sendable {
    func refine(_ text: String, context: RefinementContext) async -> String
}

/// Returns the transcript untouched. Used for `RefinementMode.off`, and as the
/// safe result whenever anything downstream goes wrong.
public struct PassthroughRefiner: Refiner {
    public init() {}
    public func refine(_ text: String, context: RefinementContext) async -> String { text }
}

/// Decides whether a model's rewrite may be trusted.
///
/// The failure mode that matters for dictation is not a clumsy edit — it is a
/// model quietly replacing what you said with something you did not say. Length
/// and token-overlap bounds catch hallucination, truncation and instruction
/// following ("Sure! Here is your cleaned text:") without needing to understand
/// the content. Anything that trips these bounds is discarded in favour of the
/// raw transcript, because inserting slightly untidy words you *did* say always
/// beats inserting tidy words you did not.
public enum TranscriptGuard {
    /// A rewrite may not shrink below this fraction of the original, nor grow
    /// beyond its reciprocal.
    public static let minimumLengthRatio = 0.55
    public static let maximumLengthRatio = 1.6
    /// Fraction of the original's words that must survive, ignoring fillers.
    public static let minimumTokenRetention = 0.6
    /// Share of the input's length that may be words which were never spoken.
    ///
    /// Not zero, because some genuinely wanted fixes introduce a new token — a
    /// homophone correction ("their" → "there") is a substitution, not an
    /// addition, but looks like one here. Kept tight so that a model rewriting a
    /// garbled sentence into a fluent one is rejected.
    ///
    /// This bound cannot catch everything, and pretending otherwise would be
    /// worse than the gap: a single inserted function word sits below the noise
    /// floor of any metric like this. The defences against that are the prompt,
    /// which forbids repairing broken sentences, and the history view, where the
    /// raw transcript is kept next to what was inserted so it can be audited.

    public static func isTrustworthy(original: String, candidate: String) -> Bool {
        let originalTokens = tokens(of: original)
        let candidateTokens = Set(tokens(of: candidate))

        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard !originalTokens.isEmpty else { return true }

        let ratio = Double(candidate.count) / Double(max(1, original.count))
        guard ratio >= minimumLengthRatio, ratio <= maximumLengthRatio else { return false }

        // Fillers are *supposed* to vanish, so they cannot count against retention.
        let meaningful = originalTokens.filter { !SpokenText.fillerWords.contains($0) }
        guard !meaningful.isEmpty else { return true }

        let retained = meaningful.filter { candidateTokens.contains($0) }.count
        guard Double(retained) / Double(meaningful.count) >= minimumTokenRetention else {
            return false
        }

        // Words in the output that were never in the input.
        let originalSet = Set(originalTokens)
        let invented = tokens(of: candidate).filter { !originalSet.contains($0) }.count
        let allowance = max(1, Int(Double(originalTokens.count) * maximumInventedRatio))
        return invented <= allowance
    }

    /// Ceiling on invented words, as a share of the input's token count.
    public static let maximumInventedRatio = 0.08

    static func tokens(of text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
