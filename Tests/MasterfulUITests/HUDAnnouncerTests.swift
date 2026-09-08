import MasterfulKit
import Testing
@testable import MasterfulUI

@Suite("The spoken island")
@MainActor
struct HUDAnnouncerTests {

    @Test("The states that resolve themselves stay silent")
    func silentPhases() {
        // Narrating each of these would turn a two-word answer into a
        // paragraph — the spoken equivalent of the live transcript the island
        // already refuses to draw.
        #expect(HUDAnnouncer.spokenText(for: .idle) == nil)
        #expect(HUDAnnouncer.spokenText(for: .transcribing) == nil)
        #expect(HUDAnnouncer.spokenText(for: .refining) == nil)
        #expect(HUDAnnouncer.spokenText(for: .inserting) == nil)
    }

    @Test("Latched listening says how to stop, because that is what differs")
    func listeningModes() {
        #expect(HUDAnnouncer.spokenText(for: .listening(.pushToTalk)) == "Listening")

        let latched = HUDAnnouncer.spokenText(for: .listening(.latched))
        #expect(latched?.contains("continuously") == true)
        #expect(latched?.contains("Press again") == true)
    }

    @Test("Text that went to the clipboard says so, and says what to do")
    func clipboardIsAnnounced() {
        // The case this whole thing exists for. A sighted user gets a card;
        // without this line a VoiceOver user concludes the dictation failed
        // while their sentence sits unmentioned on the clipboard.
        let spoken = HUDAnnouncer.spokenText(for: .delivered(
            Delivery(characterCount: 90, wordCount: 18, destination: .clipboard)
        ))
        #expect(spoken?.contains("18 words") == true)
        #expect(spoken?.contains("clipboard") == true)
        #expect(spoken?.contains("Command V") == true)
    }

    @Test("A clean insertion is reported briefly")
    func insertedIsAnnounced() {
        #expect(HUDAnnouncer.spokenText(for: .delivered(
            Delivery(characterCount: 44, wordCount: 9, destination: .focusedField)
        )) == "9 words inserted")

        #expect(HUDAnnouncer.spokenText(for: .delivered(
            Delivery(characterCount: 4, wordCount: 1, destination: .focusedField)
        )) == "1 word inserted")
    }

    @Test("A dictation that was only spoken commands names them, not a word count")
    func commandOnlyDictation() {
        let spoken = HUDAnnouncer.spokenText(for: .delivered(
            Delivery(characterCount: 0, wordCount: 0, destination: .focusedField,
                     commandSummary: "Select all, then Copy")
        ))
        #expect(spoken == "Select all, then Copy")
    }

    @Test("Failures carry their remedy, not just their name")
    func failuresCarryTheRemedy() {
        let spoken = HUDAnnouncer.spokenText(for: .failed(.noSpeechDetected))
        #expect(spoken?.contains("Didn't catch that") == true)
        #expect(spoken?.contains("Hold the key") == true)
    }

    @Test("The refusal explains itself — silence here reads as a broken app")
    func blockedIsAnnounced() {
        let spoken = HUDAnnouncer.spokenText(for: .blocked(.secureInputActive))
        #expect(spoken?.contains("Password field") == true)
        #expect(spoken?.contains("Leave the field") == true)
    }

    @Test("Symbols a screen reader mangles are rewritten into words")
    func symbolsAreSpokenAsWords() {
        // ⌘ is announced as "place of interest sign"; → is skipped in silence,
        // which turns a settings path into an unnavigable run of words.
        let permission = HUDAnnouncer.spokenText(for: .failed(.microphonePermissionDenied))
        #expect(permission?.contains("→") == false)
        #expect(permission?.contains(", then ") == true)

        let insertion = HUDAnnouncer.spokenText(for: .failed(.insertionFailed("x")))
        #expect(insertion?.contains("⌘") == false)
        #expect(insertion?.contains("Command V") == true)
    }
}

@Suite("When the island opens")
struct HUDPresentationTests {

    @Test("Everything that resolves itself stays a bar")
    func compactPhases() {
        #expect(DictationPhase.idle.hudPresentation == .compact)
        #expect(DictationPhase.listening(.pushToTalk).hudPresentation == .compact)
        #expect(DictationPhase.listening(.latched).hudPresentation == .compact)
        #expect(DictationPhase.transcribing.hudPresentation == .compact)
        #expect(DictationPhase.refining.hudPresentation == .compact)
        #expect(DictationPhase.inserting.hudPresentation == .compact)
    }

    @Test("Anything the user has to read opens the card")
    func expandedPhases() {
        #expect(DictationPhase.failed(.noSpeechDetected).hudPresentation == .expanded)
        #expect(DictationPhase.blocked(.secureInputActive).hudPresentation == .expanded)
    }

    @Test("A delivery opens only when the text is not where the user was looking")
    func deliveryDependsOnDestination() {
        // The rule the whole HUD is built on: expand when, and only when, there
        // is something the user has to act on.
        #expect(DictationPhase.delivered(
            Delivery(characterCount: 44, wordCount: 9, destination: .focusedField)
        ).hudPresentation == .compact)

        #expect(DictationPhase.delivered(
            Delivery(characterCount: 44, wordCount: 9, destination: .clipboard)
        ).hudPresentation == .expanded)
    }
}
