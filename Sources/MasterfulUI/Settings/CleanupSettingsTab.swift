import AppKit
import MasterfulKit
import Refinement
import SwiftUI

struct CleanupSettingsTab: View {
    @Bindable var services: UIServices
    @State private var apiKeyDraft = ""
    @State private var keyStatus: KeyStatus = .idle

    private enum KeyStatus: Equatable {
        case idle, checking, valid, invalid
    }

    var body: some View {
        SettingsPane {
            Card {
                SectionHeader(
                    "Clean-up",
                    subtitle: "Masterful discards any rewrite that adds to what you meant, changes a number, or answers you instead of writing you down."
                )
                ForEach(RefinementMode.allCases, id: \.self) { mode in
                    modeRow(mode)
                    if mode != RefinementMode.allCases.last { Divider() }
                }
            }

            if services.settings.refinement == .remote {
                remoteKeyCard
            }

            Card {
                SectionHeader(
                    "Per-app style",
                    subtitle: "Masterful knows which app you’re dictating into. The same thought belongs in different words in a terminal, an email and a text message."
                )
                SettingRow("Default", help: "Used when an app has no rule of its own.") {
                    Picker("", selection: Binding(
                        get: { services.settings.defaultProfile },
                        set: { v in services.update { $0.defaultProfile = v } }
                    )) {
                        ForEach(FormattingProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Divider()
                appProfileList
            }
        }
    }

    // MARK: - Mode

    private func modeRow(_ mode: RefinementMode) -> some View {
        let isSelected = services.settings.refinement == mode
        let note = RefinerFactory.availabilityNote(
            for: mode, provider: services.settings.remoteProvider
        )
        return Button {
            services.update { $0.refinement = mode }
        } label: {
            HStack(alignment: .top, spacing: Token.Space.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AppSurface.accent : Color.secondary)
                VStack(alignment: .leading, spacing: Token.Space.hairline) {
                    Text(mode.displayName).font(.system(size: 12, weight: .medium))
                    Text(description(for: mode))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note).font(.system(size: 10)).foregroundStyle(Palette.warning)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func description(for mode: RefinementMode) -> String {
        switch mode {
        case .off: "Insert exactly what was heard."
        case .rules: "Punctuation, capitalisation, filler removal. Instant and predictable."
        case .onDevice: "Apple's on-device model. Nothing leaves this Mac."
        case .remote: "Your own Claude or Gemini key. The only setting that sends text off this Mac."
        }
    }

    // MARK: - Remote key

    private var remoteKeyCard: some View {
        Card {
            SectionHeader(
                "\(services.settings.remoteProvider.displayName) API key",
                subtitle: "Stored in your Keychain, never in Masterful's settings file. Only transcripts are sent, and only while this mode is selected."
            )

            Picker("Provider", selection: Binding(
                get: { services.settings.remoteProvider },
                set: { v in
                    services.update { $0.remoteProvider = v }
                    apiKeyDraft = ""
                    keyStatus = .idle
                }
            )) {
                ForEach(RemoteProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: Token.Space.sm) {
                SecureField("Paste your key", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveKey() }
                    .disabled(apiKeyDraft.isEmpty || keyStatus == .checking)
            }

            HStack(spacing: Token.Space.sm) {
                switch keyStatus {
                case .idle:
                    if Keychain.has(account: services.settings.remoteProvider.keychainAccount) {
                        StatusDot(.good)
                        Text("A key is stored.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") {
                            Keychain.remove(account: services.settings.remoteProvider.keychainAccount)
                            keyStatus = .idle
                        }
                        .controlSize(.small)
                    } else {
                        StatusDot(.bad)
                        Text("No key stored.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .valid:
                    StatusDot(.good)
                    Text("Key works.").font(.system(size: 11)).foregroundStyle(.secondary)
                case .invalid:
                    StatusDot(.bad)
                    Text("That key didn't work.").font(.system(size: 11)).foregroundStyle(Palette.danger)
                }
            }

            Link(
                "Get a \(services.settings.remoteProvider.displayName) key",
                destination: services.settings.remoteProvider.consoleURL
            )
            .font(.system(size: 11))
        }
    }

    /// Verified with a real round trip rather than a regex on the prefix. A key
    /// that looks right but does not work would otherwise fail silently, in the
    /// middle of a sentence, weeks later.
    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = services.settings.remoteProvider
        keyStatus = .checking
        Task { @MainActor in
            let ok = await RemoteRefiner.validateKey(key, provider: provider)
            if ok {
                keyStatus = .valid
                apiKeyDraft = ""
            } else {
                Keychain.remove(account: provider.keychainAccount)
                keyStatus = .invalid
            }
        }
    }

    // MARK: - Per-app

    private var appProfileList: some View {
        VStack(alignment: .leading, spacing: Token.Space.sm) {
            ForEach(sortedProfiles, id: \.bundleID) { entry in
                HStack {
                    Text(entry.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { services.settings.appProfiles[entry.bundleID] ?? .formal },
                        set: { v in services.update { $0.appProfiles[entry.bundleID] = v } }
                    )) {
                        ForEach(FormattingProfile.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    Button {
                        services.update { $0.appProfiles.removeValue(forKey: entry.bundleID) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button("Add current app…") { addFrontmostApp() }
                .controlSize(.small)
                .padding(.top, Token.Space.xxs)
        }
    }

    private var sortedProfiles: [(bundleID: String, name: String)] {
        services.settings.appProfiles.keys.sorted().map { bundleID in
            (bundleID, Self.displayName(for: bundleID))
        }
    }

    /// Resolves a bundle identifier to the app's real name where possible, so
    /// the list reads as "Slack" rather than "com.tinyspeck.slackmacgap".
    private static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// "Current app" means the last one that was frontmost, not Masterful —
    /// which is frontmost right now precisely because settings is open.
    private func addFrontmostApp() {
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard let app = candidates.first(where: { $0.isActive }) ?? candidates.first,
              let bundleID = app.bundleIdentifier
        else { return }
        services.update { $0.appProfiles[bundleID] = services.settings.defaultProfile }
    }
}
