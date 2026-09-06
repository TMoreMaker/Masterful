import Foundation
import MasterfulKit
import Testing
@testable import Persistence

@MainActor
@Suite("History store")
struct HistoryStoreTests {

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(inMemory: true)
    }

    @Test("Recording a dictation derives its own word and character counts")
    func recordsDerivedCounts() throws {
        let store = try makeStore()
        let record = store.record(
            rawTranscript: "um hello there world",
            finalText: "Hello there world",
            speechDuration: 6,
            applicationBundleID: "com.apple.mail",
            applicationName: "Mail",
            engineName: "Test",
            refinementMode: .rules,
            destination: .focusedField
        )
        #expect(record.wordCount == 3)
        #expect(record.characterCount == 17)
        #expect(!record.wentToClipboard)
        #expect(store.recent().count == 1)
    }

    @Test("Speaking pace ignores implausibly short utterances")
    func pacePlausibility() throws {
        let store = try makeStore()
        // A sub-second clip would otherwise report hundreds of words a minute
        // and poison the average.
        let blip = store.record(
            rawTranscript: "hi", finalText: "Hi", speechDuration: 0.3,
            applicationBundleID: nil, applicationName: nil,
            engineName: "Test", refinementMode: .rules, destination: .focusedField
        )
        #expect(blip.wordsPerMinute == 0)

        let real = store.record(
            rawTranscript: "", finalText: String(repeating: "word ", count: 30),
            speechDuration: 60,
            applicationBundleID: nil, applicationName: nil,
            engineName: "Test", refinementMode: .rules, destination: .focusedField
        )
        #expect(real.wordsPerMinute == 30)
    }

    @Test("Search matches inserted text and falls back to everything when empty")
    func search() throws {
        let store = try makeStore()
        for text in ["Ship the release", "Buy milk", "Release notes draft"] {
            store.record(
                rawTranscript: text, finalText: text, speechDuration: 5,
                applicationBundleID: nil, applicationName: nil,
                engineName: "Test", refinementMode: .rules, destination: .focusedField
            )
        }
        #expect(store.search("release").count == 2)
        #expect(store.search("").count == 3)
    }

    @Test("Vocabulary de-duplicates regardless of case")
    func vocabularyDeduplication() throws {
        let store = try makeStore()
        #expect(store.addVocabulary("SwiftUI"))
        // Both spellings bias the recogniser identically, so the second is noise.
        #expect(!store.addVocabulary("swiftui"))
        #expect(!store.addVocabulary("   "))
        #expect(store.vocabularyStrings() == ["SwiftUI"])
    }

    @Test("Stats aggregate across records")
    func stats() throws {
        let store = try makeStore()
        // 50 words in 20 seconds is 150 wpm — an ordinary speaking pace.
        let sentence = Array(repeating: "word", count: 50).joined(separator: " ")
        for _ in 0..<3 {
            store.record(
                rawTranscript: "", finalText: sentence, speechDuration: 20,
                applicationBundleID: nil, applicationName: nil,
                engineName: "Test", refinementMode: .rules, destination: .focusedField
            )
        }
        let stats = store.stats()
        #expect(stats.sessionCount == 3)
        #expect(stats.totalWords == 150)
        #expect(stats.totalSpeechTime == 60)
        // 150 words would take 225s to type at 40 wpm, against 60s spoken.
        #expect(abs(stats.estimatedTimeSaved - 165) < 0.001)
    }

    @Test("Speaking slower than typing reports no time saved, never negative")
    func timeSavedIsClamped() throws {
        let store = try makeStore()
        // Five words laboured over for 90 seconds is genuinely slower than
        // typing them. The honest answer is zero, not a negative number.
        store.record(
            rawTranscript: "", finalText: "one two three four five",
            speechDuration: 90,
            applicationBundleID: nil, applicationName: nil,
            engineName: "Test", refinementMode: .rules, destination: .focusedField
        )
        #expect(store.stats().estimatedTimeSaved == 0)
    }
}

@Suite("Streak calculation")
struct StreakTests {
    private let calendar = Calendar.current

    private func daysAgo(_ count: Int) -> Date {
        calendar.date(byAdding: .day, value: -count, to: Date())!
    }

    @Test("Consecutive days count up")
    func consecutive() {
        #expect(HistoryStore.streak(from: [daysAgo(0), daysAgo(1), daysAgo(2)]) == 3)
    }

    @Test("A gap ends the streak")
    func gap() {
        #expect(HistoryStore.streak(from: [daysAgo(0), daysAgo(2), daysAgo(3)]) == 1)
    }

    @Test("Not having dictated yet today does not reset the streak")
    func todayNotRequired() {
        // Otherwise the number would drop to zero every morning and climb back
        // after the first dictation, which is not what a streak means.
        #expect(HistoryStore.streak(from: [daysAgo(1), daysAgo(2)]) == 2)
    }

    @Test("A stale streak is over")
    func stale() {
        #expect(HistoryStore.streak(from: [daysAgo(5), daysAgo(6)]) == 0)
    }

    @Test("No history is no streak")
    func empty() {
        #expect(HistoryStore.streak(from: []) == 0)
    }
}
