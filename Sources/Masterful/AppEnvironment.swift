import AppKit
import AudioCapture
import InputControl
import MasterfulKit
import MasterfulUI
import Observation
import Persistence
import Refinement

/// Composition root.
///
/// A singleton because there is exactly one microphone, one event tap and one
/// HUD on a machine, and because the `NSApplicationDelegate` needs to reach the
/// same instance the SwiftUI scene renders. Everything it owns takes its
/// dependencies by injection, so the singleton stops here rather than spreading.
@MainActor
@Observable
public final class AppEnvironment {
    public static let shared = AppEnvironment()

    public let settingsStore: SettingsStore
    public let historyStore: HistoryStore
    public let coordinator: DictationCoordinator
    public let services: UIServices

    private var previewTask: Task<Void, Never>?

    private init() {
        let store = SettingsStore()
        self.settingsStore = store

        // A failed store must not take the app down: dictation itself does not
        // need history, so fall back to an in-memory container and carry on
        // with statistics disabled rather than refusing to launch.
        let history: HistoryStore
        do {
            history = try HistoryStore()
        } catch {
            Log.lifecycle.error(
                "History store unavailable, continuing in memory: \(error.localizedDescription, privacy: .public)"
            )
            history = try! HistoryStore(inMemory: true)
        }
        self.historyStore = history

        self.coordinator = DictationCoordinator(settingsStore: store, historyStore: history)
        self.services = UIServices(settingsStore: store, historyStore: history)

        configureServices()
    }

    // MARK: - Wiring

    private func configureServices() {
        services.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.coordinator.applySettingsChange()
            LaunchAtLogin.synchronise(to: self.settingsStore.settings.launchAtLogin)
        }

        services.onRecordingChanged = { [weak self] isRecording in
            self?.coordinator.setHotkeyRecording(isRecording)
        }

        services.onRequestMicrophone = { [weak self] in
            _ = await MicrophonePermission.request()
            await self?.refreshPermissions()
        }

        services.onRequestAccessibility = {
            AccessibilityPermission.request()
            AccessibilityPermission.openSystemSettings()
        }

        services.onRefreshPermissions = { [weak self] in
            await self?.refreshPermissions()
        }

        services.onStartMicTest = { [weak self] in
            guard let self else { return }
            self.coordinator.onInputLevel = { [weak self] level in
                self?.services.inputLevel = level
            }
            self.coordinator.startMicTest()
            self.services.isMicTestRunning = true
        }

        services.onStopMicTest = { [weak self] in
            self?.coordinator.stopMicTest()
            self?.services.isMicTestRunning = false
        }

        services.onFinishOnboarding = { [weak self] in
            WindowManager.shared.close(.onboarding)
            Task { await self?.coordinator.retryAfterPermissionChange() }
        }

        services.onShowMain = { [weak self] section in
            self?.showMain(section)
        }
        services.onQuit = { [weak self] in
            self?.coordinator.shutdown()
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Lifecycle

    public func bootstrap() {
        if HUDPreviewDriver.isEnabled {
            Log.lifecycle.notice("HUD preview mode — microphone and hotkeys are inactive")
            previewTask = HUDPreviewDriver.run(on: coordinator.hudForPreview)
            return
        }

        LaunchAtLogin.synchronise(to: settingsStore.settings.launchAtLogin)

        Task { @MainActor in
            await coordinator.start()
            await refreshPermissions()
            // First run: the app is invisible until the user finds the menu bar
            // icon, so setup has to come to them.
            if !settingsStore.settings.hasCompletedOnboarding {
                showOnboarding()
            }
        }
    }

    /// Permissions can only be granted outside the app, so re-check whenever we
    /// come back to the foreground rather than making the user relaunch.
    public func refreshAfterActivation() {
        Task { @MainActor in
            await refreshPermissions()
            guard coordinator.readiness != .ready else { return }
            await coordinator.retryAfterPermissionChange()
        }
    }

    func refreshPermissions() async {
        var snapshot = PermissionSnapshot()
        snapshot.microphone = MicrophonePermission.isGranted
        snapshot.accessibility = AccessibilityPermission.isGranted
        snapshot.speechModelReady = coordinator.isModelReady
        snapshot.globeKeyConflict = GlobeKeyBehaviour.conflictsWithDictation
        let availability = FoundationModelsRefiner.availability
        snapshot.onDeviceModelNote = availability.isAvailable ? nil : availability.userMessage
        services.permissions = snapshot
    }

    // MARK: - Windows

    public func showOnboarding() {
        WindowManager.shared.show(
            .onboarding,
            title: "Set up Masterful",
            size: CGSize(width: 660, height: 580),
            resizable: false
        ) { [services] in
            OnboardingView(services: services)
        }
    }

    public func showSettings() {
        WindowManager.shared.show(
            .settings,
            title: "Masterful Settings",
            size: CGSize(width: 560, height: 520),
            resizable: false
        ) { [services] in
            SettingsView(services: services)
        }
    }

    /// The main window, open on `section`.
    public func showMain(_ section: MainSection = .overview) {
        services.mainSection = section
        WindowManager.shared.show(
            .main,
            title: "Masterful",
            size: CGSize(width: 940, height: 620),
            minimumSize: CGSize(width: 760, height: 520),
            bridgesToolbar: true
        ) { [services] in
            MainWindowView(services: services)
        }
    }
}
