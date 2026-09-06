import Testing
@testable import MasterfulKit

@Suite("Dictation state machine")
struct DictationSessionTests {

    @Test("A push-to-talk utterance runs the full happy path")
    func happyPath() {
        var session = DictationSession()

        var effects = session.apply(.beginListening(.pushToTalk))
        #expect(session.phase == .listening(.pushToTalk))
        #expect(effects.contains(.presentHUD))
        #expect(effects.contains(.startCapture))

        _ = session.apply(.partialTranscript("hello"))
        #expect(session.transcript == "hello")
        #expect(session.phase == .listening(.pushToTalk))

        effects = session.apply(.endListening)
        #expect(session.phase == .transcribing)
        #expect(effects.contains(.stopCapture(tail: DictationSession.captureTail)))
        #expect(effects.contains(.finalizeTranscription))

        effects = session.apply(.finalTranscript("hello there"))
        #expect(session.phase == .refining)
        #expect(effects == [.refine("hello there")])

        effects = session.apply(.refined("Hello there."))
        #expect(session.phase == .inserting)
        #expect(effects == [.insert("Hello there.")])

        let delivery = Delivery(characterCount: 12, wordCount: 2, destination: .focusedField)
        effects = session.apply(.delivered(delivery))
        #expect(session.phase == .delivered(delivery))
        #expect(effects.contains(.dismissHUD(after: DictationSession.Dwell.success)))

        _ = session.apply(.dismiss)
        #expect(session.phase == .idle)
        #expect(session.transcript.isEmpty)
    }

    @Test("The capture tail outlives the key release so trailing words survive")
    func releaseKeepsMicrophoneOpenBriefly() {
        var session = DictationSession()
        _ = session.apply(.beginListening(.pushToTalk))
        let effects = session.apply(.endListening)
        #expect(effects.contains { effect in
            if case .stopCapture(let tail) = effect { return tail > .zero }
            return false
        })
    }

    @Test("Promotion to latched only applies while still listening")
    func promotionWindow() {
        var session = DictationSession()
        _ = session.apply(.beginListening(.pushToTalk))
        _ = session.apply(.promoteToLatched)
        #expect(session.phase == .listening(.latched))

        // Once the audio is closed, a late promotion must not reopen it and
        // splice two utterances together.
        _ = session.apply(.endListening)
        _ = session.apply(.promoteToLatched)
        #expect(session.phase == .transcribing)
    }

    @Test("Silence is reported rather than inserted")
    func emptyTranscriptFails() {
        var session = DictationSession()
        _ = session.apply(.beginListening(.pushToTalk))
        _ = session.apply(.endListening)
        let effects = session.apply(.finalTranscript("   \n "))
        #expect(session.phase == .failed(.noSpeechDetected))
        #expect(!effects.contains { if case .insert = $0 { return true } else { return false } })
    }

    @Test("Cancelling mid-flight stops capture and inserts nothing")
    func cancelInsertsNothing() {
        var session = DictationSession()
        _ = session.apply(.beginListening(.pushToTalk))
        _ = session.apply(.partialTranscript("this should not be inserted"))
        let effects = session.apply(.cancel)

        #expect(session.phase == .idle)
        #expect(session.transcript.isEmpty)
        #expect(effects.contains(.cancelTranscription))
        #expect(!effects.contains { if case .insert = $0 { return true } else { return false } })
    }

    @Test("A press while a previous utterance is still resolving starts fresh")
    func midFlightRestart() {
        var session = DictationSession()
        _ = session.apply(.beginListening(.pushToTalk))
        _ = session.apply(.endListening)
        #expect(session.phase == .transcribing)

        let effects = session.apply(.beginListening(.pushToTalk))
        #expect(session.phase == .listening(.pushToTalk))
        #expect(effects.contains(.cancelTranscription))
        #expect(effects.contains(.startCapture))
        #expect(session.transcript.isEmpty)
    }

    @Test("A late volatile result is kept but does not resurrect the session")
    func lateVolatileResult() {
        var session = DictationSession()
        _ = session.apply(.beginListening(.pushToTalk))
        _ = session.apply(.endListening)
        _ = session.apply(.partialTranscript("trailing words"))
        #expect(session.phase == .transcribing)
        #expect(session.transcript == "trailing words")
    }

    @Test("Blocked sessions never open the microphone")
    func blockedNeverCaptures() {
        var session = DictationSession()
        let effects = session.apply(.blocked(.secureInputActive))
        #expect(session.phase == .blocked(.secureInputActive))
        #expect(!effects.contains(.startCapture))
    }
}
