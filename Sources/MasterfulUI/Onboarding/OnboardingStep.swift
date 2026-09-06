import Foundation

/// The setup flow.
///
/// Ordered by dependency, not by importance: each step unlocks the next. The
/// practice step is deliberately last and deliberately included — the moment a
/// person watches their own speech appear in a text field is the moment the
/// product explains itself, and putting it after setup rather than after
/// dismissal is the difference between someone using this and someone forgetting
/// they installed it.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case microphone
    case accessibility
    case speechModel
    case hotkey
    case cleanup
    case practice
    case ready

    public var title: String {
        switch self {
        case .welcome: "Masterful"
        case .microphone: "Let it hear you"
        case .accessibility: "Let it type for you"
        case .speechModel: "Speech model"
        case .hotkey: "Pick your key"
        case .cleanup: "How much clean-up?"
        case .practice: "Try it"
        case .ready: "You're set"
        }
    }

    public var subtitle: String {
        switch self {
        case .welcome:
            "Hold a key, talk, let go. The text lands wherever you were already typing — and nothing leaves this Mac."
        case .microphone:
            "Masterful only listens while you're holding your key. It is never recording in the background."
        case .accessibility:
            "This is what lets Masterful put text into other apps. macOS has no narrower permission for it."
        case .speechModel:
            "Apple's on-device speech model runs entirely on this Mac. Your audio is never uploaded."
        case .hotkey:
            "Anything works — a key, a chord, or a button on your mouse."
        case .cleanup:
            "Masterful can tidy punctuation and drop filler words. It will never change your actual words."
        case .practice:
            "Click into the box, hold your key, and say something."
        case .ready:
            "Masterful lives in the menu bar. It'll stay out of the way until you need it."
        }
    }

    /// Steps the user may skip past without satisfying.
    public var isOptional: Bool {
        switch self {
        case .welcome, .cleanup, .practice, .ready: true
        case .microphone, .accessibility, .speechModel, .hotkey: false
        }
    }
}
