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
        profile: FormattingProfile = .formal
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

    /// Whether a rewrite may be inserted.
    ///
    /// Which bounds apply depends on what the profile was allowed to do. A
    /// `verbatim` or `code` rewrite is checked for fidelity, because that is what
    /// it promised. A `technical`, `formal` or `informal` rewrite cannot be —
    /// compressing 57 spoken words into 20 written ones fails every overlap test
    /// there is, and correctly so, which is precisely why those tests are the
    /// wrong instrument for it.
    public static func isTrustworthy(
        original: String,
        candidate: String,
        profile: FormattingProfile
    ) -> Bool {
        profile.rewritesPhrasing
            ? isTrustworthyRewrite(original: original, candidate: candidate)
            : isTrustworthy(original: original, candidate: candidate)
    }

    /// Bounds for a rewrite that is *supposed* to change the wording.
    ///
    /// Overlap is abandoned; three cheaper properties replace it, each aimed at a
    /// specific way a rewrite goes wrong rather than at unfaithfulness in general.
    static func isTrustworthyRewrite(original: String, candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }

        // 1. It must not have grown. A rewrite that is longer than the speech it
        //    came from is the signature of a model that answered the transcript
        //    rather than writing it down — the single failure that would make
        //    this tool untrustworthy. The allowance covers very short utterances,
        //    where punctuation alone can outweigh the compression.
        let ratio = Double(trimmed.count) / Double(original.count)
        guard ratio <= maximumRewriteGrowth
            || trimmed.count <= original.count + shortUtteranceSlack else {
            return false
        }

        // 2. It must not have collapsed to a summary. Compression is the point,
        //    but a sentence standing in for a paragraph has lost content the
        //    speaker will not notice is missing.
        guard ratio >= minimumRewriteRatio else { return false }

        // 3. Every number survives, exactly. Prices, quantities and dates are
        //    what the speaker will act on and the last thing they would think to
        //    re-check, so a rewrite that drops or alters one is rejected outright
        //    however well it reads.
        let originalNumbers = numbers(in: original)
        let candidateNumbers = Set(numbers(in: trimmed))
        return originalNumbers.allSatisfy { candidateNumbers.contains($0) }
    }

    /// A rewrite may be at most this much longer than the speech it came from.
    public static let maximumRewriteGrowth = 1.0
    /// Absolute slack on top of that, so a short utterance is not rejected for
    /// gaining a comma and a full stop. Deliberately a fixed number of characters
    /// rather than a floor on length: an allowance expressed as "anything under
    /// N characters is fine" exempts short hallucinations from the growth check
    /// altogether, which is the one thing this bound exists to catch.
    public static let shortUtteranceSlack = 12
    /// Below this share of the original, it has summarised rather than tightened.
    public static let minimumRewriteRatio = 0.2

    /// Digit runs, with grouping separators removed so "18,000" and "18000" are
    /// the same number.
    static func numbers(in text: String) -> [String] {
        text.replacingOccurrences(of: "(?<=\\d)[,\\s](?=\\d{3}\\b)", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
            .filter { !$0.isEmpty }
    }

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
