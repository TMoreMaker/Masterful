import AVFoundation
import Foundation
import MasterfulKit
import Speech

/// Runs a recorded file through one locale's model.
///
/// Feeds the analyser through the same `AsyncStream<AnalyzerInput>` path the app
/// uses in production rather than the convenience `analyzeSequence(from:)`. The
/// harness is only useful if it measures the code path that actually ships; a
/// number produced by a different entry point would be a number about something
/// else.
enum FileTranscriber {

    enum TranscriptionError: Error, CustomStringConvertible {
        case unsupported(String)
        case noCompatibleFormat
        case converterUnavailable

        var description: String {
            switch self {
            case .unsupported(let id): "\(id) is not a supported locale"
            case .noCompatibleFormat: "no compatible audio format for this model"
            case .converterUnavailable: "could not convert the recording to the model's format"
            }
        }
    }

    /// Locales whose models are already on disk. Used as the default candidate
    /// set so a first run measures what is installed instead of silently pulling
    /// several hundred megabytes per language.
    static func installedLocales(matchingLanguage language: String?) async -> [Locale] {
        let installed = await SpeechTranscriber.installedLocales
        return installed
            .filter { language == nil || $0.language.languageCode?.identifier == language }
            .sorted { $0.identifier < $1.identifier }
    }

    static func transcribe(fileURL: URL, locale: Locale, vocabulary: [String] = []) async throws -> String {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupported(locale.identifier)
        }

        // Matches the production recogniser: volatile results for live HUD text,
        // and explicitly not `.fastResults`, which trades accuracy for latency
        // that offline analysis has no use for anyway.
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Deliberately no asset installation here.
        //
        // `AssetInventory.status(forModules:)` reports `.supported` rather than
        // `.installed` for locales that `installedLocales` lists as present, so
        // the obvious guard — install unless already installed — fires every
        // single time. Each needless attempt allocates a locale slot, and the
        // system caps allocations at `AssetInventory.maximumReservedLocales`
        // (5), so a nine-locale sweep exhausts them and every later model fails.
        //
        // The eval tool only ever runs against locales the caller has confirmed
        // are installed, so downloading is not its job. `--locales` naming an
        // uninstalled model fails loudly, which is the right outcome for a
        // measurement tool: silently pulling several hundred megabytes mid-run
        // would wreck the timings it exists to report.

        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw TranscriptionError.noCompatibleFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // The same bias the app applies, so a comparison against another engine
        // primed with the same names is a fair one.
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
        }
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Collection starts before the audio is pushed. Starting it afterwards
        // races the analyser and drops the earliest results.
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                // The production joiner, so the eval scores the transcript the
                // app would actually have produced.
                text = SegmentJoiner.join(text, String(result.text.characters))
            }
            return text
        }

        try await analyzer.start(inputSequence: input)
        try feed(fileURL: fileURL, target: target, into: continuation)
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await collected.value

        // Tearing the analyser down is not housekeeping — it is what returns the
        // locale allocation. Letting it fall out of scope is enough eventually,
        // but "eventually" is measured against a hard limit of five, and this
        // tool's whole job is to walk through more locales than that in a row.
        await analyzer.cancelAndFinishNow()

        return text
    }

    /// Reads the whole recording, converting it into the model's preferred
    /// format in chunks.
    private static func feed(
        fileURL: URL,
        target: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let file = try AVAudioFile(forReading: fileURL)
        let source = file.processingFormat

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw TranscriptionError.converterUnavailable
        }

        let chunkFrames: AVAudioFrameCount = 16384
        // Sample-rate conversion changes the frame count, so the output buffer is
        // sized by the ratio with headroom rather than by the input length.
        let ratio = target.sampleRate / source.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 1024

        // Bounded by the file's own position rather than by a short read.
        //
        // Reading a fixed chunk and stopping when it comes back short looks
        // equivalent and is not: a file whose length is an exact multiple of the
        // chunk size never produces a short read, so the loop attempts one more
        // read at EOF, which throws an error carrying no detail at all. That bug
        // is invisible on most recordings and fires reliably on a few, which is
        // the worst way for it to behave.
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(
                min(Int64(chunkFrames), file.length - file.framePosition)
            )
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: source, frameCapacity: chunkFrames
            ) else { break }
            try file.read(into: inputBuffer, frameCount: remaining)
            guard inputBuffer.frameLength > 0 else { break }

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: outputCapacity
            ) else { break }

            // The converter may pull for input more than once per output buffer.
            // Handing it the same chunk twice would duplicate audio, so the
            // chunk is wrapped such that the second pull reports end-of-stream.
            let pending = SingleUseBuffer(inputBuffer)
            var conversionError: NSError?
            converter.convert(to: outputBuffer, error: &conversionError) { _, status in
                guard let next = pending.take() else {
                    status.pointee = .noDataNow
                    return nil
                }
                status.pointee = .haveData
                return next
            }
            if let conversionError { throw conversionError }

            if outputBuffer.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: outputBuffer))
            }
        }
    }
}

/// Hands an `AVAudioPCMBuffer` to `AVAudioConverter` exactly once.
///
/// Mirrors the helper in `AudioCapture` for the same reason it exists there: the
/// converter calls its input block synchronously, on the calling thread, and the
/// buffer is released after the first read, so the unchecked conformance is
/// sound. Duplicated rather than shared because the eval tool deliberately does
/// not depend on the production capture target.
private final class SingleUseBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
