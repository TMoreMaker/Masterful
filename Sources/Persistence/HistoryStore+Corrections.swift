import Foundation
import MasterfulKit
import SwiftData

/// One week of the correction log.
public struct WeekSummary: Sendable, Equatable, Identifiable {
    public var weekStart: Date
    public var dictations: Int = 0
    /// Dictations Masterful could follow afterwards. The rates are taken over
    /// these alone.
    public var watchedDictations: Int = 0
    public var watchedWords: Int = 0
    public var misheardWords: Int = 0
    public var punctuationFixes: Int = 0

    public var id: Date { weekStart }

    public init(weekStart: Date) {
        self.weekStart = weekStart
    }

    /// Misheard words per hundred dictated. Per hundred rather than a raw count,
    /// so a week of heavy dictation does not read as a week of bad recognition.
    /// `nil` when nothing was watched: no data is not the same as no errors.
    public var misheardPer100: Double? {
        watchedWords > 0 ? Double(misheardWords) / Double(watchedWords) * 100 : nil
    }

    public var punctuationPer100: Double? {
        watchedWords > 0 ? Double(punctuationFixes) / Double(watchedWords) * 100 : nil
    }
}

/// The same fix, made more than once.
public struct RecurringCorrection: Sendable, Equatable, Identifiable {
    public var heard: String
    public var written: String
    public var kind: CorrectionKind
    public var count: Int
    public var lastSeen: Date

    public var id: String { "\(kind.rawValue)\u{1F}\(heard.lowercased())\u{1F}\(written)" }
}

extension HistoryStore {

    // MARK: - Writing

    /// Files what the watcher found against the dictation it watched,
    /// *replacing* whatever was filed for it before.
    ///
    /// Replacing rather than appending is what lets fixes be saved as they are
    /// made: each report describes the whole dictation as it now stands, so
    /// typing "Th", pausing, then finishing "Thando" ends with one fix, not two.
    ///
    /// `nil` means the field could not be followed, which is recorded as such:
    /// the dictation then stays out of the rate rather than counting as perfect.
    public func recordCorrections(_ result: CorrectionResult?, for record: DictationRecord) {
        // Deleted from history while it was being watched.
        guard record.modelContext != nil, !record.isDeleted else { return }
        guard let result else { return }

        let id = record.id
        try? context.delete(model: CorrectionEntry.self, where: #Predicate { $0.dictationID == id })
        record.correctionsWatched = true
        record.correctedText = result.edits.isEmpty ? nil : result.correctedText
        if !result.edits.isEmpty {
            for edit in result.edits {
                context.insert(CorrectionEntry(
                    edit: edit, dictationID: record.id, applicationName: record.applicationName
                ))
            }
        }
        save()
    }

    /// "Not a mishearing": keeps the edit in the log, but as a rewrite, so it
    /// stops counting against recognition.
    public func reclassify(_ correction: RecurringCorrection, as kind: CorrectionKind) {
        for entry in entries(matching: correction) { entry.kindRaw = kind.rawValue }
        save()
    }

    /// Takes back a term that was learned automatically, when the fix that
    /// taught it turned out to be something else. A term the user added by hand
    /// is never touched.
    public func removeLearnedVocabulary(_ term: String) {
        for entry in vocabulary() where entry.isAutomatic
            && entry.term.compare(term, options: .caseInsensitive) == .orderedSame {
            context.delete(entry)
        }
        save()
    }

    // MARK: - Reading

    public func corrections(for record: DictationRecord) -> [CorrectionEntry] {
        let id = record.id
        let descriptor = FetchDescriptor<CorrectionEntry>(
            predicate: #Predicate { $0.dictationID == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The last `weeks` calendar weeks, oldest first, the current one included
    /// even when it is empty.
    public func weeklySummaries(
        weeks: Int = 8,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeekSummary] {
        guard weeks > 0, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
        else { return [] }

        var summaries: [Date: WeekSummary] = [:]
        for offset in 0..<weeks {
            if let start = calendar.date(byAdding: .weekOfYear, value: offset, to: first) {
                summaries[start] = WeekSummary(weekStart: start)
            }
        }
        func week(of date: Date) -> Date? {
            calendar.dateInterval(of: .weekOfYear, for: date)?.start
        }

        let records = (try? context.fetch(FetchDescriptor<DictationRecord>(
            predicate: #Predicate { $0.createdAt >= first }
        ))) ?? []
        for record in records {
            guard let start = week(of: record.createdAt), summaries[start] != nil else { continue }
            summaries[start]!.dictations += 1
            if record.correctionsWatched {
                summaries[start]!.watchedDictations += 1
                summaries[start]!.watchedWords += record.wordCount
            }
        }

        let entries = (try? context.fetch(FetchDescriptor<CorrectionEntry>(
            predicate: #Predicate { $0.createdAt >= first }
        ))) ?? []
        for entry in entries {
            guard let start = week(of: entry.createdAt), summaries[start] != nil else { continue }
            switch entry.kind {
            case .word: summaries[start]!.misheardWords += entry.wordCount
            case .punctuation: summaries[start]!.punctuationFixes += 1
            case .rewrite: break
            }
        }

        return summaries.values.sorted { $0.weekStart < $1.weekStart }
    }

    /// Corrections grouped by what was heard and what it became, most frequent
    /// first. Grouping ignores the case of what was heard — the recogniser's
    /// capital is not the point — but keeps the case of what was written, since
    /// that is what goes into the vocabulary.
    public func recurringCorrections(kind: CorrectionKind? = nil, limit: Int = 200) -> [RecurringCorrection] {
        let entries = (try? context.fetch(FetchDescriptor<CorrectionEntry>())) ?? []
        var groups: [String: RecurringCorrection] = [:]
        for entry in entries where kind == nil || entry.kind == kind {
            let candidate = RecurringCorrection(
                heard: entry.heard, written: entry.written, kind: entry.kind,
                count: 1, lastSeen: entry.createdAt
            )
            if var existing = groups[candidate.id] {
                existing.count += 1
                existing.lastSeen = max(existing.lastSeen, entry.createdAt)
                groups[candidate.id] = existing
            } else {
                groups[candidate.id] = candidate
            }
        }
        return groups.values
            .sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
            .prefix(limit)
            .map { $0 }
    }

    private func entries(matching correction: RecurringCorrection) -> [CorrectionEntry] {
        let entries = (try? context.fetch(FetchDescriptor<CorrectionEntry>())) ?? []
        return entries.filter {
            RecurringCorrection(heard: $0.heard, written: $0.written, kind: $0.kind, count: 0, lastSeen: $0.createdAt).id
                == correction.id
        }
    }
}
