import CoreAudio
import Foundation
import MasterfulKit
import os

/// Lowers whatever else is playing while you dictate, and puts it back.
///
/// macOS has no public per-application output volume — that is why the tools
/// which really do it ship a kernel driver — so this ducks the default output
/// device as a whole. Two consequences follow, and both are handled here rather
/// than left to surprise the user: the volume being changed is *theirs*, so it
/// is restored to the exact value it had; and if they reach for the volume keys
/// mid-sentence, their choice wins and we do not overwrite it.
public final class OutputDucker: @unchecked Sendable {

    /// What we ducked, so it can be put back on the same device even if the
    /// default output changed underneath us — which a Bluetooth headset
    /// switching to its hands-free profile will happily do mid-session.
    private struct Ducked {
        var device: AudioDeviceID
        var original: Float
        var applied: Float
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var ducked: Ducked?
        /// Supersedes an in-flight fade. Without it, a dictation ending during
        /// the fade-down would race it and settle at the wrong volume.
        var generation: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "com.tlotliso.masterful.ducking", qos: .userInitiated)
    /// A restore waiting out the capture tail, cancelled if dictation resumes
    /// first. Without the cancel, tapping the key again during the tail would
    /// bring the video back up in the middle of the new sentence.
    private var pendingRestore: DispatchWorkItem?

    /// A step is inaudible on its own; the sequence reads as a fade rather than
    /// the media player being yanked down, which is the whole point.
    private static let fadeSteps = 12
    private static let fadeDuration = 0.18

    /// Below this the two volumes are the same as far as anyone can hear, and
    /// treating them as equal is what lets us tell "untouched" from "the user
    /// moved it".
    private static let tolerance: Float = 0.02

    public init() {}

    // MARK: - Public

    /// Fades other audio down to `level` of its current volume.
    ///
    /// Does nothing when the output device is idle. That is not an optimisation:
    /// with nothing playing there is nothing to duck, and skipping it means we
    /// never capture a "original volume" that the user then changes while we sit
    /// on it, only to have it restored out from under them later.
    public func duck(to level: Double) {
        pendingRestore?.cancel()
        pendingRestore = nil

        guard let device = Self.defaultOutputDevice() else { return }
        guard Self.isRunningSomewhere(device) else {
            Log.audio.debug("Nothing playing — not ducking")
            return
        }
        guard let current = Self.volume(of: device) else {
            Log.audio.debug("Output device has no settable volume — not ducking")
            return
        }

        let target = current * Float(max(0, min(1, level)))
        // Already ducked (a second dictation inside the fade): keep the original
        // we captured the first time, or we would ratchet the volume down.
        let original = stateLock.withLock { state -> Float in
            let original = state.ducked?.original ?? current
            state.ducked = Ducked(device: device, original: original, applied: target)
            return original
        }
        let from = current

        Log.audio.info(
            "Ducking output \(original, format: .fixed(precision: 2)) → \(target, format: .fixed(precision: 2))"
        )
        fade(device: device, from: from, to: target)
    }

    /// Fades other audio back up once `delay` has passed.
    ///
    /// The delay exists because the microphone is still open for the capture
    /// tail. Bringing the video back before the tail elapses puts it in the
    /// recording, which is the one place it must not be.
    public func restore(after delay: Duration) {
        pendingRestore?.cancel()
        let seconds = Double(delay.components.seconds)
            + Double(delay.components.attoseconds) / 1e18
        guard seconds > 0 else {
            restore()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.restore() }
        pendingRestore = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Fades other audio back up to where the user had it.
    ///
    /// If the volume no longer matches what we set, the user moved it while we
    /// were ducked. Their value stands and we forget ours.
    public func restore() {
        guard let ducked = stateLock.withLock({ $0.ducked }) else { return }

        let current = Self.volume(of: ducked.device)
        if let current, abs(current - ducked.applied) > Self.tolerance {
            Log.audio.info("Output volume changed while ducked — leaving it alone")
            stateLock.withLock { $0.ducked = nil }
            return
        }

        stateLock.withLock { $0.ducked = nil }
        Log.audio.info("Restoring output to \(ducked.original, format: .fixed(precision: 2))")
        fade(device: ducked.device, from: current ?? ducked.applied, to: ducked.original)
    }

    /// Puts the volume back with no fade. For app termination, where there is no
    /// time for one and leaving the machine quiet would be unforgivable.
    public func restoreImmediately() {
        pendingRestore?.cancel()
        pendingRestore = nil
        guard let ducked = stateLock.withLock({ state -> Ducked? in
            defer { state.ducked = nil }
            state.generation &+= 1
            return state.ducked
        }) else { return }
        Self.setVolume(ducked.original, on: ducked.device)
    }

    // MARK: - Fading

    private func fade(device: AudioDeviceID, from: Float, to: Float) {
        let generation = stateLock.withLock { state -> UInt64 in
            state.generation &+= 1
            return state.generation
        }
        step(device: device, from: from, to: to, index: 1, generation: generation)
    }

    private func step(device: AudioDeviceID, from: Float, to: Float, index: Int, generation: UInt64) {
        guard stateLock.withLock({ $0.generation }) == generation else { return }

        let progress = Float(index) / Float(Self.fadeSteps)
        Self.setVolume(from + (to - from) * progress, on: device)

        guard index < Self.fadeSteps else { return }
        queue.asyncAfter(deadline: .now() + Self.fadeDuration / Double(Self.fadeSteps)) { [weak self] in
            self?.step(device: device, from: from, to: to, index: index + 1, generation: generation)
        }
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// True while something is actually feeding the device.
    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// The main element carries a single virtual volume on most devices. Some —
    /// aggregate devices especially — expose per-channel volume and nothing on
    /// the main element, so fall back to the stereo pair and average it.
    private static func volume(of device: AudioDeviceID) -> Float? {
        if let main = scalar(device, element: kAudioObjectPropertyElementMain) { return main }
        let left = scalar(device, element: 1)
        let right = scalar(device, element: 2)
        switch (left, right) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    private static func setVolume(_ volume: Float, on device: AudioDeviceID) {
        let clamped = max(0, min(1, volume))
        if setScalar(clamped, device, element: kAudioObjectPropertyElementMain) { return }
        _ = setScalar(clamped, device, element: 1)
        _ = setScalar(clamped, device, element: 2)
    }

    private static func address(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func scalar(_ device: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var address = address(element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func setScalar(
        _ value: Float, _ device: AudioDeviceID, element: AudioObjectPropertyElement
    ) -> Bool {
        var address = address(element: element)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }

        var value = value
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
