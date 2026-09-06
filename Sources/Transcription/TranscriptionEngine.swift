import AVFoundation
import AudioCapture
import Foundation
import MasterfulKit

/// One recogniser result. Volatile updates arrive continuously while speaking;
/// exactly one final update closes the session.
public struct TranscriptionUpdate: Sendable, Equatable {
    /// The full transcript so far — finalised text plus the current volatile
    /// tail — not just the newest fragment. The HUD renders this directly.
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// The seam that lets Apple's recogniser be swapped for Parakeet (or a fake in
/// tests) without anything upstream noticing.
///
/// Sessions are explicitly begun and finished rather than inferred, because a
/// dictation app starts and stops a recogniser many times a minute and the cost
/// of rebuilding one per utterance is exactly the latency we are trying to
/// avoid.
public protocol TranscriptionEngine: Actor {
    nonisolated var displayName: String { get }

    /// Ensures models are present, reserving assets if needed.
    /// - Returns: the audio format this engine wants to be fed, if it has a
    ///   preference. Callers hand this to `AudioCaptureEngine.prepare`.
    func prepare(locale: Locale) async throws -> AVAudioFormat?

    /// - Parameter vocabulary: names and jargon to bias recognition toward.
    func beginSession(vocabulary: [String]) async throws -> AsyncThrowingStream<TranscriptionUpdate, Error>

    func append(_ audio: CapturedAudio) async

    /// Flushes buffered audio and finalises. The results stream terminates after
    /// its final update.
    func finish() async throws

    func cancel() async
}

public enum TranscriptionEngineError: Error, Sendable, Equatable {
    case unavailableOnThisDevice
    case unsupportedLocale(String)
    case assetInstallationFailed(String)
    case noActiveSession
}
