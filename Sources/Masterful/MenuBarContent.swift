import AppKit
import InputControl
import MasterfulKit
import MasterfulUI
import SwiftUI

/// Feeds the menu bar panel from the running app.
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

    /// What Work mode is doing, while it is on. Says plainly when Apple's
    /// recogniser is standing in, so a dictation is never silently taken by the
    /// engine the user did not choose.
    private var workModeNote: String? {
        guard settings.workMode else { return nil }
        switch coordinator.whisperStatus {
        case .ready:
            return "Whisper on this Mac · clean-up locked to Tidy"
        case .downloading(let fraction):
            return "Downloading Whisper \(Int(fraction * 100))% · Apple until ready"
        case .loading:
            return "Preparing Whisper · Apple until ready"
        case .failed:
            return "Whisper unavailable · using Apple · clean-up locked to Tidy"
        case .off:
            return nil
        }
    }

    private var hint: String? {
        guard case .ready = coordinator.readiness else { return nil }
        let hold = "Hold \(settings.triggersDisplayString) to dictate"
        return settings.enableDoubleTapLatch ? hold + "\nDouble-tap to keep listening" : hold
    }

    var body: some View {
        MenuBarPanel(model: MenuBarPanelModel(
            status: statusText,
            hint: hint,
            remedies: remedies,
            workMode: settings.workMode,
            workModeNote: workModeNote,
            setWorkMode: { coordinator.setWorkMode($0) },
            refinement: settings.refinement,
            setRefinement: { newValue in
                environment.settingsStore.update { $0.refinement = newValue }
            },
            lastDictation: coordinator.lastDictation,
            commands: [
                .init(title: "Open Masterful", key: "o") { environment.showMain() },
                .init(title: "History") { environment.showMain(.history) },
                .init(title: "Settings…", key: ",") { environment.showSettings() },
                .init(title: "Run Setup Again…") { environment.showOnboarding() },
                .init(title: "Quit Masterful", key: "q") {
                    coordinator.shutdown()
                    NSApplication.shared.terminate(nil)
                },
            ]
        ))
    }

    private var remedies: [MenuBarPanelModel.Remedy] {
        var remedies: [MenuBarPanelModel.Remedy] = []
        switch coordinator.readiness {
        case .needsAccessibility:
            remedies.append(.init(title: "Grant Accessibility access…") {
                AccessibilityPermission.request()
                AccessibilityPermission.openSystemSettings()
            })
        case .needsMicrophone:
            remedies.append(.init(title: "Open Privacy settings…") {
                NSWorkspace.shared.open(URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )!)
            })
        case .failed:
            remedies.append(.init(title: "Try again") { environment.refreshAfterActivation() })
        case .ready, .starting, .downloadingModel:
            break
        }

        // Only meaningful when the user actually bound the Globe key.
        let usesGlobe = settings.triggers.contains {
            if case .modifier(.function) = $0.trigger { true } else { false }
        }
        if usesGlobe, GlobeKeyBehaviour.conflictsWithDictation {
            remedies.append(.init(title: "Globe key is set to “\(GlobeKeyBehaviour.current.displayName)” — fix…") {
                GlobeKeyBehaviour.openKeyboardSettings()
            })
        }
        return remedies
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
