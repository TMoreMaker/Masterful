import AppKit
import InputControl
import MasterfulKit
import MasterfulUI
import SwiftUI

/// The menu bar item's menu.
///
/// The app's only permanent surface. It leads with status rather than commands,
/// because the question a menu-bar dictation tool has to answer at a glance is
/// "is this working right now" — and when the answer is no, the fix is one row
/// away rather than buried in settings.
struct MenuBarContent: View {
    @Bindable var environment: AppEnvironment

    private var coordinator: DictationCoordinator { environment.coordinator }
    // Qualified: SwiftUI declares its own `Settings` scene type.
    private var settings: MasterfulKit.Settings { environment.settingsStore.settings }

    var body: some View {
        Group {
            Text(statusText)

            if case .ready = coordinator.readiness {
                Text("Hold \(settings.triggersDisplayString) to dictate")
                if settings.enableDoubleTapLatch {
                    Text("Double-tap to keep listening")
                }
            }

            remedies

            Divider()

            Button("Open Masterful") { environment.showMain() }
                .keyboardShortcut("o")
            Button("History") { environment.showMain(.history) }
            Button("Settings…") { environment.showSettings() }
                .keyboardShortcut(",")
            Button("Run Setup Again…") { environment.showOnboarding() }

            Divider()

            Picker("Clean-up", selection: Binding(
                get: { settings.refinement },
                set: { newValue in
                    environment.settingsStore.update { $0.refinement = newValue }
                }
            )) {
                ForEach(RefinementMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Divider()

            Button("Quit Masterful") {
                coordinator.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var remedies: some View {
        switch coordinator.readiness {
        case .needsAccessibility:
            Divider()
            Button("Grant Accessibility access…") {
                AccessibilityPermission.request()
                AccessibilityPermission.openSystemSettings()
            }
        case .needsMicrophone:
            Divider()
            Button("Open Privacy settings…") {
                NSWorkspace.shared.open(URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )!)
            }
        case .failed:
            Divider()
            Button("Try again") { environment.refreshAfterActivation() }
        case .ready, .starting, .downloadingModel:
            EmptyView()
        }

        // Only meaningful when the user actually bound the Globe key.
        let usesGlobe = settings.triggers.contains {
            if case .modifier(.function) = $0.trigger { true } else { false }
        }
        if usesGlobe, GlobeKeyBehaviour.conflictsWithDictation {
            Divider()
            Button("Globe key is set to “\(GlobeKeyBehaviour.current.displayName)” — fix…") {
                GlobeKeyBehaviour.openKeyboardSettings()
            }
        }
    }

    private var statusText: String {
        switch coordinator.readiness {
        case .starting: "Starting…"
        case .downloadingModel: "Preparing speech model…"
        case .ready:
            switch coordinator.phase {
            case .idle: "Ready"
            case .listening(let mode): mode == .latched ? "Listening (continuous)" : "Listening"
            case .transcribing, .refining: "Transcribing…"
            case .inserting: "Inserting…"
            case .delivered: "Inserted"
            case .failed(let error): error.userMessage
            case .blocked(let reason): reason.userMessage
            }
        case .needsAccessibility: "Needs Accessibility access"
        case .needsMicrophone: "Needs microphone access"
        case .failed(let reason): reason
        }
    }
}
