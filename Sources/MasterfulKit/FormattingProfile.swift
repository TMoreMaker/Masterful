import Foundation

/// How text should be shaped for where it is going.
///
/// The frontmost application is known at insertion time, and the right output
/// genuinely differs: a sentence dictated into a terminal should not be
/// sentence-cased and punctuated, and a line dropped into Slack should not be
/// padded into formal prose. Applying one house style everywhere is the tell of
/// a dictation tool that does not know where it is.
public enum FormattingProfile: String, Sendable, Codable, CaseIterable {
    /// Full sentences, punctuation, capitalisation. Email, documents, notes.
    case prose
    /// Conversational. Keeps it short and does not add a trailing full stop.
    case message
    /// Minimal intervention. No sentence casing, no added punctuation — in an
    /// editor or a terminal those are corruption, not tidying.
    case code
    /// Nothing at all beyond whitespace normalisation.
    case verbatim

    public var displayName: String {
        switch self {
        case .prose: "Prose"
        case .message: "Message"
        case .code: "Code"
        case .verbatim: "Verbatim"
        }
    }

    public var summary: String {
        switch self {
        case .prose: "Full sentences, punctuation and capitalisation."
        case .message: "Conversational, no trailing full stop."
        case .code: "No capitalisation or punctuation added."
        case .verbatim: "Exactly what you said."
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
        "com.tinyspeck.slackmacgap": .message,
        "com.apple.MobileSMS": .message,
        "com.hnc.Discord": .message,
        "ru.keepcoder.Telegram": .message,
        "net.whatsapp.WhatsApp": .message,
    ]
}
