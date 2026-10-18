import Foundation
import MasterfulKit
import Testing
@testable import Persistence

@MainActor
@Suite("Correction log")
struct CorrectionStoreTests {

    private func dictation(_ store: HistoryStore, _ text: String) -> DictationRecord {
        store.record(
            rawTranscript: text, finalText: text, speechDuration: 5,
            applicationBundleID: "com.google.Chrome", applicationName: "Google Chrome",
            engineName: "Test", refinementMode: .rules, destination: .focusedField
        )
    }

    private let tenWords = "one two three four five six seven eight nine ten"

    @Test("Misheard words are counted per hundred watched words")
    func ratePerHundred() throws {
        let store = try HistoryStore(inMemory: true)
        let record = dictation(store, tenWords)
        store.recordCorrections(CorrectionResult(correctedText: "", edits: [
            CorrectionEdit(heard: "two", written: "too", kind: .word),
            CorrectionEdit(heard: "five.", written: "five,", kind: .punctuation),
            CorrectionEdit(heard: "eight nine ten", written: "something else entirely here", kind: .rewrite),
        ]), for: record)

        let week = try #require(store.weeklySummaries().last)
        #expect(week.watchedDictations == 1)
        #expect(week.misheardWords == 1)
        #expect(week.punctuationFixes == 1)
        #expect(week.misheardPer100 == 10)
        #expect(record.correctedText == "")
    }

    @Test("A dictation that could not be watched stays out of the rate")
    func unwatchedExcluded() throws {
        let store = try HistoryStore(inMemory: true)
        store.recordCorrections(nil, for: dictation(store, tenWords))
        let watched = dictation(store, tenWords)
        store.recordCorrections(CorrectionResult(correctedText: tenWords, edits: []), for: watched)

        let week = try #require(store.weeklySummaries().last)
        #expect(week.dictations == 2)
        #expect(week.watchedDictations == 1)
        #expect(week.misheardPer100 == 0)
    }

    @Test("No watched dictations means no rate, not a perfect one")
    func emptyWeekHasNoRate() throws {
        let store = try HistoryStore(inMemory: true)
        let weeks = store.weeklySummaries(weeks: 8)
        #expect(weeks.count == 8)
        #expect(weeks.allSatisfy { $0.misheardPer100 == nil })
    }

    @Test("Repeated fixes are grouped, most frequent first")
    func recurring() throws {
        let store = try HistoryStore(inMemory: true)
        for heard in ["paint", "Paint", "pleased"] {
            let record = dictation(store, tenWords)
            let written = heard == "pleased" ? "placed" : "page"
            store.recordCorrections(
                CorrectionResult(correctedText: "", edits: [CorrectionEdit(heard: heard, written: written, kind: .word)]),
                for: record
            )
        }
        let recurring = store.recurringCorrections(kind: .word)
        #expect(recurring.map(\.written) == ["page", "placed"])
        #expect(recurring.first?.count == 2)
    }

    @Test("Marking a fix as not a mishearing takes it out of the rate")
    func reclassify() throws {
        let store = try HistoryStore(inMemory: true)
        let record = dictation(store, tenWords)
        store.recordCorrections(
            CorrectionResult(correctedText: "", edits: [CorrectionEdit(heard: "two", written: "2", kind: .word)]),
            for: record
        )
        let correction = try #require(store.recurringCorrections().first)
        store.reclassify(correction, as: .rewrite)

        #expect(store.weeklySummaries().last?.misheardWords == 0)
        #expect(store.recurringCorrections(kind: .word).isEmpty)
    }

    @Test("Deleting a dictation deletes its corrections")
    func deleteCascades() throws {
        let store = try HistoryStore(inMemory: true)
        let record = dictation(store, tenWords)
        store.recordCorrections(
            CorrectionResult(correctedText: "", edits: [CorrectionEdit(heard: "two", written: "too", kind: .word)]),
            for: record
        )
        store.delete(record)
        #expect(store.recurringCorrections().isEmpty)
    }

    @Test("Recording again replaces, so a fix saved mid-typing does not linger")
    func recordingReplaces() throws {
        let store = try HistoryStore(inMemory: true)
        let record = dictation(store, tenWords)
        store.recordCorrections(
            CorrectionResult(correctedText: "", edits: [CorrectionEdit(heard: "tandu", written: "Th", kind: .word)]),
            for: record
        )
        store.recordCorrections(
            CorrectionResult(correctedText: "", edits: [CorrectionEdit(heard: "tandu", written: "Thando", kind: .word)]),
            for: record
        )
        #expect(store.corrections(for: record).map(\.written) == ["Thando"])
    }

    @Test("Only automatically learned terms can be taken back")
    func removeLearned() throws {
        let store = try HistoryStore(inMemory: true)
        store.addVocabulary("Th", isAutomatic: true)
        store.addVocabulary("Lerato")
        store.removeLearnedVocabulary("th")
        store.removeLearnedVocabulary("Lerato")
        #expect(store.vocabularyStrings() == ["Lerato"])
    }
}
