import Testing
@testable import MasterfulKit

@Suite("Vocabulary learner")
struct VocabularyLearnerTests {
    /// A stand-in for the system spellchecker.
    private let learner = VocabularyLearner { word in
        ["the", "page", "placed", "tender", "front", "mercy", "swift"].contains(word.lowercased())
    }

    private func word(_ heard: String, _ written: String) -> CorrectionEdit {
        CorrectionEdit(heard: heard, written: written, kind: .word)
    }

    @Test("A name the dictionary does not know is learned")
    func nameIsLearned() {
        #expect(learner.term(from: word("tandu", "Thando")) == "Thando")
        #expect(learner.term(from: word("tender", "Thando,")) == "Thando")
        #expect(learner.term(from: word("figure", "Figma")) == "Figma")
    }

    @Test("An ordinary word is not learned")
    func ordinaryWordIsNot() {
        #expect(learner.term(from: word("be", "the")) == nil)
        #expect(learner.term(from: word("paint", "page")) == nil)
    }

    @Test("Mixed case is a term even when its pieces are words")
    func mixedCase() {
        #expect(learner.term(from: word("swift you eye", "SwiftUI")) == "SwiftUI")
    }

    @Test("Punctuation fixes, rewrites and deletions teach nothing")
    func otherKinds() {
        #expect(learner.term(from: CorrectionEdit(heard: "Thando.", written: "Thando,", kind: .punctuation)) == nil)
        #expect(learner.term(from: CorrectionEdit(heard: "a b c d", written: "Thando said this", kind: .rewrite)) == nil)
        #expect(learner.term(from: word("tandu", "")) == nil)
    }

    @Test("Long phrases and numbers are not terms")
    func phrasesAndNumbers() {
        #expect(learner.term(from: word("x", "Thando and Lerato went")) == nil)
        #expect(learner.term(from: word("for", "4")) == nil)
    }

    @Test("Each term is learned once")
    func deduplicated() {
        #expect(learner.terms(from: [word("tandu", "Thando"), word("tando", "thando"), word("be", "the")]) == ["Thando"])
    }
}
