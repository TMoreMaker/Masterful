import Foundation
import MasterfulKit
import SwiftData

/// One completed dictation.
///
/// Audio is never stored — only what was said and where it went. That is a
/// deliberate limit rather than an omission: keeping recordings would make this
/// database the single most sensitive file on the machine, and nothing the app
/// does needs them after the transcript exists.
@Model
public final class DictationRecord {
    #Index<DictationRecord>([\.createdAt])

    public var id: UUID = UUID()
    public var createdAt: Date = Date()

    /// Exactly what the recogniser heard, before clean-up.
    public var rawTranscript: String = ""
    /// What was actually inserted.
    public var finalText: String = ""

    /// Seconds of speech, for the words-per-minute figure.
    public var speechDuration: TimeInterval = 0
    public var wordCount: Int = 0
    public var characterCount: Int = 0

    public var applicationBundleID: String?
    public var applicationName: String?

    public var engineName: String = ""
    public var refinementModeRaw: String = RefinementMode.rules.rawValue
    public var wentToClipboard: Bool = false

    public init(
        rawTranscript: String,
        finalText: String,
        speechDuration: TimeInterval,
        applicationBundleID: String?,
        applicationName: String?,
        engineName: String,
        refinementMode: RefinementMode,
        destination: Destination
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.speechDuration = speechDuration
        self.wordCount = finalText.split(whereSeparator: \.isWhitespace).count
        self.characterCount = finalText.count
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.engineName = engineName
        self.refinementModeRaw = refinementMode.rawValue
        self.wentToClipboard = destination == .clipboard
    }

    public var refinementMode: RefinementMode {
        RefinementMode(rawValue: refinementModeRaw) ?? .rules
    }

    /// Speaking rate for this dictation. Guards against the sub-second
    /// utterances that would otherwise report implausible figures.
    public var wordsPerMinute: Double {
        guard speechDuration >= 1, wordCount > 0 else { return 0 }
        return Double(wordCount) / (speechDuration / 60)
    }
}

/// A user-defined term the recogniser should be biased toward.
@Model
public final class VocabularyTerm {
    public var term: String = ""
    public var addedAt: Date = Date()
    /// Automatically suggested from corrections rather than typed by hand.
    public var isAutomatic: Bool = false

    public init(term: String, isAutomatic: Bool = false) {
        self.term = term
        self.addedAt = Date()
        self.isAutomatic = isAutomatic
    }
}
