import Foundation
import MasterfulKit

/// Shared spoken-language tables.
public enum SpokenText {
    /// Genuine disfluencies only.
    ///
    /// Deliberately excludes "like", "you know", "I mean" and "actually". They
    /// are often called filler words, but removing them changes register and
    /// sometimes meaning, and a dictation tool that edits your voice without
    /// being asked is not one you can trust with a sentence that matters.
    public static let fillerWords: Set<String> = [
        "um", "uh", "umm", "uhh", "erm", "ahh", "mmm", "hmm", "eh",
    ]

    /// Commands the user speaks aloud to produce structure.
    ///
    /// Kept to phrases with no plausible literal reading in the middle of
    /// dictation — "new paragraph" is a command, but a bare "period" is a word
    /// people actually say, so it is not in this table.
    public static let structuralCommands: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("next line", "\n"),
    ]
}

/// Deterministic clean-up: no model, no network, no surprises.
///
/// Runs before any AI stage and is the entirety of `RefinementMode.rules`. Every
/// transformation here is reversible in the user's head — they can predict what
/// it will do, which is the property that makes it safe to leave on by default.
public struct RuleBasedRefiner: Refiner {

    public struct Options: Sendable, Equatable {
        public var removeFillerWords: Bool = true
        public var applyStructuralCommands: Bool = true
        public var collapseStutters: Bool = true
        public var capitaliseSentences: Bool = true
        /// The pronoun "I", weekdays, and unambiguous month names.
        public var capitaliseCommonProperNouns: Bool = true

        public init() {}
    }

    private let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    public func refine(_ text: String, context: RefinementContext) async -> String {
        // Verbatim means verbatim. Whitespace normalisation only.
        guard context.profile != .verbatim else {
            return Self.normaliseWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // In an editor or a terminal, sentence casing is not tidying — it is
        // corruption. `camelCase` becomes `CamelCase` and a shell command stops
        // working. So the destination narrows what the rules are allowed to do.
        var options = self.options
        if context.profile == .code {
            options.capitaliseSentences = false
        }

        var result = text

        if options.applyStructuralCommands {
            result = Self.applyStructuralCommands(to: result)
        }
        if options.removeFillerWords {
            result = Self.removeFillers(from: result)
        }
        if options.collapseStutters {
            result = Self.collapseStutters(in: result)
        }
        result = Self.normaliseWhitespace(result)
        if options.capitaliseSentences {
            result = Self.capitaliseSentences(result)
        }
        if options.capitaliseCommonProperNouns, context.profile != .code {
            result = Self.capitaliseCommonProperNouns(result)
        }
        result = Self.restoreVocabularyCasing(result, vocabulary: context.vocabulary)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Steps

    static func applyStructuralCommands(to text: String) -> String {
        var result = text
        for command in SpokenText.structuralCommands {
            // Word-bounded so "a new lineup" survives intact.
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: command.phrase))\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: command.replacement,
                options: .regularExpression
            )
        }
        return result
    }

    static func removeFillers(from text: String) -> String {
        let alternatives = SpokenText.fillerWords
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Consume the trailing separator too, so removal does not leave a gap
        // or a comma stranded against the previous word.
        let pattern = "(?i)(?<![\\w'])(?:\(alternatives))[,]?(?:\\s+|$)"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// "the the report" → "the report", and "can you can you send" → "can you
    /// send". Only exact adjacent repeats.
    ///
    /// Phrases are collapsed before single words because restarting a phrase is
    /// the more common disfluency in speech — people repeat "can you", not "can"
    /// — and the single-word pass cannot see it.
    static func collapseStutters(in text: String) -> String {
        // Two- and three-word phrases repeated back to back.
        let phrasesCollapsed = text.replacingOccurrences(
            of: "(?i)\\b((?:\\w+[,;:]?\\s+){1,2}\\w+)[,;:]?\\s+\\1\\b",
            with: "$1",
            options: .regularExpression
        )
        // The separator must allow punctuation, not just whitespace. A hesitant
        // speaker is transcribed as "the, the, the, the detection" — commas and
        // all — and a whitespace-only pattern silently misses every one of them.
        return phrasesCollapsed.replacingOccurrences(
            of: "(?i)\\b(\\w+)([,;:]?\\s+\\1\\b)+",
            with: "$1",
            options: .regularExpression
        )
    }

    /// Words English always capitalises, regardless of position.
    ///
    /// Deliberately excludes March, May and August. They are month names and
    /// also ordinary words — "we may ship on the first" must not become "we May
    /// ship" — and a clean-up pass that is wrong even occasionally is worse than
    /// one that is conservative. Genuine proper nouns belong in the user's
    /// custom vocabulary, which is exactly what that feature is for.
    private static let alwaysCapitalised = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "april", "june", "july",
        "september", "october", "november", "december",
    ]

    static func capitaliseCommonProperNouns(_ text: String) -> String {
        // The pronoun. The word boundary after "i" also catches "i'm", "i'll"
        // and "i've", since an apostrophe is not a word character.
        var result = text.replacingOccurrences(
            of: "\\bi\\b", with: "I", options: .regularExpression
        )
        for word in alwaysCapitalised {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(word)\\b",
                with: word.prefix(1).uppercased() + word.dropFirst(),
                options: .regularExpression
            )
        }
        return result
    }

    static func normaliseWhitespace(_ text: String) -> String {
        text
            // Space before punctuation is an artefact of removing a filler.
            .replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static func capitaliseSentences(_ text: String) -> String {
        var characters = Array(text)
        var capitaliseNext = true
        for index in characters.indices {
            let character = characters[index]
            if capitaliseNext, character.isLetter {
                characters[index] = Character(character.uppercased())
                capitaliseNext = false
            } else if character == "." || character == "!" || character == "?" || character == "\n" {
                capitaliseNext = true
            }
        }
        return String(characters)
    }

    /// Sentence casing will have flattened "SwiftUI" to "Swiftui"; put the
    /// user's own vocabulary back the way they spelled it.
    static func restoreVocabularyCasing(_ text: String, vocabulary: [String]) -> String {
        guard !vocabulary.isEmpty else { return text }
        var result = text
        for term in vocabulary where !term.isEmpty {
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: term,
                options: .regularExpression
            )
        }
        return result
    }
}
