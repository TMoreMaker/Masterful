import Testing
@testable import MasterfulKit

@Suite("Segment joiner")
struct SegmentJoinerTests {

    @Test("A pause after a comma does not start a new sentence")
    func capitalAfterCommaIsLowered() {
        // Real dictation, split where the speaker paused.
        #expect(SegmentJoiner.join(
            "The prompt was mostly adhered to, however,",
            "The request was to use a translucent frosted plastic appearance."
        ) == "The prompt was mostly adhered to, however, the request was to use a translucent frosted plastic appearance.")
    }

    @Test("A pause with no punctuation at all is mended too")
    func capitalAfterBareWordIsLowered() {
        #expect(SegmentJoiner.join("The controls bar in simulation", "Seems bottom heavy.")
            == "The controls bar in simulation seems bottom heavy.")
    }

    @Test("A segment after a full stop keeps its capital")
    func newSentenceKeepsCapital() {
        #expect(SegmentJoiner.join("The site is functional.", "The copy button does not work.")
            == "The site is functional. The copy button does not work.")
        #expect(SegmentJoiner.join("Does it work?", "Not quite.") == "Does it work? Not quite.")
    }

    @Test("The full stop the recogniser placed is left alone")
    func punctuationIsNotChanged() {
        // Sometimes wrong, but nothing at the boundary says which — so the
        // joiner does not guess at the user's punctuation.
        #expect(SegmentJoiner.join("The site seems to be mostly functional.", "With all of the controls working.")
            == "The site seems to be mostly functional. With all of the controls working.")
    }

    @Test("The pronoun stays capitalised", arguments: ["I", "I'm", "I’ve"])
    func pronounKeepsCapital(word: String) {
        #expect(SegmentJoiner.join("and then,", "\(word) noticed it.") == "and then, \(word) noticed it.")
    }

    @Test("Acronyms and mixed case are not flattened", arguments: ["API", "SwiftUI", "UI"])
    func acronymsKeepCase(word: String) {
        #expect(SegmentJoiner.join("the problem is the", "\(word) layer.") == "the problem is the \(word) layer.")
    }

    @Test("Vocabulary terms keep their casing")
    func vocabularyKeepsCase() {
        #expect(SegmentJoiner.join("when I list the issues for", "Figma they come back.", vocabulary: ["Figma"])
            == "when I list the issues for Figma they come back.")
    }

    @Test("Weekdays keep their capital")
    func weekdaysKeepCapital() {
        #expect(SegmentJoiner.join("we can meet on", "Thursday instead.") == "we can meet on Thursday instead.")
    }

    @Test("A word the recogniser already treats as a name keeps its capital")
    func knownNameKeepsCapital() {
        #expect(SegmentJoiner.join("I use Masterful a lot, and", "Masterful mostly works.")
            == "I use Masterful a lot, and Masterful mostly works.")
    }

    @Test("A capital that only ever started a sentence is not taken as a name")
    func sentenceStartIsNotAName() {
        #expect(SegmentJoiner.join("The page is empty. The layout is off, and", "The spacing is tight.")
            == "The page is empty. The layout is off, and the spacing is tight.")
    }

    @Test("Empty pieces join cleanly")
    func emptyPieces() {
        #expect(SegmentJoiner.join("", "  Hello.") == "Hello.")
        #expect(SegmentJoiner.join("Hello.", "   ") == "Hello.")
    }

}
