import MasterfulKit
import Persistence
import SwiftUI

/// Every fix you have made, grouped, so the ones that keep happening stand out
/// — and a name the recogniser keeps getting wrong is one click from the
/// vocabulary that fixes it.
struct CorrectionsPage: View {
    @Bindable var services: UIServices
    @State private var kind: CorrectionKind = .word
    @State private var rows: [RecurringCorrection] = []
    @State private var selection: Set<RecurringCorrection.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Space.lg) {
            Text(subtitle)
                .font(Typeface.secondary)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], Token.Space.xl)

            if rows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "character.cursor.ibeam",
                    description: Text("Fixes you make straight after a dictation are listed here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Masterful wrote") { row in
                        Text(row.heard.isEmpty ? "(missing)" : row.heard)
                            .strikethrough(!row.heard.isEmpty)
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("You changed it to") { row in
                        Text(row.written.isEmpty ? "(deleted)" : row.written)
                    }
                    TableColumn("Times") { row in
                        Text(row.count.formatted()).monospacedDigit()
                    }
                    .width(56)
                    TableColumn("Last") { row in
                        Text(row.lastSeen, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 110)
                }
                .contextMenu(forSelectionType: RecurringCorrection.ID.self) { ids in
                    menu(for: rows.filter { ids.contains($0.id) })
                }
                .padding([.horizontal, .bottom], Token.Space.xl)
            }
        }
        .background(AppSurface.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Kind", selection: $kind) {
                    Text("Words").tag(CorrectionKind.word)
                    Text("Punctuation").tag(CorrectionKind.punctuation)
                    Text("Rewrites").tag(CorrectionKind.rewrite)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onAppear(perform: reload)
        .onChange(of: kind) { _, _ in reload() }
        .onChange(of: services.historyStore.revision) { _, _ in reload() }
    }

    private var subtitle: String {
        switch kind {
        case .word: "Words the recogniser got wrong. These are what the weekly figure counts."
        case .punctuation: "Same words, different punctuation or capitals."
        case .rewrite: "Passages you rewrote. Not counted against recognition."
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .word: "No misheard words yet"
        case .punctuation: "No punctuation fixes yet"
        case .rewrite: "No rewrites yet"
        }
    }

    @ViewBuilder
    private func menu(for selected: [RecurringCorrection]) -> some View {
        if selected.count == 1, let row = selected.first, row.kind == .word, !row.written.isEmpty {
            Button("Add “\(row.written)” to Vocabulary") {
                services.historyStore.addVocabulary(row.written)
            }
            Divider()
        }
        if selected.contains(where: { $0.kind != .rewrite }) {
            Button("Not a Mishearing") {
                selected.forEach { services.historyStore.reclassify($0, as: .rewrite) }
            }
        } else if !selected.isEmpty {
            Button("Count as Misheard Words") {
                selected.forEach { services.historyStore.reclassify($0, as: .word) }
            }
        }
    }

    private func reload() {
        rows = services.historyStore.recurringCorrections(kind: kind)
        selection = selection.filter { id in rows.contains { $0.id == id } }
    }
}

extension CorrectionKind {
    var displayName: String {
        switch self {
        case .word: "Misheard"
        case .punctuation: "Punctuation"
        case .rewrite: "Rewrite"
        }
    }
}
