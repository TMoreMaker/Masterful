import Foundation

/// An action spoken aloud rather than typed.
///
/// Without these, dictation can only ever produce text — which means it cannot
/// submit a form, clear a field, or correct itself. On a laptop that is a minor
/// gap because the keyboard is right there. In clamshell mode, with the lid
/// shut, it is the difference between the product working and not.
public enum VoiceCommand: String, Sendable, Codable, CaseIterable, Hashable {
    case enter
    case send
    case newLine
    case tab
    case escape
    case delete
    case deleteWord
    case clear
    case selectAll
    case copy
    case paste
    case cut
    case undo
    case save

    public var displayName: String {
        switch self {
        case .enter: "Press Return"
        case .send: "Send (⌘Return)"
        case .newLine: "New line (⇧Return)"
        case .tab: "Tab"
        case .escape: "Escape"
        case .delete: "Delete a character"
        case .deleteWord: "Delete a word"
        case .clear: "Clear the field"
        case .selectAll: "Select all"
        case .copy: "Copy"
        case .paste: "Paste"
        case .cut: "Cut"
        case .undo: "Undo"
        case .save: "Save"
        }
    }

    /// Every phrase that invokes this command, longest first so that
    /// "delete word" is never matched as "delete".
    public var phrases: [String] {
        switch self {
        case .enter: ["enter", "return"]
        case .send: ["send"]
        case .newLine: ["new line", "newline", "line break"]
        case .tab: ["tab"]
        case .escape: ["escape", "cancel"]
        case .delete: ["delete", "backspace"]
        case .deleteWord: ["delete word", "backspace word"]
        case .clear: ["clear", "clear all", "select all delete"]
        case .selectAll: ["select all"]
        case .copy: ["copy"]
        case .paste: ["paste"]
        case .cut: ["cut"]
        case .undo: ["undo"]
        case .save: ["save"]
        }
    }
}

/// A transcript broken into things to type and things to do.
public enum TranscriptSegment: Sendable, Equatable {
    case text(String)
    case command(VoiceCommand)
}

/// Finds spoken commands inside a transcript.
///
/// The design problem is ambiguity: any word chosen as a command is also a word
/// someone might dictate. Two rules resolve it, and the second exists because
/// the first was not enough.
///
/// **A prefix must be followed by a known command.** "I'll dash to the shop"
/// keeps its "dash", because "to" is not a command.
///
/// **A command must end the utterance.** Only a trailing run of commands counts;
/// anything followed by more speech reverts to plain text. This is what stops
/// you triggering a command by *talking about* one — "what's the use case for
/// dash tab would be" reads as a question, not an instruction, because words
/// follow it. That case is not hypothetical: it fired a real Tab, moved focus
/// out of the text field mid-sentence, and split the rest of the sentence into
/// another window.
///
/// The cost is that commands can no longer be interleaved between runs of text
/// ("name dash tab email dash enter" fills only one field now). That is a real
/// loss, and it is the right trade: the interleaved case is a convenience, while
/// the misfire silently corrupts what the user was saying. Distinguishing the
/// two properly needs the pause before a spoken command, which means timing data
/// the parser does not have.
public struct VoiceCommandParser: Sendable {

    public struct Configuration: Sendable, Equatable {
        /// The word that marks what follows as a command.
        public var prefix: String
        public var enabledCommands: Set<VoiceCommand>

        public init(
            prefix: String = "dash",
            enabledCommands: Set<VoiceCommand> = Set(VoiceCommand.allCases)
        ) {
            self.prefix = prefix
            self.enabledCommands = enabledCommands
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// One scanned element: either an ordinary word, or a matched command along
    /// with the words that produced it, so it can be reverted to text.
    private enum Element {
        case word(Word)
        case command(VoiceCommand, source: [Word])
    }

    /// Splits a transcript into text and commands, in the order they were said.
    public func parse(_ transcript: String) -> [TranscriptSegment] {
        let words = Self.tokenize(transcript)
        guard !words.isEmpty else { return [] }

        // Longest phrases first, so "delete word" wins over "delete".
        let table: [(words: [String], command: VoiceCommand)] = configuration.enabledCommands
            .flatMap { command in
                command.phrases.map { (Self.tokenize($0).map(\.normalized), command) }
            }
            .sorted { $0.0.count > $1.0.count }

        // Pass one: find every candidate command.
        var elements: [Element] = []
        var index = 0

        while index < words.count {
            let word = words[index]
            guard word.normalized == configuration.prefix || word.normalized == "-" else {
                elements.append(.word(word))
                index += 1
                continue
            }

            var matched: (length: Int, command: VoiceCommand)?
            for entry in table {
                let end = index + 1 + entry.words.count
                guard end <= words.count else { continue }
                if words[(index + 1)..<end].map(\.normalized) == entry.words {
                    matched = (entry.words.count, entry.command)
                    break
                }
            }

            guard let matched else {
                // Just the word "dash". Leave it in the text where it belongs.
                elements.append(.word(word))
                index += 1
                continue
            }

            let source = Array(words[index..<(index + 1 + matched.length)])
            elements.append(.command(matched.command, source: source))
            index += 1 + matched.length
        }

        // Pass two: keep only the trailing run of commands. Anything with speech
        // after it was being talked about, not issued.
        var firstKept = elements.count
        for position in stride(from: elements.count - 1, through: 0, by: -1) {
            guard case .command = elements[position] else { break }
            firstKept = position
        }

        // Pass three: assemble, reverting demoted commands to their own words.
        var segments: [TranscriptSegment] = []
        var pending: [Word] = []

        func flushText() {
            guard !pending.isEmpty else { return }
            let text = pending.map(\.original).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.text(text)) }
            pending = []
        }

        for (position, element) in elements.enumerated() {
            switch element {
            case .word(let word):
                pending.append(word)
            case .command(let command, let source):
                if position >= firstKept {
                    flushText()
                    segments.append(.command(command))
                } else {
                    pending.append(contentsOf: source)
                }
            }
        }
        flushText()
        return segments
    }

    /// True when the transcript is nothing but commands, so there is no text to
    /// clean up or insert.
    public func containsOnlyCommands(_ segments: [TranscriptSegment]) -> Bool {
        !segments.isEmpty && segments.allSatisfy {
            if case .command = $0 { return true } else { return false }
        }
    }

    // MARK: - Tokenising

    struct Word: Sendable, Equatable {
        /// As spoken, with punctuation intact, for reassembly.
        let original: String
        /// Lowercased and stripped, for matching.
        let normalized: String
    }

    static func tokenize(_ text: String) -> [Word] {
        // A spoken "dash" may arrive as the character "-", so separate those out
        // rather than leaving them glued to a neighbouring word.
        let spaced = text.replacingOccurrences(
            of: "(?<=\\s)-(?=\\s)|^-|-$", with: " - ", options: .regularExpression
        )
        return spaced
            .split(whereSeparator: \.isWhitespace)
            .map { raw in
                let text = String(raw)
                let normalized = text
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
                return Word(original: text, normalized: normalized)
            }
    }
}
