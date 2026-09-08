import MasterfulKit
import Foundation
import Testing
@testable import Refinement

@Suite("Rule-based clean-up")
struct RuleBasedRefinerTests {
    private let sut = RuleBasedRefiner()

    @Test("Disfluencies are removed without disturbing the surrounding words")
    func removesFillers() async {
        let output = await sut.refine("um so I think uh we should ship it", context: .none)
        #expect(output == "So I think we should ship it")
    }

    @Test("Words that merely sound like fillers are left alone")
    func preservesMeaningfulWords() async {
        // "Like", "actually" and "I mean" are commonly called filler words, but
        // removing them changes register and sometimes meaning. A dictation tool
        // that edits your voice unasked is not one you can trust.
        let input = "I actually like the way you framed it, I mean it"
        let output = await sut.refine(input, context: .none)
        #expect(output.contains("actually"))
        #expect(output.contains("like"))
        #expect(output.contains("I mean"))
    }

    @Test("Structural commands become real line breaks")
    func structuralCommands() async {
        let output = await sut.refine("first point new line second point", context: .none)
        #expect(output == "First point\nSecond point")
    }

    @Test("Structural phrases inside ordinary words survive")
    func structuralCommandsAreWordBounded() async {
        let output = await sut.refine("we reviewed the new lineup today", context: .none)
        #expect(output == "We reviewed the new lineup today")
    }

    @Test("Stutters collapse")
    func collapsesStutters() async {
        let output = await sut.refine("send send the the report", context: .none)
        #expect(output == "Send the report")
    }

    @Test("Sentences are capitalised")
    func capitalises() async {
        let output = await sut.refine("hello there. how are you? fine!", context: .none)
        #expect(output == "Hello there. How are you? Fine!")
    }

    @Test("Custom vocabulary keeps its own casing")
    func vocabularyCasing() async {
        let context = RefinementContext(vocabulary: ["SwiftUI", "Tlotliso"])
        let output = await sut.refine("swiftui suits tlotliso well", context: context)
        #expect(output == "SwiftUI suits Tlotliso well")
    }

    @Test("The pronoun I is always capitalised, contractions included")
    func capitalisesPronoun() async {
        let output = await sut.refine("so i think i'm going and i'll tell them", context: .none)
        #expect(output == "So I think I'm going and I'll tell them")
    }

    @Test("Weekdays and unambiguous months are capitalised")
    func capitalisesDates() async {
        let output = await sut.refine("moving it to thursday the third of december", context: .none)
        #expect(output == "Moving it to Thursday the third of December")
    }

    @Test("Month names that are also ordinary words are left alone")
    func doesNotCapitaliseAmbiguousMonths() async {
        // "we may ship" must never become "we May ship". A clean-up pass that is
        // wrong occasionally is worse than one that is conservative.
        let output = await sut.refine("we may ship in spring and march to the deadline", context: .none)
        // The leading word is capitalised by sentence casing, as it should be;
        // what matters is that "may" and "march" mid-sentence are untouched.
        #expect(output == "We may ship in spring and march to the deadline")
    }

    @Test("Repeated phrases collapse, not just repeated words")
    func collapsesPhraseStutters() async {
        // People restart phrases, not single words: "can you can you" is the
        // common disfluency, and a word-level pass cannot see it.
        let output = await sut.refine(
            "can you can you send me the the invoice", context: .none
        )
        #expect(output == "Can you send me the invoice")
    }

    @Test("Stutters separated by commas collapse too")
    func collapsesCommaSeparatedStutters() async {
        // Straight from a real transcript. The recogniser punctuates hesitation,
        // so "the the the" arrives as "the, the, the" and a whitespace-only
        // pattern misses every occurrence.
        let output = await sut.refine(
            "an issue with the, the, the, the detection", context: .none
        )
        #expect(output == "An issue with the detection")
    }

    @Test("Code context keeps its casing untouched")
    func codeProfileIsNotCapitalised() async {
        let context = RefinementContext(profile: .code)
        let output = await sut.refine("um git checkout i think monday branch", context: context)
        #expect(output == "git checkout i think monday branch")
    }

    @Test("Removing a filler does not strand punctuation")
    func noStrandedPunctuation() async {
        let output = await sut.refine("well um, that is the plan", context: .none)
        #expect(!output.contains(" ,"))
        #expect(!output.contains("  "))
    }
}

@Suite("Transcript guard")
struct TranscriptGuardTests {

    @Test("A faithful tidy-up is accepted")
    func acceptsFaithfulEdit() {
        #expect(TranscriptGuard.isTrustworthy(
            original: "so um we should ship the release on friday",
            candidate: "So we should ship the release on Friday."
        ))
    }

    @Test("A hallucinated replacement is rejected")
    func rejectsHallucination() {
        // The failure mode that actually matters: fluent text the user never said.
        #expect(!TranscriptGuard.isTrustworthy(
            original: "so um we should ship the release on friday",
            candidate: "The quarterly earnings call is scheduled for next Tuesday."
        ))
    }

    @Test("Truncation is rejected")
    func rejectsTruncation() {
        #expect(!TranscriptGuard.isTrustworthy(
            original: "please add the invoice totals to the spreadsheet before the meeting",
            candidate: "Please add the invoice totals."
        ))
    }

    @Test("A model answering instead of editing is rejected")
    func rejectsInstructionFollowing() {
        #expect(!TranscriptGuard.isTrustworthy(
            original: "clean up this sentence for me",
            candidate: "Sure! Here is your cleaned-up text, formatted nicely for you to use."
        ))
    }

    @Test("Empty output is rejected")
    func rejectsEmpty() {
        #expect(!TranscriptGuard.isTrustworthy(original: "hello there", candidate: "   "))
    }
}

@Suite("Refinement pipeline")
struct RefinementPipelineTests {

    private struct SlowRefiner: Refiner {
        func refine(_ text: String, context: RefinementContext) async -> String {
            try? await Task.sleep(for: .seconds(5))
            return "never arrives"
        }
    }

    private struct HallucinatingRefiner: Refiner {
        func refine(_ text: String, context: RefinementContext) async -> String {
            "Completely unrelated sentence about something else entirely."
        }
    }

    @Test("A slow model never delays the insert")
    func budgetIsEnforced() async {
        let pipeline = RefinementPipeline(model: SlowRefiner(), budget: .milliseconds(50))
        let output = await pipeline.refine("um hello there", context: .none)
        #expect(output == "Hello there")
    }

    @Test("The budget bounds wall-clock time, not just the returned value")
    func budgetActuallyReturnsEarly() async {
        // The bug this pins: racing inside a `withTaskGroup` returns the correct
        // fallback text while still waiting for the slow task, because a task
        // group awaits all its children. Asserting only on the output passes
        // happily against a deadline that enforces nothing — so assert the clock.
        let pipeline = RefinementPipeline(model: SlowRefiner(), budget: .milliseconds(50))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await pipeline.refine("um hello there", context: .none)
        }
        // SlowRefiner sleeps for 5 seconds. Anything near that means the
        // deadline is decorative.
        #expect(elapsed < .milliseconds(1_000))
    }

    @Test("Untrustworthy model output is discarded in favour of the rules")
    func guardRailApplies() async {
        let pipeline = RefinementPipeline(model: HallucinatingRefiner())
        let output = await pipeline.refine("um hello there", context: .none)
        #expect(output == "Hello there")
    }
}

@Suite("Guard against invented words")
struct InventedWordTests {

    @Test("A model repairing a garbled sentence into fluent prose is rejected")
    func rejectsRepair() {
        // Taken from a real dictation: the recogniser produced a broken phrase
        // and the model "helpfully" rewrote it into something the speaker never
        // said. Formatting is the job; repairing is not.
        #expect(!TranscriptGuard.isTrustworthy(
            original: "the mouse i have added the most hot key but it seems broken",
            candidate: "The mouse I have added is the main hotkey control, but it appears to be broken now."
        ))
    }

    @Test("A homophone correction is still allowed")
    func allowsHomophoneFix() {
        // "their" → "there" introduces a token that was not in the input, so a
        // zero-tolerance rule would reject a fix that is genuinely wanted.
        #expect(TranscriptGuard.isTrustworthy(
            original: "put the invoice over their on the desk before the meeting starts",
            candidate: "Put the invoice over there on the desk before the meeting starts."
        ))
    }

    @Test("Ordinary punctuation and casing changes invent nothing")
    func allowsFormatting() {
        #expect(TranscriptGuard.isTrustworthy(
            original: "i spoke to the team this morning they want it redone",
            candidate: "I spoke to the team this morning. They want it redone."
        ))
    }
}

@Suite("Rewrite guard")
struct RewriteGuardTests {

    /// The utterance that prompted registers to exist. Under the fidelity bounds
    /// this fails every check; under the rewrite bounds it must pass, because it
    /// is exactly what the user asked the tool to produce.
    private static let spoken = """
        I'm not a fan of the shadows. I think those should be omitted from the \
        design, and I think that is a sort of primary rule. Instead of green, \
        let's go with like a white yeah, like a white, yeah, a white look and \
        feel. I want it to be slick, like similar to Apple.
        """

    @Test("A faithful compression is accepted for a writing register")
    func acceptsCompression() {
        let written = "Drop the shadows — treat that as a primary rule. Use white instead of green. Make it slick, similar to Apple."
        #expect(TranscriptGuard.isTrustworthy(
            original: Self.spoken, candidate: written, profile: .technical
        ))
        // …and is still correctly refused where fidelity was promised.
        #expect(!TranscriptGuard.isTrustworthy(
            original: Self.spoken, candidate: written, profile: .verbatim
        ))
    }

    @Test("A rewrite that grew is rejected as an answer rather than a draft")
    func rejectsGrowth() {
        #expect(!TranscriptGuard.isTrustworthy(
            original: "remove the shadows from the design",
            candidate: "Shadows can add depth to an interface, but flat design has become the dominant idiom, so removing them is a reasonable choice for a modern look.",
            profile: .technical
        ))
    }

    @Test("A short hallucination cannot hide inside the short-utterance slack")
    func rejectsShortHallucination() {
        #expect(!TranscriptGuard.isTrustworthy(
            original: "hello there",
            candidate: "Completely unrelated sentence about something else entirely.",
            profile: .informal
        ))
    }

    @Test("Punctuating a short message is allowed to grow it slightly")
    func allowsPunctuation() {
        #expect(TranscriptGuard.isTrustworthy(
            original: "yeah sounds good to me",
            candidate: "Yeah, sounds good to me",
            profile: .informal
        ))
    }

    @Test("Summarising away most of the content is rejected")
    func rejectsSummary() {
        #expect(!TranscriptGuard.isTrustworthy(
            original: Self.spoken, candidate: "Change the design.", profile: .technical
        ))
    }

    @Test("A rewrite that loses or alters a number is rejected however well it reads")
    func preservesNumbers() {
        let spoken = "so the plot is 2200 rand for half a hectare and we farm 120 hectares in total"
        #expect(!TranscriptGuard.isTrustworthy(
            original: spoken,
            candidate: "The plot costs 2200 rand per half hectare; we farm 100 hectares.",
            profile: .technical
        ))
        #expect(TranscriptGuard.isTrustworthy(
            original: spoken,
            candidate: "The plot is 2200 rand per half hectare. We farm 120 hectares.",
            profile: .technical
        ))
    }

    @Test("Grouped and ungrouped numbers are the same number")
    func numberGrouping() {
        #expect(TranscriptGuard.isTrustworthy(
            original: "the invoice came to 18,000 rand which is a lot of money for this",
            candidate: "The invoice was 18000 rand.",
            profile: .technical
        ))
    }
}

@Suite("Formatting profile migration")
struct ProfileMigrationTests {

    /// Settings written before registers existed must still load. Losing them
    /// silently resets every per-app rule the user made.
    @Test("Legacy profile names decode onto registers")
    func decodesLegacyNames() throws {
        let json = #"{"a":"prose","b":"message","c":"technical","d":"code"}"#
        let decoded = try JSONDecoder().decode(
            [String: FormattingProfile].self, from: Data(json.utf8)
        )
        #expect(decoded["a"] == .formal)
        #expect(decoded["b"] == .informal)
        #expect(decoded["c"] == .technical)
        #expect(decoded["d"] == .code)
    }

    @Test("Only the writing registers rewrite phrasing or use lists")
    func capabilities() {
        #expect(FormattingProfile.technical.rewritesPhrasing)
        #expect(FormattingProfile.formal.rewritesPhrasing)
        #expect(FormattingProfile.informal.rewritesPhrasing)
        #expect(!FormattingProfile.code.rewritesPhrasing)
        #expect(!FormattingProfile.verbatim.rewritesPhrasing)

        // A bulleted list in a text message reads as a memo.
        #expect(FormattingProfile.technical.mayUseLists)
        #expect(!FormattingProfile.informal.mayUseLists)
    }
}
