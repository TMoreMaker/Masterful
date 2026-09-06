import Foundation
import MasterfulKit
import Refinement

// Measures transcript clean-up across every mode, against a fixed corpus.
//
//   make eval
//
// The output is deliberately two things at once: a table of numbers that can be
// diffed between runs, and the actual text, because "is this clean-up any good"
// is ultimately a judgement no metric makes for you.

@main
struct EvalTool {
    static func main() async {
        let availability = FoundationModelsRefiner.availability

        print("")
        print("Masterful — clean-up evaluation")
        print(String(repeating: "═", count: 78))
        print("Corpus: \(Corpus.cases.count) cases")
        print("On-device model: \(availability.isAvailable ? "available" : "UNAVAILABLE — \(availability.userMessage)")")
        if !availability.isAvailable {
            print("  → Only the deterministic rules are measured below.")
            print("  → Enable Apple Intelligence in System Settings, then re-run.")
        }
        print("")

        var modes: [(label: String, refiner: any Refiner)] = [
            ("rules", RefinementPipeline())
        ]
        if availability.isAvailable {
            modes.append((
                "on-device",
                RefinementPipeline(model: FoundationModelsRefiner(profile: .prose))
            ))
        }

        var totals: [String: [Metrics]] = [:]

        for (index, testCase) in Corpus.cases.enumerated() {
            print(String(repeating: "─", count: 78))
            print("\(index + 1). \(testCase.name)   [\(testCase.profile.displayName)]")
            print("   probes: \(testCase.probes)")
            print("")
            print("   input     │ \(wrap(testCase.transcript))")

            for mode in modes {
                // The profile has to be rebuilt per case: it is what tells the
                // model that a terminal must not be sentence-cased.
                // The model stage is measured with a deliberately huge budget so
                // this reports what the model actually produces and how long it
                // actually takes. Measuring through the production deadline
                // would just show the rule output every time the model was a
                // millisecond late, which tells you nothing about the model.
                let refiner: any Refiner = mode.label == "rules"
                    ? RefinementPipeline()
                    : RefinementPipeline(
                        model: FoundationModelsRefiner(profile: testCase.profile),
                        budget: .seconds(60)
                      )

                let context = RefinementContext(
                    vocabulary: ["SwiftUI", "Tlotliso", "Thabo", "Johannesburg"],
                    profile: testCase.profile
                )

                let clock = ContinuousClock()
                var output = ""
                let elapsed = await clock.measure {
                    output = await refiner.refine(testCase.transcript, context: context)
                }

                let metrics = Metrics.measure(
                    input: testCase.transcript, output: output, latency: elapsed
                )
                totals[mode.label, default: []].append(metrics)

                print("   \(pad(mode.label, 9)) │ \(wrap(output))")
                print("             │ \(summary(metrics))")
            }
            print("")
        }

        print(String(repeating: "═", count: 78))
        print("Summary")
        print("")
        print("   \(pad("mode", 10)) \(pad("p50 ms", 8)) \(pad("p95 ms", 8)) \(pad("retention", 11)) \(pad("guard ok", 9)) flags")
        for mode in modes {
            guard let measurements = totals[mode.label], !measurements.isEmpty else { continue }
            let latencies = measurements.map(\.latencyMilliseconds).sorted()
            let retention = measurements.map(\.retention).reduce(0, +) / Double(measurements.count)
            let guardOK = measurements.filter(\.passesGuard).count
            let flagged = measurements.filter { !$0.flags.isEmpty }.count

            print("   \(pad(mode.label, 10)) \(pad("\(percentile(latencies, 0.5))", 8)) \(pad("\(percentile(latencies, 0.95))", 8)) \(pad(String(format: "%.0f%%", retention * 100), 11)) \(pad("\(guardOK)/\(measurements.count)", 9)) \(flagged == 0 ? "none" : "\(flagged) case(s)")")
        }
        print("")
        if let onDevice = totals["on-device"], !onDevice.isEmpty {
            let latencies = onDevice.map(\.latencyMilliseconds).sorted()
            let productionBudget = 1_200
            let overBudget = latencies.filter { $0 > productionBudget }.count
            print("Latency against the production budget (\(productionBudget)ms):")
            print("   \(overBudget)/\(latencies.count) cases exceed it — those fall back to rules in the app.")
            print("   Set the budget from this, not the other way round: a deadline the")
            print("   model can never meet turns the whole on-device stage into dead code.")
            print("")
        }
        print("Read the two CRITICAL cases by eye: dictated speech must be formatted,")
        print("never obeyed or answered. A poem or a capital city there is a real failure.")
        print("")
    }

    // MARK: - Formatting

    static func summary(_ metrics: Metrics) -> String {
        var parts = [
            "\(metrics.latencyMilliseconds)ms",
            String(format: "retention %.0f%%", metrics.retention * 100),
            String(format: "len %.2f×", metrics.lengthRatio),
            metrics.passesGuard ? "guard ok" : "GUARD REJECT",
        ]
        if metrics.fillersRemaining > 0 { parts.append("fillers \(metrics.fillersRemaining)") }
        if !metrics.inventedWords.isEmpty {
            parts.append("new: \(metrics.inventedWords.prefix(5).joined(separator: ","))")
        }
        return parts.joined(separator: " · ")
    }

    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Wraps to the terminal's width, indenting continuations under the column.
    static func wrap(_ text: String, width: Int = 60) -> String {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.count + word.count + 1 > width {
                    lines.append(line)
                    line = String(word)
                } else {
                    line = line.isEmpty ? String(word) : line + " " + word
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n             │ ")
    }
}
