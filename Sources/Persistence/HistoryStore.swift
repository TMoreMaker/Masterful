import Foundation
import MasterfulKit
import SwiftData

/// Aggregate figures for the stats view.
public struct DictationStats: Sendable, Equatable {
    public var sessionCount: Int = 0
    public var totalWords: Int = 0
    public var totalSpeechTime: TimeInterval = 0
    public var averageWordsPerMinute: Double = 0
    /// Days in a row with at least one dictation, counting back from today.
    public var currentStreak: Int = 0

    /// Rough time saved versus typing the same words by hand.
    ///
    /// Uses `HistoryStore.assumedTypingWordsPerMinute`, which is an assumption,
    /// not a measurement — so it is presented as an estimate in the UI rather
    /// than as a fact.
    public var estimatedTimeSaved: TimeInterval {
        let typingTime = Double(totalWords) / HistoryStore.assumedTypingWordsPerMinute * 60
        return max(0, typingTime - totalSpeechTime)
    }

    public init() {}
}

/// Owns the SwiftData stack.
///
/// `@MainActor` throughout: the history and stats windows bind to it directly,
/// and the write path runs once per dictation, which is nowhere near often
/// enough to justify the complexity of a background context.
@MainActor
public final class HistoryStore {

    /// Average sustained typing speed for prose. Deliberately conservative —
    /// an inflated figure would make the "time saved" number flattering and
    /// therefore worthless.
    public nonisolated static let assumedTypingWordsPerMinute: Double = 40

    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(inMemory: Bool = false) throws {
        let schema = Schema([DictationRecord.self, VocabularyTerm.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            // Explicitly local. Dictation history is a transcript of everything
            // the user has said at their machine; it does not belong in iCloud
            // without them asking for it.
            cloudKitDatabase: .none
        )
        self.container = try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Records

    @discardableResult
    public func record(
        rawTranscript: String,
        finalText: String,
        speechDuration: TimeInterval,
        applicationBundleID: String?,
        applicationName: String?,
        engineName: String,
        refinementMode: RefinementMode,
        destination: Destination
    ) -> DictationRecord {
        let record = DictationRecord(
            rawTranscript: rawTranscript,
            finalText: finalText,
            speechDuration: speechDuration,
            applicationBundleID: applicationBundleID,
            applicationName: applicationName,
            engineName: engineName,
            refinementMode: refinementMode,
            destination: destination
        )
        context.insert(record)
        save()
        return record
    }

    public func recent(limit: Int = 200) -> [DictationRecord] {
        var descriptor = FetchDescriptor<DictationRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    public func search(_ query: String, limit: Int = 200) -> [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(limit: limit) }
        var descriptor = FetchDescriptor<DictationRecord>(
            predicate: #Predicate { $0.finalText.localizedStandardContains(trimmed) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    public func delete(_ record: DictationRecord) {
        context.delete(record)
        save()
    }

    public func deleteAllRecords() {
        try? context.delete(model: DictationRecord.self)
        save()
    }

    /// Drops records older than `days`. `nil` keeps everything.
    public func pruneRecords(olderThan days: Int?) {
        guard let days, days > 0 else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        try? context.delete(
            model: DictationRecord.self,
            where: #Predicate { $0.createdAt < cutoff }
        )
        save()
    }

    // MARK: - Stats

    public func stats() -> DictationStats {
        let records = (try? context.fetch(FetchDescriptor<DictationRecord>())) ?? []
        guard !records.isEmpty else { return DictationStats() }

        var stats = DictationStats()
        stats.sessionCount = records.count
        stats.totalWords = records.reduce(0) { $0 + $1.wordCount }
        stats.totalSpeechTime = records.reduce(0) { $0 + $1.speechDuration }

        let rated = records.filter { $0.wordsPerMinute > 0 }
        if !rated.isEmpty {
            stats.averageWordsPerMinute =
                rated.reduce(0) { $0 + $1.wordsPerMinute } / Double(rated.count)
        }
        stats.currentStreak = Self.streak(from: records.map(\.createdAt))
        return stats
    }

    /// Consecutive days with activity, counting back from today. A gap
    /// *yesterday* ends the streak; a gap today does not, so the number does not
    /// reset every morning before the first dictation.
    nonisolated static func streak(from dates: [Date]) -> Int {
        let calendar = Calendar.current
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: Date())
        var cursor = days.contains(today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today)!
        guard days.contains(cursor) else { return 0 }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // MARK: - Vocabulary

    public func vocabulary() -> [VocabularyTerm] {
        let descriptor = FetchDescriptor<VocabularyTerm>(
            sortBy: [SortDescriptor(\.term, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    public func vocabularyStrings() -> [String] {
        vocabulary().map(\.term)
    }

    @discardableResult
    public func addVocabulary(_ term: String, isAutomatic: Bool = false) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Case-insensitive de-duplication: "SwiftUI" and "swiftui" bias the
        // recogniser identically, so storing both is noise.
        guard !vocabulary().contains(where: {
            $0.term.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) else { return false }

        context.insert(VocabularyTerm(term: trimmed, isAutomatic: isAutomatic))
        save()
        return true
    }

    public func removeVocabulary(_ term: VocabularyTerm) {
        context.delete(term)
        save()
    }

    // MARK: - Saving

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Log.lifecycle.error("History save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
