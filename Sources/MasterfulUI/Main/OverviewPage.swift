import Charts
import MasterfulKit
import Persistence
import SwiftUI

/// Is recognition getting better? Answered from the fixes you make after
/// dictating, week against week.
struct OverviewPage: View {
    @Bindable var services: UIServices
    @State private var weeks: [WeekSummary] = []
    @State private var topFixes: [RecurringCorrection] = []
    @State private var measure: Measure = .misheard
    @State private var hovered: Date?

    enum Measure: String, CaseIterable, Identifiable {
        case misheard, punctuation
        var id: String { rawValue }
        var title: String { self == .misheard ? "Misheard words" : "Punctuation fixes" }
        func value(_ week: WeekSummary) -> Double? {
            self == .misheard ? week.misheardPer100 : week.punctuationPer100
        }
    }

    private var thisWeek: WeekSummary? { weeks.last }
    private var lastWeek: WeekSummary? { weeks.dropLast().last }
    private var hasAnyData: Bool { weeks.contains { $0.watchedDictations > 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Token.Space.lg) {
                HStack(alignment: .top, spacing: Token.Space.md) {
                    rateTile(.misheard)
                    rateTile(.punctuation)
                    Card {
                        StatBlock(
                            value: (thisWeek?.dictations ?? 0).formatted(),
                            label: "Dictations this week",
                            caption: "\((thisWeek?.watchedDictations ?? 0).formatted()) followed for fixes"
                        )
                    }
                }

                if hasAnyData {
                    chart
                    fixes
                } else {
                    Card {
                        ContentUnavailableView(
                            "Nothing counted yet",
                            systemImage: "character.cursor.ibeam",
                            description: Text("Dictate into a text field, then fix anything it got wrong before you move on. Each fix shows up here, and the weekly figures start from there.")
                        )
                    }
                }
            }
            .padding(Token.Space.xl)
        }
        .background(AppSurface.background)
        .navigationSubtitle("Counted from the fixes you make straight after dictating")
        .onAppear(perform: reload)
        .onChange(of: services.historyStore.revision) { _, _ in reload() }
    }

    // MARK: - Tiles

    private func rateTile(_ measure: Measure) -> some View {
        let now = thisWeek.flatMap(measure.value)
        let before = lastWeek.flatMap(measure.value)
        return Card {
            StatBlock(
                value: now.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                label: "\(measure.title) per 100"
            )
            Trend(now: now, before: before)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("\(measure.title) per 100 words", subtitle: "Last eight weeks. Lower is better.")
                Picker("Measure", selection: $measure) {
                    ForEach(Measure.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Chart(weeks) { week in
                if let value = measure.value(week) {
                    BarMark(
                        x: .value("Week", week.weekStart, unit: .weekOfYear),
                        y: .value(measure.title, value),
                        width: .ratio(0.55)
                    )
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    // The current week is still filling in, so it is drawn as
                    // provisional rather than as a result.
                    .foregroundStyle(AppSurface.accent.opacity(
                        hovered != nil && hovered != week.weekStart ? Token.Opacity.subtle
                            : week.id == thisWeek?.id ? Token.Opacity.muted : Token.Opacity.full
                    ))
                }
                if let hovered, hovered == week.weekStart {
                    RuleMark(x: .value("Week", week.weekStart, unit: .weekOfYear))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(for: week)
                        }
                }
            }
            .chartXAxis {
                // A stride rather than the weeks themselves: a centred label sits
                // between its tick and the next, so the last week needs a tick
                // after it or its label is silently dropped.
                AxisMarks(values: .stride(by: .weekOfYear)) { value in
                    if let date = value.as(Date.self), date == thisWeek?.weekStart {
                        AxisValueLabel("This week", centered: true)
                    } else {
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                    }
                }
            }
            // Runs to the end of the current week, so its bar and label have the
            // same room as every other week's.
            .chartXScale(domain: (weeks.first?.weekStart ?? .now)...(thisWeek.map { $0.weekStart.addingTimeInterval(7 * 86_400) } ?? .now))
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(AppSurface.separator)
                    AxisValueLabel()
                }
            }
            .chartXSelection(value: Binding(
                get: { hovered },
                set: { date in
                    hovered = date.flatMap { date in
                        weeks.last { $0.weekStart <= date }?.weekStart
                    }
                }
            ))
            .frame(height: 200)
            .padding(.top, Token.Space.xl)
            .accessibilityLabel("\(measure.title) per 100 words by week")
        }
    }

    private func tooltip(for week: WeekSummary) -> some View {
        VStack(alignment: .leading, spacing: Token.Space.hairline) {
            Text(week.id == thisWeek?.id
                ? "This week, so far"
                : "Week of \(week.weekStart.formatted(.dateTime.day().month(.wide)))")
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
            Text(measure.value(week).map { "\($0.formatted(.number.precision(.fractionLength(1)))) per 100" } ?? "No data")
                .font(Typeface.secondaryEmphasised)
            Text("\(week.watchedDictations) of \(week.dictations) dictations followed")
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Token.Space.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Token.Radius.sm, style: .continuous))
    }

    // MARK: - Fixes

    private var fixes: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Most frequent fixes")
                Button("Show All") { services.mainSection = .corrections }
                    .buttonStyle(.link)
            }
            if topFixes.isEmpty {
                Text("No misheard words fixed yet.")
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topFixes) { fix in
                    HStack {
                        CorrectionPair(heard: fix.heard, written: fix.written)
                        Spacer()
                        Text("×\(fix.count)")
                            .font(Typeface.secondary)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reload() {
        weeks = services.historyStore.weeklySummaries(weeks: 8)
        topFixes = Array(services.historyStore.recurringCorrections(kind: .word, limit: 5))
    }
}

/// This week against last, with the direction spelled out — never colour alone.
struct Trend: View {
    let now: Double?
    let before: Double?

    var body: some View {
        Group {
            if let now, let before {
                let change = now - before
                let amount = abs(change).formatted(.number.precision(.fractionLength(1)))
                if abs(change) < 0.05 {
                    Label("Same as last week", systemImage: "equal")
                        .foregroundStyle(.secondary)
                } else if change < 0 {
                    Label("\(amount) fewer than last week", systemImage: "arrow.down.right")
                        .foregroundStyle(Palette.success)
                } else {
                    Label("\(amount) more than last week", systemImage: "arrow.up.right")
                        .foregroundStyle(Palette.warning)
                }
            } else {
                Label("No comparison yet", systemImage: "minus")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(Typeface.caption)
    }
}

/// "paint → page", with the side Masterful got wrong struck through.
struct CorrectionPair: View {
    let heard: String
    let written: String

    var body: some View {
        HStack(spacing: Token.Space.xs) {
            Text(heard.isEmpty ? "(missing)" : heard)
                .strikethrough(!heard.isEmpty)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(Typeface.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("became")
            Text(written.isEmpty ? "(deleted)" : written)
        }
        .font(Typeface.rowTitle)
    }
}
