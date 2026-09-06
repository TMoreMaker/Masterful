import Foundation
import Observation

/// How aggressively the raw transcript is cleaned before insertion.
public enum RefinementMode: String, Sendable, Codable, CaseIterable {
    /// Insert exactly what was heard.
    case off
    /// Deterministic only: spoken punctuation, filler removal, sentence casing.
    case rules
    /// Rules, then Apple's on-device model. Never leaves the machine.
    case onDevice
    /// Rules, then a remote model using a key you supply. Opt-in, off by default.
    case remote

    public var displayName: String {
        switch self {
        case .off: "Raw"
        case .rules: "Tidy"
        case .onDevice: "On-device AI"
        case .remote: "Cloud AI"
        }
    }
}

/// How text reaches the focused field.
public enum InsertionStrategy: String, Sendable, Codable, CaseIterable {
    /// Try Accessibility, fall back to paste, fall back to typing. Recommended.
    case automatic
    case paste
    case accessibility
    case typing

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .paste: "Paste"
        case .accessibility: "Accessibility"
        case .typing: "Simulated typing"
        }
    }
}

/// Where the HUD lives.
public enum HUDAnchor: String, Sendable, Codable, CaseIterable {
    /// Continues the notch on displays that have one; a bar cut into the top
    /// edge of the screen on displays that do not.
    case notch
    case topCenter
    case bottomCenter

    public var displayName: String {
        switch self {
        case .notch: "In the notch"
        case .topCenter: "Top centre"
        case .bottomCenter: "Bottom centre"
        }
    }
}

public struct Settings: Sendable, Codable, Equatable {
    /// Every binding that starts dictation, all live at once.
    ///
    /// A list rather than a single shortcut because one machine is several
    /// machines over a day: open on a desk, the Globe key is under your thumb;
    /// closed in clamshell with an external keyboard and mouse, it is not
    /// reachable at all. Making the user re-record a binding when they dock is
    /// not a preference, it is a defect.
    public var triggers: [Shortcut] = [.globeKey]
    /// Double-tapping the same trigger latches dictation on until pressed again.
    public var enableDoubleTapLatch: Bool = true
    /// Two presses inside this window count as a double-tap.
    public var doubleTapWindowMilliseconds: Int = 320
    /// A press shorter than this was a tap, not a hold. Below it we wait to see
    /// whether a second tap is coming rather than transcribing a 90 ms blip.
    public var minimumHoldMilliseconds: Int = 220

    public var refinement: RefinementMode = .rules
    public var insertion: InsertionStrategy = .automatic
    /// Names and jargon, fed to the recogniser as contextual bias.
    public var vocabulary: [String] = []
    public var localeIdentifier: String = Locale.current.identifier

    /// Fallback style, used when the frontmost app has no assignment.
    public var defaultProfile: FormattingProfile = .prose
    /// Bundle identifier → formatting profile.
    public var appProfiles: [String: FormattingProfile] = FormattingProfile.defaultAssignments

    /// Which service `RefinementMode.remote` talks to. The key itself lives in
    /// the Keychain, never here.
    public var remoteProvider: RemoteProvider = .anthropic

    public var historyEnabled: Bool = true
    /// Days of history to keep. `nil` keeps everything.
    public var historyRetentionDays: Int? = 90

    public var hasCompletedOnboarding: Bool = false

    /// Spoken actions like "dash enter". Essential in clamshell mode, where
    /// there is no keyboard to reach for.
    public var voiceCommandsEnabled: Bool = true
    /// The word that marks what follows as a command rather than dictation.
    public var voiceCommandPrefix: String = "dash"

    public var soundEffects: Bool = false
    public var hudAnchor: HUDAnchor = .notch
    public var launchAtLogin: Bool = false
    /// `nil` follows the system default input device, including when it changes.
    public var preferredInputDeviceUID: String?

    public init() {}

    // MARK: - Codable

    /// Decoded field by field, with every missing key falling back to its
    /// default.
    ///
    /// Swift's synthesised decoder ignores property defaults and throws on any
    /// missing key, so adding a single setting would fail to decode every
    /// existing install and silently reset the user's entire configuration. That
    /// is a bad enough outcome to be worth writing by hand.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        // Migration: before multiple bindings, this was a single `pushToTalk`.
        let stored = ((try? container.decodeIfPresent([Shortcut].self, forKey: .triggers)) ?? nil) ?? []
        let legacy = (try? container.decodeIfPresent(Shortcut.self, forKey: .pushToTalk)) ?? nil
        if !stored.isEmpty {
            triggers = stored
        } else if let legacy {
            triggers = [legacy]
        } else {
            triggers = defaults.triggers
        }

        enableDoubleTapLatch = value(.enableDoubleTapLatch, defaults.enableDoubleTapLatch)
        doubleTapWindowMilliseconds = value(.doubleTapWindowMilliseconds, defaults.doubleTapWindowMilliseconds)
        minimumHoldMilliseconds = value(.minimumHoldMilliseconds, defaults.minimumHoldMilliseconds)
        refinement = value(.refinement, defaults.refinement)
        insertion = value(.insertion, defaults.insertion)
        vocabulary = value(.vocabulary, defaults.vocabulary)
        localeIdentifier = value(.localeIdentifier, defaults.localeIdentifier)
        defaultProfile = value(.defaultProfile, defaults.defaultProfile)
        appProfiles = value(.appProfiles, defaults.appProfiles)
        remoteProvider = value(.remoteProvider, defaults.remoteProvider)
        historyEnabled = value(.historyEnabled, defaults.historyEnabled)
        historyRetentionDays = value(.historyRetentionDays, defaults.historyRetentionDays)
        hasCompletedOnboarding = value(.hasCompletedOnboarding, defaults.hasCompletedOnboarding)
        voiceCommandsEnabled = value(.voiceCommandsEnabled, defaults.voiceCommandsEnabled)
        voiceCommandPrefix = value(.voiceCommandPrefix, defaults.voiceCommandPrefix)
        soundEffects = value(.soundEffects, defaults.soundEffects)
        hudAnchor = value(.hudAnchor, defaults.hudAnchor)
        launchAtLogin = value(.launchAtLogin, defaults.launchAtLogin)
        preferredInputDeviceUID = value(.preferredInputDeviceUID, defaults.preferredInputDeviceUID)
    }

    /// Written explicitly because `CodingKeys` carries a read-only migration
    /// key (`pushToTalk`) with no matching property, so the encoder cannot be
    /// synthesised. Legacy keys are deliberately not written back out.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(triggers, forKey: .triggers)
        try container.encode(enableDoubleTapLatch, forKey: .enableDoubleTapLatch)
        try container.encode(doubleTapWindowMilliseconds, forKey: .doubleTapWindowMilliseconds)
        try container.encode(minimumHoldMilliseconds, forKey: .minimumHoldMilliseconds)
        try container.encode(refinement, forKey: .refinement)
        try container.encode(insertion, forKey: .insertion)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(localeIdentifier, forKey: .localeIdentifier)
        try container.encode(defaultProfile, forKey: .defaultProfile)
        try container.encode(appProfiles, forKey: .appProfiles)
        try container.encode(remoteProvider, forKey: .remoteProvider)
        try container.encode(historyEnabled, forKey: .historyEnabled)
        try container.encodeIfPresent(historyRetentionDays, forKey: .historyRetentionDays)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(voiceCommandsEnabled, forKey: .voiceCommandsEnabled)
        try container.encode(voiceCommandPrefix, forKey: .voiceCommandPrefix)
        try container.encode(soundEffects, forKey: .soundEffects)
        try container.encode(hudAnchor, forKey: .hudAnchor)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encodeIfPresent(preferredInputDeviceUID, forKey: .preferredInputDeviceUID)
    }

    enum CodingKeys: String, CodingKey {
        case triggers
        /// Read only, for migration from single-binding installs.
        case pushToTalk
        case enableDoubleTapLatch, doubleTapWindowMilliseconds, minimumHoldMilliseconds
        case refinement, insertion, vocabulary, localeIdentifier
        case defaultProfile, appProfiles, remoteProvider
        case historyEnabled, historyRetentionDays, hasCompletedOnboarding
        case voiceCommandsEnabled, voiceCommandPrefix
        case soundEffects, hudAnchor, launchAtLogin, preferredInputDeviceUID
    }

    public var doubleTapWindow: Duration { .milliseconds(doubleTapWindowMilliseconds) }
    public var minimumHold: Duration { .milliseconds(minimumHoldMilliseconds) }

    /// The binding shown when there is only room to name one.
    public var primaryTrigger: Shortcut { triggers.first ?? .globeKey }

    /// "🌐 Globe (fn) or Mouse 4" — for menus and onboarding copy.
    public var triggersDisplayString: String {
        guard !triggers.isEmpty else { return "no shortcut set" }
        let names = triggers.map(\.displayString)
        guard names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
    }

    public func profile(forBundleID bundleID: String?) -> FormattingProfile {
        guard let bundleID else { return defaultProfile }
        return appProfiles[bundleID] ?? defaultProfile
    }
}

/// Services that can perform the optional cloud clean-up stage.
public enum RemoteProvider: String, Sendable, Codable, CaseIterable {
    case anthropic
    case google

    public var displayName: String {
        switch self {
        case .anthropic: "Claude"
        case .google: "Gemini"
        }
    }

    /// The smallest, fastest model each provider offers. Transcript tidying is
    /// not a task that rewards a frontier model, and latency is the budget that
    /// actually matters here.
    public var modelIdentifier: String {
        switch self {
        case .anthropic: "claude-haiku-4-5-20251001"
        case .google: "gemini-2.5-flash-lite"
        }
    }

    public var keychainAccount: String {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .google: "google-api-key"
        }
    }

    public var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .google: URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

/// Observable settings store backed by `UserDefaults`.
///
/// Writes are debounced through `Observable`'s change tracking rather than a
/// `didSet` on every property, so the settings UI can bind directly.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key = "settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = Settings()
        }
    }

    /// Single mutation entry point. Keeps persistence in one place and makes
    /// every settings change greppable.
    public func update(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        guard copy != settings else { return }
        settings = copy
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else {
            Log.lifecycle.error("Failed to encode settings")
            return
        }
        defaults.set(data, forKey: key)
    }
}
