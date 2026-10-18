import AppKit
import InputControl
import MasterfulKit
import SwiftUI

public struct OnboardingView: View {
    @Bindable var services: UIServices
    @State private var step: OnboardingStep
    @State private var levelHistory = [Float](repeating: 0, count: Token.Size.levelHistory)
    @State private var practiceText = ""
    @State private var pollTask: Task<Void, Never>?

    /// `initialStep` exists for `WindowPreview`; the app always starts at Welcome.
    public init(services: UIServices, initialStep: OnboardingStep = .welcome) {
        self.services = services
        _step = State(initialValue: initialStep)
    }

    public var body: some View {
        VStack(spacing: 0) {
            progress
            content
            footer
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(AppSurface.background)
        .tint(AppSurface.accent)
        .task { await beginPermissionPolling() }
        .onDisappear {
            pollTask?.cancel()
            services.onStopMicTest()
        }
    }

    // MARK: - Chrome

    private var progress: some View {
        VStack(spacing: Token.Space.sm) {
            HStack(spacing: Token.Space.xxs) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { candidate in
                    Capsule()
                        .fill(candidate.rawValue <= step.rawValue
                              ? AppSurface.accent
                              : AppSurface.separator)
                        .frame(height: 3)
                }
            }
            .animation(Motion.honouringPreferences(Motion.content), value: step)
        }
        .padding(.horizontal, Token.Space.xxl)
        .padding(.top, Token.Space.xxl)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Space.lg) {
                VStack(alignment: .leading, spacing: Token.Space.sm) {
                    Text(step.title)
                        .font(Typeface.screenTitle)
                    Text(step.subtitle)
                        .font(Typeface.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                stepBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Token.Space.xxl)
            .padding(.vertical, Token.Space.xl)
            // Slide in the direction of travel, so moving back feels like
            // moving back rather than like a different screen appearing.
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .frame(maxHeight: .infinity)
        .animation(Motion.honouringPreferences(Motion.content), value: step)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
                    .controlSize(.large)
            }
            Spacer()
            if step.isOptional, step != .ready, step != .welcome {
                Button("Skip") { move(1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button(primaryTitle) { primaryAction() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
        }
        .padding(Token.Space.xxl)
        // A card-coloured band with a hairline, rather than `.bar`: the bar
        // material is a neutral grey, which read as a stray system panel at
        // the foot of a warm window.
        .background(AppSurface.card)
        .overlay(alignment: .top) {
            Rectangle().fill(AppSurface.separator).frame(height: 0.5)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get started"
        case .ready: "Finish"
        default: "Continue"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .microphone: services.permissions.microphone
        case .accessibility: services.permissions.accessibility
        case .speechModel: services.permissions.speechModelReady
        default: true
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome: welcomeStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .speechModel: speechModelStep
        case .hotkey: hotkeyStep
        case .cleanup: cleanupStep
        case .practice: practiceStep
        case .ready: readyStep
        }
    }

    private var welcomeStep: some View {
        Card {
            ForEach(Array(welcomePoints.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: Token.Space.md) {
                    Image(systemName: point.symbol)
                        .font(Typeface.listSymbol)
                        .foregroundStyle(AppSurface.accentText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: Token.Space.hairline) {
                        Text(point.title).font(Typeface.rowTitleEmphasised)
                        Text(point.detail)
                            .font(Typeface.secondary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var welcomePoints: [(symbol: String, title: String, detail: String)] {
        [
            ("lock.laptopcomputer", "Everything stays local",
             "Speech is transcribed on this Mac by Apple's on-device model. No account, no upload, no subscription."),
            ("bolt.fill", "Fast enough to think in",
             "Text usually lands under a second after you let go of the key."),
            ("text.cursor", "Works in any text field",
             "Mail, Slack, your editor, a browser — anywhere you can type."),
        ]
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: Token.Space.lg) {
            Card {
                RequirementRow(
                    title: "Microphone access",
                    detail: services.permissions.microphone
                        ? "Granted."
                        : "macOS will ask you once. Masterful cannot transcribe without it.",
                    state: services.permissions.microphone ? .good : .waiting,
                    actionTitle: "Allow…",
                    action: { Task { await services.onRequestMicrophone() } }
                )
            }

            if services.permissions.microphone {
                Card {
                    SectionHeader("Check your input", subtitle: "Say something — the bars should move.")
                    // Wider than the HUD's four bars: there is room here, and this is
                    // the one screen whose job is to prove the microphone works.
                    WaveformView(samples: levelHistory, tint: AppSurface.bloom, bars: 12)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Token.Space.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                                .fill(AppSurface.background)
                        )
                    Text("Masterful follows your system input device, and keeps up if you switch mid-sentence.")
                        .font(Typeface.secondary)
                        .foregroundStyle(.secondary)
                }
                .onAppear { services.onStartMicTest() }
                .onDisappear { services.onStopMicTest() }
                .onChange(of: services.inputLevel) { _, level in
                    levelHistory.removeFirst()
                    levelHistory.append(min(1, max(level.rms, level.peak * 0.7)))
                }
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: Token.Space.lg) {
            Card {
                RequirementRow(
                    title: "Accessibility access",
                    detail: services.permissions.accessibility
                        ? "Granted."
                        : "Open System Settings, then switch Masterful on under Accessibility. This window updates on its own.",
                    state: services.permissions.accessibility ? .good : .waiting,
                    actionTitle: "Open System Settings…",
                    action: services.onRequestAccessibility
                )
            }

            Card {
                SectionHeader("Why this one is unavoidable")
                Text("""
                Two things need it: watching for your dictation key anywhere on the \
                system, and placing text into another app's text field. macOS offers \
                no narrower permission for either.

                Masterful does not read what you type. It compares each key against \
                your chosen shortcut and ignores everything else — and it refuses to \
                listen at all while a password field has focus.
                """)
                .font(Typeface.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var speechModelStep: some View {
        Card {
            RequirementRow(
                title: "On-device speech model",
                detail: services.permissions.speechModelReady
                    ? "Installed and ready."
                    : "Downloading from Apple. This happens once.",
                state: services.permissions.speechModelReady ? .good : .waiting
            )
            if !services.permissions.speechModelReady {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: Token.Space.lg) {
            Card {
                SectionHeader(
                    "Hold to dictate",
                    subtitle: "Add one for each setup — the built-in keyboard now, a mouse button for when the laptop is closed."
                )
                TriggerListEditor(
                    triggers: Binding(
                        get: { services.settings.triggers },
                        set: { newValue in services.update { $0.triggers = newValue } }
                    ),
                    onRecordingChanged: services.onRecordingChanged
                )
            }

            Card {
                SettingRow(
                    "Double-tap to keep listening",
                    help: "Tap twice and Masterful stays on until you press again — for anything longer than a sentence."
                ) {
                    Toggle("", isOn: Binding(
                        get: { services.settings.enableDoubleTapLatch },
                        set: { newValue in services.update { $0.enableDoubleTapLatch = newValue } }
                    ))
                    .labelsHidden()
                }
            }
        }
    }

    private var cleanupStep: some View {
        Card {
            ForEach(RefinementMode.allCases, id: \.self) { mode in
                cleanupOption(mode)
                if mode != RefinementMode.allCases.last {
                    Divider()
                }
            }
        }
    }

    private func cleanupOption(_ mode: RefinementMode) -> some View {
        let isSelected = services.settings.refinement == mode
        let note = RefinerFactoryNote.note(for: mode, services: services)
        return Button {
            services.update { $0.refinement = mode }
        } label: {
            HStack(alignment: .top, spacing: Token.Space.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AppSurface.accent : Color.secondary)
                VStack(alignment: .leading, spacing: Token.Space.hairline) {
                    Text(mode.displayName).font(Typeface.rowTitleEmphasised)
                    Text(cleanupDescription(mode))
                        .font(Typeface.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        InlineNotice(.warning, note, prominence: .note)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cleanupDescription(_ mode: RefinementMode) -> String {
        switch mode {
        case .off: "Insert exactly what was heard."
        case .rules: "Punctuation, capitalisation and filler removal. Predictable, instant, no model."
        case .onDevice: "Apple's on-device model tidies the sentence. Still never leaves this Mac."
        case .remote: "Use your own Claude or Gemini key. The only setting that sends text off this Mac."
        }
    }

    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: Token.Space.lg) {
            Card {
                HStack(spacing: Token.Space.sm) {
                    Text("Hold")
                        .font(Typeface.rowTitle)
                        .foregroundStyle(.secondary)
                    KeyCapView(shortcut: services.settings.primaryTrigger, isEmphasised: true)
                    Text("and say anything")
                        .font(Typeface.rowTitle)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $practiceText)
                    .font(Typeface.body)
                    .scrollContentBackground(.hidden)
                    .padding(Token.Space.sm)
                    .frame(height: 120)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                            .fill(AppSurface.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous)
                            .strokeBorder(AppSurface.separator, lineWidth: 0.5)
                    )
                    .accentFocusRing(cornerRadius: Token.Radius.sm)

                if practiceWordCount >= 2 {
                    HStack(spacing: Token.Space.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.success)
                        Text("That's it. It works the same way in every other app.")
                            .font(Typeface.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.honouringPreferences(Motion.content), value: practiceWordCount >= 2)

            if !services.permissions.allGranted {
                InlineNotice(.warning, "Grant the permissions above first — dictation is not active yet.")
            }
        }
    }

    private var practiceWordCount: Int {
        practiceText.split(whereSeparator: \.isWhitespace).count
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: Token.Space.lg) {
            Card {
                HStack(spacing: Token.Space.md) {
                    Image(systemName: "waveform")
                        .font(Typeface.featureSymbol)
                        .foregroundStyle(AppSurface.accentText)
                    VStack(alignment: .leading, spacing: Token.Space.hairline) {
                        Text("Hold \(services.settings.triggersDisplayString) anywhere")
                            .font(Typeface.rowTitleEmphasised)
                        Text("Settings, history and stats live in the menu bar icon.")
                            .font(Typeface.secondary)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Card {
                SettingRow("Launch at login", help: "Masterful starts with your Mac.") {
                    Toggle("", isOn: Binding(
                        get: { services.settings.launchAtLogin },
                        set: { newValue in services.update { $0.launchAtLogin = newValue } }
                    ))
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Navigation

    private func primaryAction() {
        if step == .ready {
            services.update { $0.hasCompletedOnboarding = true }
            services.onFinishOnboarding()
            return
        }
        move(1)
    }

    private func move(_ delta: Int) {
        let next = step.rawValue + delta
        guard let target = OnboardingStep(rawValue: next) else { return }
        step = target
    }

    /// Permissions are granted outside the app, so the only way to notice is to
    /// keep asking. A second is responsive without being wasteful, and it means
    /// the user never has to come back and click a refresh button.
    private func beginPermissionPolling() async {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await services.onRefreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// Small indirection so the onboarding view does not import `Refinement`.
enum RefinerFactoryNote {
    @MainActor
    static func note(for mode: RefinementMode, services: UIServices) -> String? {
        switch mode {
        case .off, .rules: nil
        case .onDevice: services.permissions.onDeviceModelNote
        case .remote: "Requires an API key — add it in Settings."
        }
    }
}
