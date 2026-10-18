import Foundation

/// Joins the recogniser's segments back into one transcript.
///
/// The recogniser does not hand over one transcript. It closes off a segment
/// every time the speaker pauses, and writes each segment as though it were a
/// sentence of its own — so the first word comes back capitalised whether or
/// not a sentence actually started there. Gluing segments with a space turns a
/// pause to think into a stray capital in the middle of a sentence:
///
///     "mostly adhered to, however, The request was…"
///     "so that, You know they look human readable"
///
/// Every example above is from real dictation history, and every one sits on a
/// segment boundary. So the repair happens here, at the boundary, where it is
/// known to be an artefact — not as a general pass over the text, where a
/// capital after a comma is just as likely to be a name.
///
/// Deliberately leaves punctuation alone. A full stop the recogniser placed at
/// a pause is sometimes wrong ("mostly functional. With all of…"), but nothing
/// at the boundary says which ones, and a joiner that guesses would be changing
/// what the user wrote. Only the case is restored, and only when the segment
/// before it left a sentence open.
public enum SegmentJoiner {

    /// Appends `segment` to `transcript`, undoing the capital a pause put there.
    ///
    /// - Parameter vocabulary: the user's own terms, which keep the casing they
    ///   were spelled with wherever they land.
    public static func join(
        _ transcript: String,
        _ segment: String,
        vocabulary: [String] = []
    ) -> String {
        let right = segment.trimmingCharacters(in: .whitespaces)
        guard !right.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return right }

        let repaired = continuesSentence(transcript)
            ? decapitaliseOpening(of: right, context: transcript, vocabulary: vocabulary)
            : right
        return transcript + " " + repaired
    }

    /// Whether the text so far stopped mid-sentence: anything but a terminal
    /// mark or a line break.
    static func continuesSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return !".!?\n".contains(last)
    }

    /// Lowercases the segment's first word unless it is capitalised for a
    /// reason other than starting the segment.
    static func decapitaliseOpening(
        of segment: String,
        context: String,
        vocabulary: [String]
    ) -> String {
        let word = String(segment.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }))
        guard let first = word.first, first.isUppercase else { return segment }
        guard !keepsCapital(word, context: context, vocabulary: vocabulary) else { return segment }
        return first.lowercased() + segment.dropFirst()
    }

    /// The reasons a word is capitalised that a pause did not cause.
    static func keepsCapital(_ word: String, context: String, vocabulary: [String]) -> Bool {
        let lower = word.lowercased()

        // The pronoun, and its contractions.
        if lower == "i" || lower.hasPrefix("i'") || lower.hasPrefix("i’") { return true }

        // Acronyms and mixed case — "API", "SwiftUI", "iPhone" — say something
        // about the word itself, not about where it fell.
        if word.dropFirst().contains(where: \.isUppercase) { return true }

        // The user spelled it this way on purpose.
        if vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            return true
        }

        if alwaysCapitalised.contains(lower) { return true }

        // The recogniser capitalised it somewhere it had no sentence to start,
        // so it believes this is a name — "Masterful", "Mercor".
        return appearsCapitalisedMidSentence(word, in: context)
    }

    /// Weekdays and the months that are not also ordinary words. Matches the
    /// table `RuleBasedRefiner` uses, for the same reason: "may" and "march"
    /// are verbs far more often than they are dates.
    static let alwaysCapitalised: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "april", "june", "july",
        "september", "october", "november", "december",
    ]

    static func appearsCapitalisedMidSentence(_ word: String, in text: String) -> Bool {
        // Preceded by a letter, a comma or similar and a space — not a terminal
        // mark, and not the start of the text.
        let pattern = "[\\p{L}\\d,;:)\\-–—] \(NSRegularExpression.escapedPattern(for: word))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
