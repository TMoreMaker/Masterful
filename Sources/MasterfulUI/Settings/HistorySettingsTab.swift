import MasterfulKit
import Persistence
import SwiftUI

struct HistorySettingsTab: View {
    @Bindable var services: UIServices
    @State private var stats = DictationStats()
    @State private var confirmingDelete = false

    private static let retentionOptions: [Int?] = [7, 30, 90, 365, nil]

    var body: some View {
        SettingsPane {
            Card {
                SectionHeader("What you've dictated")
                HStack(alignment: .top, spacing: Token.Space.lg) {
                    StatBlock(value: stats.totalWords.formatted(), label: "Words")
                    StatBlock(value: stats.sessionCount.formatted(), label: "Dictations")
                    StatBlock(
                        value: stats.averageWordsPerMinute > 0
                            ? "\(Int(stats.averageWordsPerMinute))" : "—",
                        label: "Words / min"
                    )
                    StatBlock(
                        value: Self.duration(stats.estimatedTimeSaved),
                        label: "Time saved",
                        // Presented as an estimate because it is one: it assumes
                        // a typing speed rather than measuring the user's.
                        caption: "est. vs typing at \(Int(HistoryStore.assumedTypingWordsPerMinute)) wpm"
                    )
                }
                if stats.currentStreak > 1 {
                    Text("\(stats.currentStreak) days in a row.")
                        .font(Typeface.secondary)
                        .foregroundStyle(.secondary)
                }
                Button("Open History") { services.onShowMain(.history) }
                .padding(.top, Token.Space.xxs)
            }

            Card {
                SettingRow(
                    "Keep a history",
                    help: "Transcripts only. Masterful never stores your audio."
                ) {
                    Toggle("", isOn: Binding(
                        get: { services.settings.historyEnabled },
                        set: { v in services.update { $0.historyEnabled = v } }
                    ))
                    .labelsHidden()
                }

                if services.settings.historyEnabled {
                    Divider()
                    SettingRow("Keep for", help: "Older entries are deleted automatically.") {
                        Picker("", selection: Binding(
                            get: { services.settings.historyRetentionDays },
                            set: { v in services.update { $0.historyRetentionDays = v } }
                        )) {
                            ForEach(Self.retentionOptions, id: \.self) { option in
                                Text(option.map { "\($0) days" } ?? "Forever").tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
            }

            Card {
                SectionHeader(
                    "Delete everything",
                    subtitle: "Removes every stored transcript and statistic. This cannot be undone."
                )
                if confirmingDelete {
                    HStack {
                        Button("Delete all history", role: .destructive) {
                            services.historyStore.deleteAllRecords()
                            confirmingDelete = false
                            reload()
                        }
                        Button("Cancel") { confirmingDelete = false }
                    }
                } else {
                    Button("Delete all history…") { confirmingDelete = true }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        stats = services.historyStore.stats()
    }

    private static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
    }
}
