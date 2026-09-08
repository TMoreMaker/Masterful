import AVFoundation
import Foundation

/// Records one passage to a WAV file.
///
/// Deliberately captures at the microphone's own format and does not resample.
/// The whole point of the harness is that one recording is replayed through
/// several recognisers, and each of them wants a different sample rate — so the
/// conversion belongs at analysis time, once per model, against the highest
/// fidelity source available. Resampling here would bake one model's preference
/// into the corpus and quietly handicap the others.
enum Recorder {

    enum RecordingError: Error, CustomStringConvertible {
        case microphoneDenied
        case engineFailed(String)

        var description: String {
            switch self {
            case .microphoneDenied:
                """
                Microphone access was refused.

                A command-line tool inherits the permission of the terminal that
                launched it, so grant it to your terminal app in
                System Settings → Privacy & Security → Microphone, then re-run.
                """
            case .engineFailed(let detail): "Audio engine failed: \(detail)"
            }
        }
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Records until `shouldStop` returns true, polled a few times a second.
    static func record(to url: URL, shouldStop: @escaping @Sendable () -> Bool) async throws {
        guard await requestPermission() else { throw RecordingError.microphoneDenied }

        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw RecordingError.engineFailed("no input device")
        }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        // The tap runs on a real-time audio thread. Writing straight to the file
        // from it is acceptable here and only here: this is an offline recording
        // tool with no latency budget to blow, and the alternative — a ring
        // buffer and a consumer task — is complexity that buys nothing.
        let writeError = LockedBox<Error?>(nil)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do { try file.write(from: buffer) } catch { writeError.set(error) }
        }

        engine.prepare()
        do { try engine.start() } catch {
            throw RecordingError.engineFailed(error.localizedDescription)
        }

        while !shouldStop() {
            if writeError.value != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let error = writeError.value { throw error }
    }

    /// Duration of a recorded file, for the summary line.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Minimal mutable box for passing a value off the audio thread.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { self.stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        stored = newValue
    }
}
