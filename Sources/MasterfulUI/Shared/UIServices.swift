import MasterfulKit
import Observation
import Persistence
import SwiftUI

/// What the app can currently do.
public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: Bool = false
    public var accessibility: Bool = false
    public var speechModelReady: Bool = false
    public var globeKeyConflict: Bool = false
    public var onDeviceModelNote: String?

    public init() {}

    public var allGranted: Bool { microphone && accessibility && speechModelReady }
}

/// The seam between the UI layer and the running application.
///
/// The windows need to read settings, read history, and ask the app to do a
/// handful of things it alone can do — request a permission, restart the hotkey
/// engine, quit. Passing the coordinator itself would make `MasterfulUI` depend
/// on the composition root and turn the dependency graph into a cycle. A small
/// object of values and closures keeps the arrow pointing one way.
@MainActor
@Observable
public final class UIServices {
    public let settingsStore: SettingsStore
    public let historyStore: HistoryStore

    public var permissions = PermissionSnapshot()
    /// Live input level, so onboarding can show the microphone working before
    /// asking the user to trust it with a sentence.
    public var inputLevel: AudioLevel = .silence
    public var isMicTestRunning = false

    public var onSettingsChanged: () -> Void = {}
    /// Suspends the live hotkey while a new one is being recorded, so the
    /// engine does not swallow the very button the user is trying to bind.
    public var onRecordingChanged: (Bool) -> Void = { _ in }
    public var onRequestMicrophone: () async -> Void = {}
    public var onRequestAccessibility: () -> Void = {}
    public var onRefreshPermissions: () async -> Void = {}
    public var onStartMicTest: () -> Void = {}
    public var onStopMicTest: () -> Void = {}
    public var onFinishOnboarding: () -> Void = {}
    public var onQuit: () -> Void = {}

    public init(settingsStore: SettingsStore, historyStore: HistoryStore) {
        self.settingsStore = settingsStore
        self.historyStore = historyStore
    }

    public var settings: MasterfulKit.Settings { settingsStore.settings }

    /// Mutate settings and tell the app in one step, so no caller can change a
    /// binding and forget to restart the engine that depends on it.
    public func update(_ mutate: (inout MasterfulKit.Settings) -> Void) {
        settingsStore.update(mutate)
        onSettingsChanged()
    }
}
