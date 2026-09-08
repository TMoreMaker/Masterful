import AVFoundation
import Foundation
import Speech

// Measures *recognition* accuracy — which locale's acoustic model actually hears
// this speaker correctly — as opposed to `masterful-eval`, which measures the
// clean-up applied afterwards.
//
//   make record      read the passages aloud, once
//   make eval-asr    replay that recording through every installed model
//
// The two-step shape is the whole idea. Comparing recognisers by dictating the
// same paragraph into each of them in turn compares the readings as much as the
// models. Recording once and replaying holds the audio fixed, so the only thing
// that varies is the thing under test.

@main
struct ASREvalTool {

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "run"

        do {
            switch command {
            case "record": try await record(only: arguments.dropFirst().first)
            case "run":    try await run(arguments: Array(arguments.dropFirst()))
            case "list":   try list()
            default:
                print("Usage: masterful-asr-eval [record|run|list]")
                exit(2)
            }
        } catch {
            print("\n\(error)")
            exit(1)
        }
    }

    // MARK: - list

    static func list() throws {
        let passages = try EvalPaths.load()
        print("\nPassages in \(EvalPaths.passages.path)\n")
        for passage in passages {
            let state: String
            if let seconds = Recorder.duration(of: passage.recordingURL) {
                state = String(format: "recorded, %.0fs", seconds)
            } else {
                state = "NOT RECORDED"
            }
            print("  \(passage.id.padded(to: 24)) \(state)")
        }
        print("")
    }

    // MARK: - record

    static func record(only wanted: String?) async throws {
        let passages = try EvalPaths.load()
        guard !passages.isEmpty else {
            print("No passages found in \(EvalPaths.passages.path)")
            return
        }

        let targets = passages.filter { wanted == nil || $0.id == wanted }
        guard !targets.isEmpty else {
            print("No passage named \(wanted ?? "")")
            return
        }

        print("""

        Masterful — recording reference passages
        \(String(repeating: "═", count: 70))

        Read each passage aloud at your normal speaking pace. Do not
        over-enunciate: the recogniser is going to be judged on how it handles
        the way you actually talk.

        A stumble is fine — reread the line and carry on. What matters is that
        the words in the passage are the words you said, because that text is
        the reference every model is scored against.

        """)

        for passage in targets {
            if passage.hasRecording {
                print("── \(passage.id) — already recorded. Press Return to re-record, or 's' to skip.")
                if readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "s" { continue }
            }

            print(String(repeating: "─", count: 70))
            print(passage.text)
            print(String(repeating: "─", count: 70))
            print("\nPress Return to START recording…", terminator: "")
            _ = readLine()

            let stop = LockedBox(false)
            // readLine() blocks, so it cannot share a thread with the polling
            // loop that watches the flag it sets.
            Thread.detachNewThread {
                _ = readLine()
                stop.set(true)
            }

            print("● Recording — press Return when you have finished reading.")
            try await Recorder.record(to: passage.recordingURL) { stop.value }

            let seconds = Recorder.duration(of: passage.recordingURL) ?? 0
            print(String(format: "  saved %@ (%.0fs)\n", passage.recordingURL.lastPathComponent, seconds))
        }

        print("Done. Now run:  make eval-asr\n")
    }

    // MARK: - run

    static func run(arguments: [String]) async throws {
        let passages = try EvalPaths.load().filter(\.hasRecording)
        guard !passages.isEmpty else {
            print("""

            No recordings yet.

              make record

            """)
            return
        }

        let locales = try await resolveLocales(arguments: arguments)
        guard !locales.isEmpty else {
            print("No matching locales are installed.")
            return
        }

        print("")
        print("Masterful — recognition evaluation")
        print(String(repeating: "═", count: 78))
        print("Passages:  \(passages.count)")
        print("Locales:   \(locales.map(\.identifier).joined(separator: ", "))")
        print("")

        var totals: [String: (errors: Int, words: Int, seconds: Double)] = [:]
        var confusionsByLocale: [String: [String: Int]] = [:]

        for passage in passages {
            print(String(repeating: "─", count: 78))
            print(passage.id)
            print("")

            for locale in locales {
                let clock = ContinuousClock()
                var heard = ""
                var failure: String?
                let elapsed = await clock.measure {
                    do {
                        heard = try await FileTranscriber.transcribe(
                            fileURL: passage.recordingURL, locale: locale
                        )
                    } catch {
                        failure = "\(error)"
                    }
                }

                guard failure == nil else {
                    print("  \(locale.identifier.padded(to: 8)) FAILED — \(failure!)")
                    continue
                }

                let wer = WordErrorRate(reference: passage.text, hypothesis: heard)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18

                var running = totals[locale.identifier] ?? (0, 0, 0)
                running.errors += wer.errorCount
                running.words += wer.reference.count
                running.seconds += seconds
                totals[locale.identifier] = running

                for substitution in wer.substitutions {
                    let key = "\(substitution.reference) → \(substitution.heard)"
                    confusionsByLocale[locale.identifier, default: [:]][key, default: 0] += 1
                }

                print(String(
                    format: "  %@ WER %5.1f%%   %d sub  %d del  %d ins   (%.1fs)",
                    locale.identifier.padded(to: 8),
                    wer.rate * 100,
                    wer.substitutions.count, wer.deletions.count, wer.insertions.count,
                    seconds
                ))

                let shown = wer.substitutions.prefix(6)
                    .map { "\($0.reference)→\($0.heard)" }
                    .joined(separator: "  ")
                if !shown.isEmpty { print("           \(shown)") }
            }
            print("")
        }

        summarise(totals: totals, confusions: confusionsByLocale)
    }

    private static func summarise(
        totals: [String: (errors: Int, words: Int, seconds: Double)],
        confusions: [String: [String: Int]]
    ) {
        print(String(repeating: "═", count: 78))
        print("Overall")
        print("")

        let ranked = totals
            .map { (locale: $0.key, wer: Double($0.value.errors) / Double(max(1, $0.value.words)), value: $0.value) }
            .sorted { $0.wer < $1.wer }

        for (index, row) in ranked.enumerated() {
            let marker = index == 0 ? "★" : " "
            print(String(
                format: "  %@ %@ WER %5.1f%%   %d errors in %d words   (%.1fs total)",
                marker,
                row.locale.padded(to: 8),
                row.wer * 100,
                row.value.errors, row.value.words, row.value.seconds
            ))
        }

        if let best = ranked.first {
            print("")
            print("  Best: \(best.locale)")
            let repeated = (confusions[best.locale] ?? [:])
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(8)
            if !repeated.isEmpty {
                print("  Still wrong on \(best.locale):")
                for (confusion, count) in repeated {
                    print("    \(confusion)\(count > 1 ? "  ×\(count)" : "")")
                }
            }
        }
        print("")
        print("  Set the winner with the language picker in Settings.")
        print("")
    }

    /// `--locales en_GB,en_US` to name them, otherwise every installed model for
    /// the same language as the current setting.
    private static func resolveLocales(arguments: [String]) async throws -> [Locale] {
        if let index = arguments.firstIndex(of: "--locales"), index + 1 < arguments.count {
            return arguments[index + 1]
                .split(separator: ",")
                .map { Locale(identifier: $0.trimmingCharacters(in: .whitespaces)) }
        }
        let language = Locale.current.language.languageCode?.identifier
        return await FileTranscriber.installedLocales(matchingLanguage: language)
    }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
