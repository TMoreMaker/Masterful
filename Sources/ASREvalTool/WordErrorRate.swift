import Foundation

/// Word error rate, with the alignment kept rather than thrown away.
///
/// A bare WER number tells you a run got worse without telling you how, which is
/// exactly the information needed to act. So the alignment that produces the
/// number is retained and reported: "rand → rent" is the finding, and 4.2% is
/// only the summary of it.
struct WordErrorRate {

    enum Edit: Equatable {
        case match(String)
        case substitution(reference: String, heard: String)
        case deletion(String)
        case insertion(String)
    }

    let reference: [String]
    let hypothesis: [String]
    let edits: [Edit]

    var substitutions: [(reference: String, heard: String)] {
        edits.compactMap { if case .substitution(let r, let h) = $0 { (r, h) } else { nil } }
    }
    var deletions: [String] {
        edits.compactMap { if case .deletion(let w) = $0 { w } else { nil } }
    }
    var insertions: [String] {
        edits.compactMap { if case .insertion(let w) = $0 { w } else { nil } }
    }

    var errorCount: Int { substitutions.count + deletions.count + insertions.count }

    /// Errors per reference word. Can exceed 1.0 when the recogniser inserts
    /// more than it gets right — which is worth seeing rather than clamping.
    var rate: Double {
        reference.isEmpty ? 0 : Double(errorCount) / Double(reference.count)
    }

    // MARK: - Normalisation

    /// Reduces both sides to comparable word sequences.
    ///
    /// Punctuation and casing are removed because this measures *recognition*,
    /// not formatting — the refinement stage owns those, and it is evaluated
    /// separately by `masterful-eval`. Digit grouping is stripped so that
    /// "18,000" and "18000" are the same word; spelled-out versus numeric forms
    /// are deliberately NOT reconciled, because "eighteen thousand" and "18000"
    /// are a genuine difference in what the recogniser produced and hiding it
    /// would flatter the result.
    static func normalise(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "(?<=\\d),(?=\\d)", with: "", options: .regularExpression)
            // Keep intra-word apostrophes: "don't" is one word, not two.
            .replacingOccurrences(of: "[^a-z0-9'\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?<![a-z])'|'(?![a-z])", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    // MARK: - Alignment

    /// Standard Levenshtein over words, then a backtrace to recover the edits.
    ///
    /// The full matrix is held rather than the usual two-row optimisation: these
    /// passages are a few dozen words, and being able to walk backwards through
    /// it is what turns a number into a list of specific mistakes.
    init(reference referenceText: String, hypothesis hypothesisText: String) {
        let reference = Self.normalise(referenceText)
        let hypothesis = Self.normalise(hypothesisText)
        self.reference = reference
        self.hypothesis = hypothesis

        let rows = reference.count, columns = hypothesis.count
        var cost = Array(
            repeating: Array(repeating: 0, count: columns + 1),
            count: rows + 1
        )
        for row in 0...rows { cost[row][0] = row }
        for column in 0...columns { cost[0][column] = column }

        for row in 1...max(rows, 1) where rows > 0 {
            for column in 1...max(columns, 1) where columns > 0 {
                if reference[row - 1] == hypothesis[column - 1] {
                    cost[row][column] = cost[row - 1][column - 1]
                } else {
                    cost[row][column] = 1 + min(
                        cost[row - 1][column - 1],  // substitution
                        cost[row - 1][column],      // deletion
                        cost[row][column - 1]       // insertion
                    )
                }
            }
        }

        var edits: [Edit] = []
        var row = rows, column = columns
        while row > 0 || column > 0 {
            if row > 0, column > 0, reference[row - 1] == hypothesis[column - 1] {
                edits.append(.match(reference[row - 1]))
                row -= 1; column -= 1
            } else if row > 0, column > 0, cost[row][column] == cost[row - 1][column - 1] + 1 {
                edits.append(.substitution(reference: reference[row - 1], heard: hypothesis[column - 1]))
                row -= 1; column -= 1
            } else if row > 0, cost[row][column] == cost[row - 1][column] + 1 {
                edits.append(.deletion(reference[row - 1]))
                row -= 1
            } else {
                edits.append(.insertion(hypothesis[column - 1]))
                column -= 1
            }
        }
        self.edits = edits.reversed()
    }
}
