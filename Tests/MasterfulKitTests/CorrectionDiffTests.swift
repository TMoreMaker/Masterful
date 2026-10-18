import Foundation
import Testing
@testable import MasterfulKit

@Suite("Correction diff")
struct CorrectionDiffTests {

    /// A field holding `before`, then the dictation, then `after`.
    private func field(_ before: String, _ dictation: String, _ after: String = "") -> (String, NSRange) {
        let text = before + dictation + after
        return (text, NSRange(location: before.utf16.count, length: dictation.utf16.count))
    }

    @Test("A swapped word is a mishearing")
    func wordSwap() throws {
        let (baseline, span) = field("", "The simulation is pleased front and centre.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span, final: "The simulation is placed front and centre."
        ))
        #expect(result.edits == [CorrectionEdit(heard: "pleased", written: "placed", kind: .word)])
        #expect(result.correctedText == "The simulation is placed front and centre.")
    }

    @Test("Changing only punctuation or case is a punctuation fix")
    func punctuationOnly() throws {
        let (baseline, span) = field("", "The site seems to be mostly functional. With all of the controls working.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span,
            final: "The site seems to be mostly functional, with all of the controls working."
        ))
        #expect(result.edits == [CorrectionEdit(heard: "functional. With", written: "functional, with", kind: .punctuation)])
    }

    @Test("Several separate fixes are each logged")
    func severalFixes() throws {
        let (baseline, span) = field("", "The bottom of the paint is very empty and the lips of spacing shows.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span,
            final: "The bottom of the page is very empty and the lack of spacing shows."
        ))
        #expect(result.edits.map(\.heard) == ["paint", "lips"])
        #expect(result.edits.map(\.written) == ["page", "lack"])
        #expect(result.edits.allSatisfy { $0.kind == .word })
    }

    @Test("A missing word added inside the dictation counts")
    func addedWord() throws {
        let (baseline, span) = field("", "The prompt asked for translucent tube.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span, final: "The prompt asked for a translucent tube."
        ))
        #expect(result.edits == [CorrectionEdit(heard: "", written: "a", kind: .word)])
        #expect(result.edits[0].wordCount == 1)
    }

    @Test("Typing on after the dictation is not a correction")
    func typingOn() throws {
        let (baseline, span) = field("", "The site is functional.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span, final: "The site is functional. Mostly, anyway."
        ))
        #expect(result.edits.isEmpty)
    }

    @Test("Editing text before the dictation is not a correction of it")
    func editBefore() throws {
        let (baseline, span) = field("Earlier paragraph with a typo hear.\n\n", "The site is functional.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span,
            final: "Earlier paragraph with a typo here.\n\nThe site is functional."
        ))
        #expect(result.edits.isEmpty)
    }

    @Test("A dictation in the middle of a field is found and diffed in place")
    func middleOfField() throws {
        let (baseline, span) = field("Intro sentence. ", "The page has very lips of contrast.", " Closing line.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span,
            final: "Intro sentence. The page has very little contrast. Closing line."
        ))
        #expect(result.edits == [CorrectionEdit(heard: "lips of", written: "little", kind: .word)])
    }

    @Test("Rewriting most of it is a rewrite, not a run of mishearings")
    func rewrite() throws {
        let (baseline, span) = field("", "The controls bar seems bottom heavy because things sit low.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span,
            final: "The controls feel weighted toward the bottom edge overall, honestly."
        ))
        #expect(!result.edits.isEmpty)
        #expect(result.edits.allSatisfy { $0.kind == .rewrite })
    }

    @Test("A long replaced phrase is a rewrite")
    func longPhrase() {
        let edit = CorrectionDiff.classify(
            heard: ["you", "need", "to", "in"], written: ["in", "the"]
        )
        #expect(edit.kind == .rewrite)
    }

    @Test("Deleting the dictation outright is not a correction")
    func deleted() {
        let (baseline, span) = field("", "The functionality.")
        #expect(CorrectionDiff.corrections(baseline: baseline, span: span, final: "") == nil)
    }

    @Test("No change, no edits")
    func unchanged() throws {
        let (baseline, span) = field("", "All good.")
        let result = try #require(CorrectionDiff.corrections(baseline: baseline, span: span, final: baseline))
        #expect(result.edits.isEmpty)
        #expect(result.correctedText == "All good.")
    }

    @Test("Ranges are UTF-16, the unit Accessibility reports")
    func utf16Ranges() throws {
        let (baseline, span) = field("Café — ", "the paint is empty.")
        let result = try #require(CorrectionDiff.corrections(
            baseline: baseline, span: span, final: "Café — the page is empty."
        ))
        #expect(result.edits == [CorrectionEdit(heard: "paint", written: "page", kind: .word)])
    }
}
