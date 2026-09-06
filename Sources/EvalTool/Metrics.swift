import Foundation
import MasterfulKit
import Refinement

/// What we can measure automatically about one clean-up result.
///
/// None of these numbers say the output is *good* — that needs eyes. What they
/// do is catch the failures that matter and are tedious to spot by hand: words
/// going missing, the model answering instead of formatting, and latency
/// creeping past the point where dictation stops feeling immediate.
struct Metrics {
    var latency: Duration
    /// Fraction of the input's meaningful words that survived. Fillers are
    /// excluded, since removing those is the job.
    var retention: Double
    var lengthRatio: Double
    /// Whether `TranscriptGuard` would accept this rewrite in production.
    var passesGuard: Bool
    var fillersRemaining: Int
    var sentenceTerminators: Int
    /// Words present in the output that never appeared in the input. The single
    /// most useful signal for hallucination.
    var inventedWords: [String]

    static func measure(input: String, output: String, latency: Duration) -> Metrics {
        let inputTokens = tokens(input)
        let outputTokens = tokens(output)
        let inputSet = Set(inputTokens)
        let outputSet = Set(outputTokens)

        let meaningful = inputTokens.filter { !SpokenText.fillerWords.contains($0) }
        let retained = meaningful.filter { outputSet.contains($0) }.count
        let retention = meaningful.isEmpty ? 1 : Double(retained) / Double(meaningful.count)

        return Metrics(
            latency: latency,
            retention: retention,
            lengthRatio: input.isEmpty ? 1 : Double(output.count) / Double(input.count),
            passesGuard: TranscriptGuard.isTrustworthy(original: input, candidate: output),
            fillersRemaining: outputTokens.filter { SpokenText.fillerWords.contains($0) }.count,
            sentenceTerminators: output.filter { ".!?".contains($0) }.count,
            inventedWords: Array(Set(outputTokens.filter { !inputSet.contains($0) })).sorted()
        )
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    var latencyMilliseconds: Int {
        Int(Double(latency.components.seconds) * 1000
            + Double(latency.components.attoseconds) / 1e15)
    }

    /// A compact verdict for the summary table.
    var flags: [String] {
        var flags: [String] = []
        if !passesGuard { flags.append("GUARD-REJECT") }
        if retention < 0.85 { flags.append("WORDS-LOST") }
        if inventedWords.count > 3 { flags.append("INVENTED") }
        return flags
    }
}
