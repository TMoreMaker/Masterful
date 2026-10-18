import Foundation

/// Decides which fixes should teach the recogniser a word.
///
/// When you correct "tandu" to "Thando", the point is that it never has to be
/// corrected again — so the corrected spelling goes into the vocabulary, which
/// biases the recogniser towards it from the next dictation.
///
/// Only words the dictionary does not know are learned: names, products,
/// jargon. "be" → "the" is a real fix, but biasing the recogniser towards
/// "the" does nothing for it, and every ordinary word added dilutes the bias
/// the real names get. The dictionary check is injected, so this stays free of
/// AppKit and the judgement can be tested without the system spellchecker.
public struct VocabularyLearner: Sendable {
    /// A term longer than this is a phrase, not a name.
    public static let longestTerm = 3

    private let isDictionaryWord: @Sendable (String) -> Bool

    public init(isDictionaryWord: @escaping @Sendable (String) -> Bool) {
        self.isDictionaryWord = isDictionaryWord
    }

    /// The terms these fixes should add to the vocabulary, in order, once each.
    public func terms(from edits: [CorrectionEdit]) -> [String] {
        var seen = Set<String>()
        return edits.compactMap(term(from:)).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The corrected spelling, if this fix taught a word worth learning.
    public func term(from edit: CorrectionEdit) -> String? {
        guard edit.kind == .word else { return nil }
        let term = edit.written.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= Self.longestTerm,
              term.count >= 2, term.contains(where: \.isLetter)
        else { return nil }

        let unknown = words.contains { word in
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            // Internal capitals — "SwiftUI", "iPhone" — are a term whatever the
            // dictionary says about its pieces.
            if bare.dropFirst().contains(where: \.isUppercase) { return true }
            return bare.contains(where: \.isLetter) && !isDictionaryWord(bare)
        }
        return unknown ? term : nil
    }
}
