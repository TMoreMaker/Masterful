import Foundation

/// What a single edit to a dictation says about the recogniser.
public enum CorrectionKind: String, Sendable, Codable, CaseIterable {
    /// A word swapped, added or removed: "pleased" → "placed". This is the
    /// number that says whether recognition is getting better.
    case word
    /// The same words, punctuated or capitalised differently:
    /// "functional. With" → "functional, with".
    case punctuation
    /// The user rewrote the passage. Logged, because it happened, but never
    /// counted as a mishearing — changing your mind is not a recognition error.
    case rewrite
}

/// One change the user made to text Masterful inserted.
public struct CorrectionEdit: Sendable, Equatable {
    /// What Masterful inserted. Empty when the user added a missing word.
    public var heard: String
    /// What the user changed it to. Empty when they deleted a word.
    public var written: String
    public var kind: CorrectionKind

    public init(heard: String, written: String, kind: CorrectionKind) {
        self.heard = heard
        self.written = written
        self.kind = kind
    }

    /// How many inserted words this edit accounts for. An added word counts as
    /// one: the recogniser missed it.
    public var wordCount: Int {
        max(1, heard.split(whereSeparator: \.isWhitespace).count)
    }
}

/// The dictation as the user left it.
public struct CorrectionResult: Sendable, Equatable {
    public var correctedText: String
    public var edits: [CorrectionEdit]

    public init(correctedText: String, edits: [CorrectionEdit]) {
        self.correctedText = correctedText
        self.edits = edits
    }
}

/// Finds what the user changed in a dictation after it landed.
///
/// Given the field as it was straight after insertion, where the dictation sits
/// in it, and the field as the user left it, this works out which of their edits
/// touched the dictation and what each one says. Edits elsewhere in the field —
/// typing on after it, fixing an earlier paragraph — are not the recogniser's
/// fault and are ignored.
///
/// Every judgement here errs towards not counting. A chart that says recognition
/// got worse because you rephrased a sentence would be worse than no chart.
public enum CorrectionDiff {

    /// A run longer than this, on either side, is a rewrite rather than a
    /// misheard phrase. Recognisers mishear words and short phrases; they do not
    /// mishear sentences.
    public static let longestMishearing = 3
    /// Above this share of the dictation's words changed, the whole thing was
    /// rewritten, and none of it is counted as recognition.
    public static let rewriteShare = 0.6
    /// Fields bigger than this are documents, not text boxes, and diffing them
    /// on every dictation is not worth the cost.
    public static let largestField = 200_000

    /// - Parameters:
    ///   - baseline: the field's full text straight after insertion.
    ///   - span: where the dictation sits in `baseline`, in UTF-16 units — the
    ///     unit Accessibility reports ranges in.
    ///   - final: the field's full text when the watch ended.
    /// - Returns: `nil` when the dictation was deleted outright or the inputs do
    ///   not describe a dictation, which is not a correction either way.
    public static func corrections(baseline: String, span: NSRange, final: String) -> CorrectionResult? {
        let base = Array(baseline.utf16)
        let after = Array(final.utf16)
        guard base.count <= largestField, after.count <= largestField,
              span.location >= 0, span.length > 0, NSMaxRange(span) <= base.count
        else { return nil }

        let spanStart = span.location
        let spanEnd = NSMaxRange(span)
        let inserted = String(utf16CodeUnits: Array(base[spanStart..<spanEnd]), count: span.length)

        guard base != after else { return CorrectionResult(correctedText: inserted, edits: []) }

        // Narrow to what changed: everything before `prefix` and after `suffix`
        // is identical in both.
        var prefix = 0
        while prefix < base.count, prefix < after.count, base[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < after.count - prefix,
              base[base.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }

        let changedStart = prefix
        let changedEnd = base.count - suffix
        // A change that sits wholly before or after the dictation — including
        // typing on straight after it — is not a correction of it.
        if changedEnd < spanStart || changedStart > spanEnd
            || (changedStart == changedEnd && (changedStart == spanStart || changedStart == spanEnd)) {
            return CorrectionResult(correctedText: inserted, edits: [])
        }

        // The region to compare: the dictation, widened to take in the change,
        // then out to whole words so a word is never compared as two halves.
        var low = min(spanStart, changedStart)
        var high = max(spanEnd, changedEnd)
        while low > 0, !isSpace(base[low - 1]) { low -= 1 }
        while high < base.count, !isSpace(base[high]) { high += 1 }

        let shift = after.count - base.count
        let before = String(utf16CodeUnits: Array(base[low..<high]), count: high - low)
        let afterEnd = high + shift
        guard afterEnd >= low else { return nil }
        let corrected = String(utf16CodeUnits: Array(after[low..<afterEnd]), count: afterEnd - low)

        let heardWords = words(before)
        let writtenWords = words(corrected)
        guard !writtenWords.isEmpty else { return nil }

        var edits = changedRuns(from: heardWords, to: writtenWords).compactMap { run -> CorrectionEdit? in
            // Words added at the very end are the user carrying on writing.
            if run.heard.isEmpty, run.position == heardWords.count { return nil }
            return classify(heard: run.heard, written: run.written)
        }

        let dictatedWords = words(inserted).count
        let changedWords = edits.filter { $0.kind != .punctuation }.reduce(0) { $0 + $1.wordCount }
        if dictatedWords >= 5, Double(changedWords) / Double(dictatedWords) > rewriteShare {
            edits = edits.map { CorrectionEdit(heard: $0.heard, written: $0.written, kind: .rewrite) }
        }

        return CorrectionResult(
            correctedText: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
            edits: edits
        )
    }

    // MARK: - Classification

    static func classify(heard: [String], written: [String]) -> CorrectionEdit {
        let heardText = heard.joined(separator: " ")
        let writtenText = written.joined(separator: " ")
        let kind: CorrectionKind
        if !heard.isEmpty, !written.isEmpty, normalised(heardText) == normalised(writtenText) {
            kind = .punctuation
        } else if heard.count <= longestMishearing, written.count <= longestMishearing {
            kind = .word
        } else {
            kind = .rewrite
        }
        return CorrectionEdit(heard: heardText, written: writtenText, kind: kind)
    }

    /// Letters and digits only, lowercased: what is left when punctuation and
    /// capitalisation are not the question.
    static func normalised(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }.map(Character.init))
        .split(separator: " ").joined(separator: " ")
    }

    // MARK: - Word diff

    struct Run: Equatable {
        var heard: [String]
        var written: [String]
        /// Index in the heard words where the run begins.
        var position: Int
    }

    /// Longest-common-subsequence diff over words, reduced to the runs that
    /// differ.
    static func changedRuns(from a: [String], to b: [String]) -> [Run] {
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var runs: [Run] = []
        var current = Run(heard: [], written: [], position: 0)
        func flush(at position: Int) {
            if !current.heard.isEmpty || !current.written.isEmpty { runs.append(current) }
            current = Run(heard: [], written: [], position: position)
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                i += 1; j += 1
                flush(at: i)
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                current.written.append(b[j]); j += 1
            } else {
                current.heard.append(a[i]); i += 1
            }
        }
        flush(at: i)
        return runs
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0
    }
}
