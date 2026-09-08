import AppKit
import MasterfulKit

/// Speaks what the island shows.
///
/// The island lives in a panel that can never take focus — that constraint is
/// the product, since a HUD that steals focus leaves nowhere to insert the
/// text. But VoiceOver navigates by focus, so a window that cannot be focused is
/// a window its cursor can never reach. The island carries a perfectly good
/// accessibility label that nothing has ever read aloud: a label on a door
/// nobody can open.
///
/// An announcement sidesteps the problem entirely. It is broadcast rather than
/// navigated to, so it needs no focus, no cursor and no reachable window — the
/// same mechanism the system uses to tell you a download finished.
///
/// This deliberately lives beside the view rather than in `DictationCoordinator`.
/// The island is a pure function of `DictationPhase`; so is this. Anything that
/// sets a phase gets the spoken version for free, which is also why
/// `MASTERFUL_HUD_PREVIEW=1` can be used to hear every state without speaking
/// into the machine.
@MainActor
public enum HUDAnnouncer {

    /// Nothing is posted unless VoiceOver is actually running. An announcement
    /// has no other consumer, so posting regardless would be noise on a queue
    /// no one is reading.
    public static var isActive: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    /// Announces a phase, if it is one worth announcing.
    ///
    /// Returns the text spoken, or `nil` when the phase says nothing — useful
    /// for logging what a VoiceOver user would have heard.
    @discardableResult
    public static func announce(_ phase: DictationPhase, from element: Any?) -> String? {
        guard let message = spokenText(for: phase) else { return nil }
        guard isActive else { return message }

        NSAccessibility.post(
            element: element ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                // Every one of these is the direct answer to something the user
                // just did with the dictation key, so whatever VoiceOver was
                // part-way through saying is already stale.
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        return message
    }

    /// What a phase sounds like, or `nil` for the ones that stay quiet.
    ///
    /// **Two announcements per dictation, not six.** Starting and the outcome
    /// are announced; transcribing, refining and inserting are not. Those three
    /// pass in well under two seconds, and narrating each would turn a two-word
    /// answer into a paragraph — the spoken equivalent of the live transcript
    /// the island already refuses to draw. The rule is the same one
    /// `DictationPhase.hudPresentation` follows: say something only when the
    /// user has to act on it.
    public static func spokenText(for phase: DictationPhase) -> String? {
        switch phase {
        case .idle, .transcribing, .refining, .inserting:
            return nil

        case .listening(let mode):
            // Latched needs its own line: the way you stop it is different, and
            // that is the one thing the waveform could never have conveyed
            // either.
            return mode == .latched
                ? "Listening continuously. Press again to stop."
                : "Listening"

        case .delivered(let delivery):
            return spoken(deliveredText(delivery))

        case .failed(let error):
            return spoken("\(error.userMessage). \(error.recoverySuggestion)")

        case .blocked(let reason):
            return spoken("\(reason.userMessage). \(reason.recoverySuggestion)")
        }
    }

    private static func deliveredText(_ delivery: Delivery) -> String {
        if delivery.wordCount == 0, let summary = delivery.commandSummary {
            return summary
        }
        let unit = delivery.wordCount == 1 ? "word" : "words"
        // The case this exists for. The text is not where the user was looking,
        // and a sighted user gets a card telling them so. Without this line a
        // VoiceOver user would conclude the dictation simply failed, while their
        // sentence sat unmentioned on the clipboard.
        return delivery.destination == .clipboard
            ? "\(delivery.wordCount) \(unit) copied to the clipboard. Press ⌘V to paste."
            : "\(delivery.wordCount) \(unit) inserted"
    }

    /// Rewrites the two symbols in the app's copy that a screen reader mangles.
    ///
    /// `⌘` is announced as "place of interest sign", and `→` is skipped
    /// silently, which turns a settings path into an unnavigable run of words.
    /// Doing this here rather than keeping a second set of spoken strings is
    /// deliberate: one copy of every message is the only way the written and
    /// spoken versions cannot drift apart.
    private static func spoken(_ text: String) -> String {
        text
            .replacingOccurrences(of: "⌘", with: "Command ")
            .replacingOccurrences(of: " → ", with: ", then ")
    }
}
