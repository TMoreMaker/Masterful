import AppKit
import MasterfulKit
import Persistence
import SwiftUI

public struct HistoryView: View {
    @Bindable var services: UIServices
    @State private var query = ""
    @State private var records: [DictationRecord] = []
    @State private var selection: DictationRecord?

    public init(services: UIServices) {
        self.services = services
    }

    public var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let selection {
                detail(for: selection)
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "text.quote",
                    description: Text("Pick a dictation to see what was said and where it went.")
                )
            }
        }
        .searchable(text: $query, prompt: "Search transcripts")
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private var list: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Hold \(services.settings.triggersDisplayString) somewhere and say something."
                        : "Try a different search.")
                )
            } else {
                List(records, id: \.persistentModelID, selection: Binding(
                    get: { selection?.persistentModelID },
                    set: { id in selection = records.first { $0.persistentModelID == id } }
                )) { record in
                    row(for: record)
                        .tag(record.persistentModelID)
                }
            }
        }
    }

    private func row(for record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: Token.Space.xxs) {
            Text(record.finalText)
                .font(Typeface.rowTitle)
                .lineLimit(2)
            HStack(spacing: Token.Space.xs) {
                Text(record.createdAt, format: .relative(presentation: .named))
                if let app = record.applicationName {
                    Text("·")
                    Text(app)
                }
                if record.wentToClipboard {
                    Text("·")
                    Image(systemName: "doc.on.clipboard")
                }
            }
            .font(Typeface.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, Token.Space.hairline)
    }

    private func detail(for record: DictationRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Space.lg) {
                Card {
                    SectionHeader("Inserted")
                    Text(record.finalText)
                        .font(Typeface.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.finalText, forType: .string)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            services.historyStore.delete(record)
                            selection = nil
                            reload()
                        }
                    }
                }

                // Only worth showing when clean-up actually changed something —
                // otherwise it is two identical paragraphs and pure noise.
                if record.rawTranscript != record.finalText {
                    Card {
                        SectionHeader(
                            "What was heard",
                            subtitle: "Before \(record.refinementMode.displayName.lowercased()) clean-up."
                        )
                        Text(record.rawTranscript)
                            .font(Typeface.rowTitle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Card {
                    SectionHeader("Details")
                    detailRow("When", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow("App", record.applicationName ?? "Unknown")
                    detailRow("Words", record.wordCount.formatted())
                    if record.wordsPerMinute > 0 {
                        detailRow("Pace", "\(Int(record.wordsPerMinute)) words / min")
                    }
                    detailRow("Engine", record.engineName)
                    detailRow("Destination", record.wentToClipboard ? "Clipboard" : "Text field")
                }
            }
            .padding(Token.Space.xl)
        }
        .background(AppSurface.background)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Typeface.secondary).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(Typeface.secondary).monospacedDigit()
        }
    }

    private func reload() {
        records = services.historyStore.search(query)
        if let selection, !records.contains(where: { $0.persistentModelID == selection.persistentModelID }) {
            self.selection = nil
        }
    }
}
