import AVFoundation
import AudioCapture
import Foundation
import MasterfulKit
import WhisperKit

/// Whisper, on this Mac, for Mercor mode.
///
/// Chosen over Apple's recogniser for written answers on the evidence of the
/// user's own speech (`Tools/engine-compare`): it hears the whole answer before
/// punctuating, so a pause to think does not become a full stop, and it takes
/// a prompt, which steers names far harder than Apple's contextual strings —
/// "Lesotho" and "Kgodisho" came out right where Apple wrote "Lisutu" and
/// "Hodisho" with both names in its vocabulary.
///
/// The price is that nothing is transcribed until the key is released, which
/// is why this is a mode for written work and not the default.
///
/// Nothing leaves the machine. The model is fetched once, into Application
/// Support, and every transcription after that is local.
public actor WhisperEngine: TranscriptionEngine {

    public nonisolated var displayName: String { "Whisper large-v3 turbo (on-device)" }

    /// large-v3 turbo, quantised to 632 MB. Measured on the user's recordings
    /// at about 2 seconds for 25 seconds of speech, cold.
    public static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Masterful/Models", isDirectory: true)
    }

    /// Where the variant lives once downloaded. WhisperKit's hub layout.
    public static var modelFolder: URL {
        modelsDirectory.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true
        )
    }

    public static var isDownloaded: Bool {
        FileManager.default.fileExists(
            atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path
        )
    }

    /// A sentence in the user's spelling, ahead of their names.
    ///
    /// Whisper continues the style of its prompt. Without this it writes
    /// "favorite"; with it, "favourite" — and the punctuation of the sentence
    /// carries over too. Measured on the user's recordings, not assumed.
    static let stylePrompt = "My favourite colour is grey, and I organised the centre."

    /// Whisper's prompt window is 224 tokens; this keeps the names well inside
    /// it alongside the style sentence.
    static let maximumPromptTerms = 40

    /// Below this peak level the recording is treated as silence. Whisper given
    /// silence does not return nothing — it returns "you", or the prompt read
    /// back — so silence has to be caught before it is ever transcribed.
    static let silencePeak: Float = 0.01

    private var pipe: WhisperKit?
    private var samples: [Float] = []
    private var vocabulary: [String] = []
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    public init() {}

    // MARK: - Model

    /// Downloads the model if needed and loads it, reporting download progress
    /// from 0 to 1. Loading after the first time is seconds; the very first
    /// load also compiles the model for the Neural Engine, which takes minutes.
    public func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard pipe == nil else { return }
        if !Self.isDownloaded {
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            _ = try await WhisperKit.download(
                variant: Self.variant, downloadBase: Self.modelsDirectory
            ) { update in progress(update.fractionCompleted) }
        }
        progress(1)
        let config = WhisperKitConfig(
            model: Self.variant,
            downloadBase: Self.modelsDirectory,
            modelFolder: Self.modelFolder.path,
            tokenizerFolder: Self.modelsDirectory,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        Log.transcription.info("Whisper loaded")
    }

    /// Frees the model's memory, which is most of a gigabyte. Mercor mode
    /// being off is no reason to hold it.
    public func unload() {
        pipe = nil
    }

    public var isLoaded: Bool { pipe != nil }

    // MARK: - TranscriptionEngine

    /// Takes whatever format capture produces and converts it here, so turning
    /// Mercor mode on never has to rebuild the audio graph.
    public func prepare(locale: Locale) async throws -> AVAudioFormat? { nil }

    public func beginSession(
        vocabulary: [String]
    ) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        guard pipe != nil else { throw TranscriptionEngineError.noActiveSession }
        cancelSession()
        samples = []
        samples.reserveCapacity(16_000 * 60)
        self.vocabulary = vocabulary
        let (stream, continuation) = AsyncThrowingStream<TranscriptionUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func append(_ audio: CapturedAudio) {
        guard continuation != nil, let converted = convert(audio.buffer) else { return }
        samples.append(contentsOf: converted)
    }

    public func finish() async throws {
        guard let continuation else { return }
        self.continuation = nil
        let audio = samples
        samples = []

        let text: String
        if Self.isSilent(audio) {
            Log.transcription.info("Whisper: silence, not transcribed")
            text = ""
        } else {
            text = try await transcribe(audio)
        }
        continuation.yield(TranscriptionUpdate(text: text, isFinal: true))
        continuation.finish()
    }

    public func cancel() async {
        cancelSession()
    }

    private func cancelSession() {
        continuation?.finish()
        continuation = nil
        samples = []
    }

    // MARK: - Transcription

    private func transcribe(_ audio: [Float]) async throws -> String {
        guard let pipe else { throw TranscriptionEngineError.noActiveSession }
        let prompt = Self.prompt(vocabulary: vocabulary)
        var options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        if let tokenizer = pipe.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Self.discardingEcho(text, prompt: prompt)
    }

    static func prompt(vocabulary: [String]) -> String {
        let names = vocabulary.prefix(maximumPromptTerms)
        return names.isEmpty ? stylePrompt : stylePrompt + " " + names.joined(separator: ", ") + "."
    }

    static func isSilent(_ audio: [Float]) -> Bool {
        // Under a third of a second is a stray press, not an answer.
        guard audio.count > 16_000 / 3 else { return true }
        return audio.reduce(Float(0)) { max($0, abs($1)) } < silencePeak
    }

    /// Whisper's other failure on near-silence: the prompt read back as if it
    /// had been spoken. Text that is nothing but prompt is discarded.
    static func discardingEcho(_ text: String, prompt: String) -> String {
        func bare(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0 == " " }
                .split(separator: " ").joined(separator: " ")
        }
        let spoken = bare(text)
        guard !spoken.isEmpty else { return "" }
        return bare(prompt).contains(spoken) ? "" : text
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let target = Self.targetFormat
        if buffer.format == target, let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate
        ) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        // The same one-shot hand-off capture uses, for the same reason: the
        // converter's callback may run concurrently, and a plain captured flag
        // is a data race as far as Swift 6 is concerned.
        let source = SingleUseBuffer(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
