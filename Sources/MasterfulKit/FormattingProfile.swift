import Foundation

/// The register to write in.
///
/// Masterful's job is not to transcribe you — it is to get what you meant into
/// the field in the form you would have typed it. Speech and writing are
/// different registers, and the gap between them is not noise to be filtered but
/// a translation to be made: nobody types "I'm not a fan of the shadows, I think
/// those should be omitted", they type "Remove the shadows".
///
/// So every profile here preserves *intent* and discards *phrasing*. What varies
/// between them is tone, because the same thought belongs in different clothes
/// depending on whether it is going to a terminal, a colleague or a friend.
///
/// `code` and `verbatim` are the escape hatches, and deliberately do none of
/// this. They exist for the cases where transformation is corruption.
public enum FormattingProfile: String, Sendable, Codable, CaseIterable {
    /// Precise and imperative. Domain terms survive untouched. Prompts, issues,
    /// commit messages, specifications.
    case technical
    /// Complete sentences, professional, no contractions. Email, documents.
    case formal
    /// Conversational. Contractions are fine and politeness is not manufactured.
    case informal
    /// Minimal intervention. No sentence casing, no added punctuation — in an
    /// editor or a terminal those are corruption, not tidying.
    case code
    /// Nothing at all beyond whitespace normalisation.
    case verbatim

    public var displayName: String {
        switch self {
        case .technical: "Technical"
        case .formal: "Formal"
        case .informal: "Informal"
        case .code: "Code"
        case .verbatim: "Verbatim"
        }
    }

    public var summary: String {
        switch self {
        case .technical: "Direct and precise. Lists when you dictate a list."
        case .formal: "Full sentences, professional tone."
        case .informal: "Conversational, the way you'd actually message someone."
        case .code: "No capitalisation or punctuation added."
        case .verbatim: "Exactly what you said."
        }
    }

    /// Whether this profile may rewrite the user's phrasing to carry their
    /// meaning more compactly.
    ///
    /// The single most consequential property on this type: it decides whether
    /// the app is a transcriber or a drafting tool for a given destination, and
    /// it is what `TranscriptGuard` consults before deciding how much change to
    /// tolerate.
    public var rewritesPhrasing: Bool {
        switch self {
        case .technical, .formal, .informal: true
        case .code, .verbatim: false
        }
    }

    /// Whether a dictation containing several parallel points may be rendered as
    /// a list.
    ///
    /// Off for `informal` on purpose. Bullet points in a reply to a friend read
    /// as a memo, which is exactly the register error this type exists to avoid
    /// — the structure has to agree with the tone, or the tone loses.
    public var mayUseLists: Bool {
        switch self {
        case .technical, .formal: true
        case .informal, .code, .verbatim: false
        }
    }

    /// Sensible starting points, so per-app behaviour is right before the user
    /// configures anything.
    public static let defaultAssignments: [String: FormattingProfile] = [
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "dev.zed.Zed": .code,
        "com.todesktop.230313mzl4w4u92": .code,   // Cursor
        "com.tinyspeck.slackmacgap": .informal,
        "com.apple.MobileSMS": .informal,
        "com.hnc.Discord": .informal,
        "ru.keepcoder.Telegram": .informal,
        "net.whatsapp.WhatsApp": .informal,
        "com.apple.mail": .formal,
        // Verified against the installed bundles rather than guessed: a wrong
        // identifier here fails silently, leaving the user wondering why their
        // per-app rule never fires.
        "com.anthropic.claudefordesktop": .technical,
        "com.openai.codex": .technical,
    ]

    // MARK: - Migration

    /// Decoded by hand so that settings written before registers existed still
    /// load.
    ///
    /// The previous cases were `prose` and `message`, which conflated tone with
    /// destination. Falling back to a default instead of mapping them would
    /// silently discard every per-app assignment the user had made — and because
    /// `appProfiles` decodes as one dictionary, a single unrecognised value
    /// would take all the others down with it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "prose": self = .formal
        case "message": self = .informal
        default:
            guard let value = FormattingProfile(rawValue: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown profile \(raw)")
                )
            }
            self = value
        }
    }
}
