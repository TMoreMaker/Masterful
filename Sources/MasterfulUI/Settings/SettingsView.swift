import AppKit
import InputControl
import MasterfulKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var services: UIServices

    public init(services: UIServices) {
        self.services = services
    }

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab(services: services)
            }
            Tab("Dictation", systemImage: "mic") {
                DictationSettingsTab(services: services)
            }
            Tab("Clean-up", systemImage: "wand.and.sparkles") {
                CleanupSettingsTab(services: services)
            }
            Tab("Vocabulary", systemImage: "character.book.closed") {
                VocabularySettingsTab(services: services)
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistorySettingsTab(services: services)
            }
        }
        .frame(width: 560, height: 520)
        .task { await services.onRefreshPermissions() }
    }
}

/// Shared scaffolding so every tab scrolls and pads identically.
struct SettingsPane<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Space.lg) {
                content
            }
            .padding(Token.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppSurface.background)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Bindable var services: UIServices

    var body: some View {
        SettingsPane {
            Card {
                SettingRow("Launch at login", help: "Start Masterful when you log in.") {
                    Toggle("", isOn: binding(\.launchAtLogin)).labelsHidden()
                }
                Divider()
                SettingRow("Play sounds", help: "A quiet cue when dictation starts and finishes.") {
                    Toggle("", isOn: binding(\.soundEffects)).labelsHidden()
                }
            }

            Card {
                SectionHeader("Where the HUD appears")
                Picker("", selection: binding(\.hudAnchor)) {
                    ForEach(HUDAnchor.allCases, id: \.self) { anchor in
                        Text(anchor.displayName).tag(anchor)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            Card {
                SectionHeader("Permissions")
                RequirementRow(
                    title: "Microphone",
                    detail: services.permissions.microphone ? "Granted" : "Not granted",
                    state: services.permissions.microphone ? .good : .bad,
                    actionTitle: "Allow…",
                    action: { Task { await services.onRequestMicrophone() } }
                )
                Divider()
                RequirementRow(
                    title: "Accessibility",
                    detail: services.permissions.accessibility ? "Granted" : "Not granted",
                    state: services.permissions.accessibility ? .good : .bad,
                    actionTitle: "Open Settings…",
                    action: services.onRequestAccessibility
                )
            }

            Card {
                SectionHeader("Masterful \(Bundle.main.shortVersion)")
                HStack {
                    Button("Run setup again") {
                        WindowManager.shared.close(.settings)
                        WindowManager.shared.show(
                            .onboarding, title: "Set up Masterful",
                            size: CGSize(width: 660, height: 560), resizable: false
                        ) { OnboardingView(services: services) }
                    }
                    Spacer()
                    Button("Quit Masterful", role: .destructive, action: services.onQuit)
                }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<MasterfulKit.Settings, T>) -> Binding<T> {
        Binding(
            get: { services.settings[keyPath: path] },
            set: { newValue in services.update { $0[keyPath: path] = newValue } }
        )
    }
}

// MARK: - Dictation

struct DictationSettingsTab: View {
    @Bindable var services: UIServices

    var body: some View {
        SettingsPane {
            Card {
                SectionHeader(
                    "Hold to dictate",
                    subtitle: "All of these work at once — a key, a chord, or a mouse button. Add one for each setup you use."
                )
                TriggerListEditor(
                    triggers: binding(\.triggers),
                    onRecordingChanged: services.onRecordingChanged
                )
            }

            Card {
                SettingRow(
                    "Double-tap to keep listening",
                    help: "Tap twice and Masterful stays on until you press again."
                ) {
                    Toggle("", isOn: binding(\.enableDoubleTapLatch)).labelsHidden()
                }

                if services.settings.enableDoubleTapLatch {
                    Divider()
                    SettingRow(
                        "Double-tap window",
                        help: "How quickly the second tap must follow. \(services.settings.doubleTapWindowMilliseconds) ms."
                    ) {
                        Slider(
                            value: Binding(
                                get: { Double(services.settings.doubleTapWindowMilliseconds) },
                                set: { v in services.update { $0.doubleTapWindowMilliseconds = Int(v) } }
                            ),
                            in: 180...600, step: 20
                        )
                        .frame(width: 160)
                    }
                    Divider()
                    SettingRow(
                        "Minimum hold",
                        help: "Presses shorter than this count as a tap. \(services.settings.minimumHoldMilliseconds) ms."
                    ) {
                        Slider(
                            value: Binding(
                                get: { Double(services.settings.minimumHoldMilliseconds) },
                                set: { v in services.update { $0.minimumHoldMilliseconds = Int(v) } }
                            ),
                            in: 100...500, step: 20
                        )
                        .frame(width: 160)
                    }
                }
            }

            Card {
                SettingRow(
                    "Spoken commands",
                    help: "Say “\(services.settings.voiceCommandPrefix) enter” to press Return, “\(services.settings.voiceCommandPrefix) delete” to erase. Essential with the lid closed."
                ) {
                    Toggle("", isOn: binding(\.voiceCommandsEnabled)).labelsHidden()
                }

                if services.settings.voiceCommandsEnabled {
                    Divider()
                    SettingRow(
                        "Command word",
                        help: "Only counts when a known command follows it, so ordinary speech is never swallowed."
                    ) {
                        TextField("", text: binding(\.voiceCommandPrefix))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: Token.Space.xxs) {
                        Text("Available commands")
                            .font(.system(size: 11, weight: .medium))
                        ForEach(VoiceCommand.allCases, id: \.self) { command in
                            HStack {
                                Text("“\(services.settings.voiceCommandPrefix) \(command.phrases[0])”")
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text(command.displayName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Card {
                SectionHeader(
                    "How text is inserted",
                    subtitle: "Automatic tries Accessibility, then paste, then simulated typing. Change this only if a specific app misbehaves."
                )
                Picker("", selection: binding(\.insertion)) {
                    ForEach(InsertionStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<MasterfulKit.Settings, T>) -> Binding<T> {
        Binding(
            get: { services.settings[keyPath: path] },
            set: { newValue in services.update { $0[keyPath: path] = newValue } }
        )
    }
}
