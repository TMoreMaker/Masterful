import AVFoundation
import Foundation
import MasterfulKit
import os

/// A converted buffer on its way to the recogniser.
///
/// `AVAudioPCMBuffer` is a reference type and not `Sendable`. The capture engine
/// creates each buffer, fills it once, hands it off, and never touches it again,
/// so the transfer is safe — but only because of that discipline, which is why
/// this wrapper exists rather than an `@unchecked Sendable` scattered at the
/// call sites.
public struct CapturedAudio: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Microphone capture, format conversion and level metering.
///
/// The graph — tap, converter, format — is built once at launch and reused, so
/// pressing the hotkey pays for `start()` only rather than graph construction.
/// The hardware itself is not held open that cheaply: macOS lights the recording
/// indicator for as long as the input device is running, so the engine is
/// stopped after `idleGrace` of silence and restarted on the next session.
public final class AudioCaptureEngine: @unchecked Sendable {

    public enum CaptureError: Error, Sendable {
        case permissionDenied
        case noInputDevice
        case converterUnavailable
        case engineFailed(String)
    }

    private let engine = AVAudioEngine()
    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var isCapturing = false
        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?
        var audioContinuation: AsyncStream<CapturedAudio>.Continuation?
        var levelContinuation: AsyncStream<AudioLevel>.Continuation?
        /// Smoothed loudness, so the waveform glides instead of strobing.
        var smoothedRMS: Float = 0
        var smoothedPeak: Float = 0
    }

    private var configurationObserver: NSObjectProtocol?
    private var stopWorkItem: DispatchWorkItem?
    private var idleWorkItem: DispatchWorkItem?
    /// Serialises every start/stop of the graph. Teardown runs here on a timer
    /// and `start()` hops here synchronously, so the two can never interleave
    /// and leave the microphone stopped while a session believes it is open.
    private let queue = DispatchQueue(label: "com.tlotliso.masterful.audio", qos: .userInitiated)

    /// How long the microphone stays open after a session ends.
    ///
    /// Restarting the graph costs a few tens of milliseconds, so back-to-back
    /// dictations should not pay for it — but leaving it running is what makes
    /// the orange recording indicator sit lit all day, which is not a thing a
    /// dictation app is allowed to do. A few seconds buys the common case and
    /// releases the hardware for everything else.
    public static let idleGrace = Duration.seconds(4)

    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// The hardware format currently offered by the default input device.
    public var inputFormat: AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    // MARK: - Lifecycle

    /// Builds the graph and installs the tap. Safe to call more than once.
    ///
    /// - Parameter targetFormat: the format the recogniser wants, from
    ///   `SpeechAnalyzer.bestAvailableAudioFormat`. Passing `nil` delivers the
    ///   hardware format untouched.
    public func prepare(targetFormat: AVAudioFormat?) throws {
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let converter: AVAudioConverter? = try {
            guard let targetFormat, targetFormat != hardware else { return nil }
            guard let made = AVAudioConverter(from: hardware, to: targetFormat) else {
                throw CaptureError.converterUnavailable
            }
            // Dictation is close-mic speech; the recogniser wants a clean,
            // deterministic downmix rather than anything clever.
            made.downmix = true
            return made
        }()

        stateLock.withLock {
            $0.converter = converter
            $0.targetFormat = targetFormat
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardware) {
            [weak self] buffer, _ in
            self?.handleTappedBuffer(buffer)
        }
        engine.prepare()

        installConfigurationObserver(targetFormat: targetFormat)
        Log.audio.info(
            "Audio graph prepared — input \(hardware.sampleRate, format: .fixed(precision: 0)) Hz × \(hardware.channelCount) ch"
        )
    }

    /// Opens the microphone and returns the two streams the app consumes.
    public func start() throws -> (audio: AsyncStream<CapturedAudio>, levels: AsyncStream<AudioLevel>) {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        idleWorkItem?.cancel()
        idleWorkItem = nil

        let (audioStream, audioContinuation) = AsyncStream<CapturedAudio>.makeStream(
            // Never stall the audio thread. If the recogniser falls behind,
            // dropping the oldest buffer is far better than blocking capture.
            bufferingPolicy: .bufferingNewest(256)
        )
        let (levelStream, levelContinuation) = AsyncStream<AudioLevel>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )

        stateLock.withLock {
            $0.audioContinuation?.finish()
            $0.levelContinuation?.finish()
            $0.audioContinuation = audioContinuation
            $0.levelContinuation = levelContinuation
            $0.smoothedRMS = 0
            $0.smoothedPeak = 0
            $0.isCapturing = true
        }

        // Synchronous, and on the same queue the idle teardown uses: if a
        // teardown was already executing when the hotkey came down, this blocks
        // behind it rather than racing it and starting an engine that is about
        // to be stopped.
        var failure: Error?
        queue.sync {
            guard !engine.isRunning else { return }
            do {
                try engine.start()
            } catch {
                failure = error
            }
        }
        if let failure {
            stateLock.withLock { $0.isCapturing = false }
            throw CaptureError.engineFailed(failure.localizedDescription)
        }

        Log.audio.info("Capture started")
        return (audioStream, levelStream)
    }

    /// Closes the microphone after `tail`.
    ///
    /// The delay is not politeness — people trail off, and cutting the stream at
    /// the instant the key comes up reliably clips the last word.
    public func stop(tail: Duration) {
        let seconds = tail.seconds

        stopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.withLock {
                $0.isCapturing = false
                $0.audioContinuation?.finish()
                $0.levelContinuation?.finish()
                $0.audioContinuation = nil
                $0.levelContinuation = nil
            }
            // Only the gate closes here. The hardware is released separately,
            // after the idle grace, so a second utterance a beat later does not
            // restart the graph — and does not flicker the indicator.
            Log.audio.info("Capture stopped")
        }
        stopWorkItem = work
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: work)

        scheduleIdleTeardown(after: max(0, seconds) + Self.idleGrace.seconds)
    }

    /// Releases the input device once the app has been quiet for a while.
    ///
    /// This is what turns the system recording indicator off. It runs on the
    /// audio queue and re-checks the gate under the lock, so a session that
    /// started in the meantime is never cut off.
    private func scheduleIdleTeardown(after seconds: Double) {
        idleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.stateLock.withLock({ $0.isCapturing }) else { return }
            guard self.engine.isRunning else { return }
            self.engine.stop()
            Log.audio.info("Microphone released")
        }
        idleWorkItem = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Fully tears down the graph. Used when the app deactivates dictation
    /// entirely, so the microphone indicator goes away.
    public func shutdown() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        idleWorkItem?.cancel()
        idleWorkItem = nil
        stateLock.withLock {
            $0.isCapturing = false
            $0.audioContinuation?.finish()
            $0.levelContinuation?.finish()
            $0.audioContinuation = nil
            $0.levelContinuation = nil
        }
        queue.sync {
            if engine.isRunning { engine.stop() }
        }
    }

    // MARK: - Audio thread

    /// Runs on the real-time audio thread. Keep it short, and never block.
    private func handleTappedBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = Self.level(of: buffer)

        let work: (converter: AVAudioConverter?, target: AVAudioFormat?,
                   audio: AsyncStream<CapturedAudio>.Continuation?,
                   levels: AsyncStream<AudioLevel>.Continuation?,
                   smoothed: AudioLevel)? = stateLock.withLock { state in
            guard state.isCapturing else { return nil }
            // Fast attack, slow release: the bar shoots up on a syllable and
            // eases down, which reads as responsive rather than jittery.
            state.smoothedRMS = Self.smooth(state.smoothedRMS, toward: level.rms)
            state.smoothedPeak = Self.smooth(state.smoothedPeak, toward: level.peak)
            return (
                state.converter, state.targetFormat,
                state.audioContinuation, state.levelContinuation,
                AudioLevel(rms: state.smoothedRMS, peak: state.smoothedPeak)
            )
        }

        guard let work else { return }
        work.levels?.yield(work.smoothed)

        guard let audio = work.audio else { return }

        guard let converter = work.converter, let target = work.target else {
            audio.yield(CapturedAudio(buffer: buffer))
            return
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }

        // The converter may ask for input more than once per output buffer, and
        // feeding the same input twice would duplicate audio. `AVAudioConverter`
        // invokes this block synchronously on the calling thread, so a
        // single-use box is both correct and the only way to satisfy Swift 6
        // without waving `@preconcurrency` at the whole module.
        let source = SingleUseBuffer(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            guard let next = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }

        if let error {
            Log.audio.error("Conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard converted.frameLength > 0 else { return }
        audio.yield(CapturedAudio(buffer: converted))
    }

    private static func smooth(_ current: Float, toward target: Float) -> Float {
        let coefficient: Float = target > current ? 0.55 : 0.12
        return current + (target - current) * coefficient
    }

    /// RMS and peak in `0...1`, mapped from dBFS with a −60 dB floor so quiet
    /// speech still moves the waveform.
    static func level(of buffer: AVAudioPCMBuffer) -> AudioLevel {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return .silence
        }
        let frames = Int(buffer.frameLength)
        let samples = channels[0]

        var sumOfSquares: Float = 0
        var peak: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        let rms = (sumOfSquares / Float(frames)).squareRoot()
        return AudioLevel(rms: normalise(rms), peak: normalise(peak))
    }

    private static func normalise(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let floorDB: Float = -60
        let decibels = 20 * log10(amplitude)
        guard decibels > floorDB else { return 0 }
        return min(1, (decibels - floorDB) / -floorDB)
    }

    // MARK: - Device changes

    /// Switching from the built-in microphone to a headset (or unplugging one
    /// mid-sentence) invalidates the graph. Rebuilding the tap on the
    /// configuration-change notification is what keeps that from ending the
    /// session with silence.
    private func installConfigurationObserver(targetFormat: AVAudioFormat?) {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.audio.notice("Input configuration changed — rebuilding graph")
            let wasCapturing = self.stateLock.withLock { $0.isCapturing }
            do {
                try self.queue.sync {
                    if self.engine.isRunning { self.engine.stop() }
                    try self.prepare(targetFormat: targetFormat)
                    // Only reopen the device if a session is actually running.
                    // Rebuilding while idle must not light the indicator.
                    if wasCapturing { try self.engine.start() }
                }
            } catch {
                Log.audio.error("Rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension Duration {
    /// `DispatchQueue` deals in seconds; `Duration` does not hand them over.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Hands an `AVAudioPCMBuffer` to `AVAudioConverter` exactly once.
///
/// Safe despite the unchecked conformance because the converter calls its input
/// block synchronously, on the thread that called `convert`, and the buffer is
/// released after the first read.
private final class SingleUseBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
