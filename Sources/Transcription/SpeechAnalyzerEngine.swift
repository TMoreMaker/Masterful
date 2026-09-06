import AVFoundation
import AudioCapture
import Foundation
import MasterfulKit
import Speech

/// Transcription on Apple's `SpeechAnalyzer` stack (macOS 26+).
///
/// Chosen as the default over a heavier model like Parakeet for one reason that
/// matters more than raw word error rate: the `.progressiveTranscription` preset
/// emits *volatile* results while you are still speaking. That is what puts live
/// text in the HUD. A chunked model can only show you something after you stop,
/// which changes what the product feels like far more than a point of accuracy.
public actor SpeechAnalyzerEngine: TranscriptionEngine {

    public nonisolated var displayName: String { "Apple Speech (on-device)" }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var pumpTask: Task<Void, Never>?

    /// The locale we reserved assets for, released on teardown so the system can
    /// reclaim the download if the user switches languages.
    private var reservedLocale: Locale?
    private var resolvedLocale: Locale?

    /// Volatile results replace the tail; finalised results append. Tracking
    /// them separately is the only way to render a stable transcript that grows
    /// rather than flickering between guesses.
    private var finalizedText: String = ""

    public init() {}

    // MARK: - Preparation

    public func prepare(locale: Locale) async throws -> AVAudioFormat? {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionEngineError.unavailableOnThisDevice
        }

        // Fall back to en_US rather than failing outright: an unsupported
        // regional variant should not leave the user with no dictation at all.
        var candidate = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if candidate == nil {
            candidate = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "en_US")
            )
        }
        guard let supported = candidate else {
            throw TranscriptionEngineError.unsupportedLocale(locale.identifier)
        }
        resolvedLocale = supported

        let probe = Self.makeTranscriber(locale: supported)

        // Models are downloaded on demand and can be evicted. Installing here
        // means the first hotkey press after a language change is not a
        // multi-hundred-megabyte surprise mid-sentence.
        let status = await AssetInventory.status(forModules: [probe])
        if status != .installed {
            Log.transcription.info("Speech assets not installed (status \(String(describing: status), privacy: .public)) — requesting")
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    try await request.downloadAndInstall()
                    Log.transcription.info("Speech assets installed")
                }
            } catch {
                throw TranscriptionEngineError.assetInstallationFailed(error.localizedDescription)
            }
        }

        // Reserving keeps the asset from being reclaimed under storage pressure.
        if reservedLocale != supported {
            if let previous = reservedLocale {
                _ = await AssetInventory.release(reservedLocale: previous)
            }
            _ = try? await AssetInventory.reserve(locale: supported)
            reservedLocale = supported
        }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        Log.transcription.info(
            "Prepared \(supported.identifier, privacy: .public) at \(format?.sampleRate ?? 0, format: .fixed(precision: 0)) Hz"
        )
        return format
    }

    // MARK: - Session

    public func beginSession(
        vocabulary: [String]
    ) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        await teardown()

        guard let locale = resolvedLocale else {
            throw TranscriptionEngineError.noActiveSession
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        self.transcriber = transcriber
        self.finalizedText = ""

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            try await analyzer.setContext(context)
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.inputContinuation = inputContinuation

        try await analyzer.start(inputSequence: inputStream)

        let (updates, updateContinuation) = AsyncThrowingStream<TranscriptionUpdate, Error>
            .makeStream()

        pumpTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let update = await self.absorb(result)
                    updateContinuation.yield(update)
                }
                // The stream ending is how `finalizeAndFinishThroughEndOfInput`
                // reports completion, so synthesise the terminal update here
                // rather than making callers infer it.
                if let self {
                    updateContinuation.yield(
                        TranscriptionUpdate(text: await self.currentText, isFinal: true)
                    )
                }
                updateContinuation.finish()
            } catch is CancellationError {
                updateContinuation.finish()
            } catch {
                Log.transcription.error("Results stream failed: \(error.localizedDescription, privacy: .public)")
                updateContinuation.finish(throwing: error)
            }
        }

        return updates
    }

    public func append(_ audio: CapturedAudio) {
        inputContinuation?.yield(AnalyzerInput(buffer: audio.buffer))
    }

    public func finish() async throws {
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    public func cancel() async {
        await teardown()
    }

    /// Builds the recogniser.
    ///
    /// Deliberately *not* `.progressiveTranscription`, which is
    /// `[.volatileResults, .fastResults]`. Only `volatileResults` is needed for
    /// live text in the HUD; `fastResults` trades recognition accuracy for
    /// latency, and adopting the convenience preset meant paying that price
    /// without ever choosing it. Measured against real dictation it was
    /// mishearing ordinary words — "clamshell mode" as "clam shell, shall mode".
    ///
    /// The latency it saves is also the latency we least need: the user is still
    /// speaking while these results arrive, so the recogniser has time it is not
    /// being credited for.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    // MARK: - Internals

    private var currentText: String { finalizedText }

    /// Folds one recogniser result into the running transcript.
    private func absorb(_ result: SpeechTranscriber.Result) -> TranscriptionUpdate {
        let fragment = String(result.text.characters)
        if result.isFinal {
            finalizedText = Self.join(finalizedText, fragment)
            return TranscriptionUpdate(text: finalizedText, isFinal: false)
        }
        // Volatile: shown but not committed, so the next volatile result
        // replaces it instead of stacking.
        return TranscriptionUpdate(text: Self.join(finalizedText, fragment), isFinal: false)
    }

    /// Recogniser fragments arrive with their own leading spacing conventions;
    /// normalise rather than trusting them.
    private static func join(_ lhs: String, _ rhs: String) -> String {
        let right = rhs.trimmingCharacters(in: .whitespaces)
        guard !right.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return right }
        return lhs + " " + right
    }

    private func teardown() async {
        pumpTask?.cancel()
        pumpTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
        finalizedText = ""
    }
}
