import Testing
@testable import MasterfulKit

@Suite("Voice commands")
struct VoiceCommandTests {
    private let parser = VoiceCommandParser()

    @Test("A command on its own produces no text")
    func standaloneCommand() {
        #expect(parser.parse("dash enter") == [.command(.enter)])
    }

    @Test("Text before a command is kept and inserted first")
    func textThenCommand() {
        #expect(parser.parse("hello there dash enter") == [
            .text("hello there"), .command(.enter),
        ])
    }

    @Test("Talking about a command does not run it")
    func describingACommandIsText() {
        // This is not hypothetical. Asking "what's the use case for dash tab"
        // fired a real Tab, moved focus out of the text field mid-sentence, and
        // sent the rest of the sentence to another window.
        #expect(parser.parse("I'm not sure what the use case for dash tab would be") == [
            .text("I'm not sure what the use case for dash tab would be"),
        ])
    }

    @Test("Only a trailing run of commands is executed")
    func onlyTrailingCommandsRun() {
        // Interleaving is given up on purpose: a command with speech after it is
        // far more likely to be someone describing it than issuing it.
        #expect(parser.parse("name dash tab email dash enter") == [
            .text("name dash tab email"), .command(.enter),
        ])
    }

    @Test("A chain of commands at the end all run")
    func trailingChain() {
        #expect(parser.parse("dash select all dash copy") == [
            .command(.selectAll), .command(.copy),
        ])
        #expect(parser.parse("draft this dash select all dash copy") == [
            .text("draft this"), .command(.selectAll), .command(.copy),
        ])
    }

    @Test("Longer command phrases win over shorter ones")
    func longestMatchWins() {
        // "delete word" must not be read as "delete" followed by the word "word".
        #expect(parser.parse("dash delete word") == [.command(.deleteWord)])
        #expect(parser.parse("dash delete") == [.command(.delete)])
        #expect(parser.parse("dash select all") == [.command(.selectAll)])
    }

    @Test("The prefix alone is ordinary speech and stays in the text")
    func prefixWithoutCommandIsText() {
        // The whole safety property: nothing is swallowed on a guess. "dash" is
        // only a command marker when a known command follows it.
        #expect(parser.parse("I'll dash to the shop") == [.text("I'll dash to the shop")])
        #expect(parser.parse("add a dash of salt") == [.text("add a dash of salt")])
    }

    @Test("A literal hyphen works as the prefix too")
    func hyphenPrefix() {
        // The recogniser sometimes writes a spoken "dash" as "-".
        #expect(parser.parse("done - enter") == [.text("done"), .command(.enter)])
    }

    @Test("Punctuation around the command is tolerated")
    func punctuationTolerated() {
        // Recognisers punctuate freely: "Dash enter." must still be a command.
        #expect(parser.parse("Dash enter.") == [.command(.enter)])
        #expect(parser.parse("that's it, dash send") == [
            .text("that's it,"), .command(.send),
        ])
    }

    @Test("Disabled commands fall back to being text")
    func disabledCommands() {
        let restricted = VoiceCommandParser(
            configuration: .init(enabledCommands: [.enter])
        )
        #expect(restricted.parse("dash paste") == [.text("dash paste")])
        #expect(restricted.parse("dash enter") == [.command(.enter)])
    }

    @Test("A custom prefix is honoured")
    func customPrefix() {
        let parser = VoiceCommandParser(configuration: .init(prefix: "computer"))
        #expect(parser.parse("computer enter") == [.command(.enter)])
        #expect(parser.parse("dash enter") == [.text("dash enter")])
    }

    @Test("Command-only transcripts are recognised as such")
    func commandOnlyDetection() {
        #expect(parser.containsOnlyCommands(parser.parse("dash enter")))
        #expect(parser.containsOnlyCommands(parser.parse("dash select all dash copy")))
        #expect(!parser.containsOnlyCommands(parser.parse("hello dash enter")))
        #expect(!parser.containsOnlyCommands(parser.parse("")))
    }

    @Test("A command mentioned mid-sentence keeps its exact wording")
    func demotedCommandKeepsWording() {
        // Reverting to text must reproduce what was said, not a normalised form.
        #expect(parser.parse("Dash Enter is the one I mean") == [
            .text("Dash Enter is the one I mean"),
        ])
    }

    @Test("Ordinary dictation is untouched")
    func plainTextUnchanged() {
        let text = "Send the invoice to the design team before Friday."
        #expect(parser.parse(text) == [.text(text)])
    }
}
