import Foundation
import MasterfulKit
import Testing
@testable import InputControl

@Suite("Hold versus double-tap")
struct HotkeyResolverTests {

    private func resolver(latch: Bool = true) -> HotkeyResolver {
        HotkeyResolver(configuration: .init(
            minimumHold: .milliseconds(220),
            doubleTapWindow: .milliseconds(320),
            latchEnabled: latch
        ))
    }

    @Test("Recording begins on the press, not after the double-tap window")
    func pressStartsImmediately() {
        var sut = resolver()
        let outputs = sut.press(at: 0)
        // The whole point of the design: no waiting to disambiguate.
        #expect(outputs == [.intent(.beginListening(.pushToTalk))])
    }

    @Test("A held press ends on release")
    func holdEndsOnRelease() {
        var sut = resolver()
        _ = sut.press(at: 0)
        let outputs = sut.release(at: 0.5)
        #expect(outputs == [.intent(.endListening)])
        #expect(!sut.isEngaged)
    }

    @Test("A quick tap keeps listening and waits for a second tap")
    func quickTapWaits() {
        var sut = resolver()
        _ = sut.press(at: 0)
        let outputs = sut.release(at: 0.05)
        // Crucially it does NOT end the session — the microphone stays open.
        #expect(outputs == [.scheduleTapTimeout(.milliseconds(320))])
    }

    @Test("A second tap inside the window latches the running session")
    func doubleTapLatches() {
        var sut = resolver()
        _ = sut.press(at: 0)
        _ = sut.release(at: 0.05)
        let outputs = sut.press(at: 0.18)
        #expect(outputs == [.cancelTapTimeout, .intent(.promoteToLatched)])
    }

    @Test("Releasing the latching press does not stop dictation")
    func latchSurvivesItsOwnRelease() {
        var sut = resolver()
        _ = sut.press(at: 0)
        _ = sut.release(at: 0.05)
        _ = sut.press(at: 0.18)
        #expect(sut.release(at: 0.24).isEmpty)
        #expect(sut.isEngaged)
    }

    @Test("A later press ends a latched session")
    func pressEndsLatched() {
        var sut = resolver()
        _ = sut.press(at: 0)
        _ = sut.release(at: 0.05)
        _ = sut.press(at: 0.18)
        _ = sut.release(at: 0.24)
        #expect(sut.press(at: 9.0) == [.intent(.endListening)])
        #expect(!sut.isEngaged)
    }

    @Test("No second tap ends the session normally")
    func lonelyTapEnds() {
        var sut = resolver()
        _ = sut.press(at: 0)
        _ = sut.release(at: 0.05)
        #expect(sut.tapTimeoutElapsed() == [.intent(.endListening)])
        #expect(!sut.isEngaged)
    }

    @Test("With latching disabled, a quick tap simply ends")
    func latchDisabled() {
        var sut = resolver(latch: false)
        _ = sut.press(at: 0)
        #expect(sut.release(at: 0.05) == [.intent(.endListening)])
    }

    @Test("Key auto-repeat does not restart the session")
    func autoRepeatIgnored() {
        var sut = resolver()
        _ = sut.press(at: 0)
        #expect(sut.press(at: 0.03).isEmpty)
        #expect(sut.press(at: 0.06).isEmpty)
    }
}

@Suite("Trigger matching")
struct TriggerMatchingTests {

    private func event(
        kind: RawInputEvent.Kind,
        keyCode: UInt16 = 0,
        flags: UInt64 = 0,
        mouseButton: Int = 0
    ) -> RawInputEvent {
        RawInputEvent(
            kind: kind, keyCode: keyCode, rawFlags: flags,
            mouseButton: mouseButton, timestamp: 0
        )
    }

    @Test("Globe key press and release are distinguished by the fn flag")
    func globeKeyEdges() {
        let trigger = Trigger.modifier(.function)
        let fnMask = ModifierKey.function.deviceMask

        let down = HotkeyEngine.match(
            event: event(kind: .flagsChanged, keyCode: 63, flags: fnMask),
            against: trigger
        )
        #expect(down?.edge == .press)

        let up = HotkeyEngine.match(
            event: event(kind: .flagsChanged, keyCode: 63, flags: 0),
            against: trigger
        )
        #expect(up?.edge == .release)
    }

    @Test("Modifier events are never swallowed")
    func modifiersPassThrough() {
        // Consuming a flagsChanged desyncs the system's modifier state and
        // leaves the user with a stuck key.
        let match = HotkeyEngine.match(
            event: event(kind: .flagsChanged, keyCode: 63, flags: ModifierKey.function.deviceMask),
            against: .modifier(.function)
        )
        #expect(match?.consume == false)
    }

    @Test("Left and right Option are told apart by device-side flags")
    func sidedModifiers() {
        let rightOptionDown = event(
            kind: .flagsChanged, keyCode: 61, flags: ModifierKey.rightOption.deviceMask
        )
        #expect(HotkeyEngine.match(event: rightOptionDown, against: .modifier(.rightOption))?.edge == .press)

        // Right Option released while left Option is still held: the general
        // alternate mask is still set, but the right-side bit is not.
        let rightUpLeftHeld = event(
            kind: .flagsChanged, keyCode: 61, flags: ModifierKey.leftOption.deviceMask
        )
        #expect(HotkeyEngine.match(event: rightUpLeftHeld, against: .modifier(.rightOption))?.edge == .release)
    }

    @Test("Chords require exact modifiers and are swallowed")
    func chordMatching() {
        let trigger = Trigger.key(code: 49, modifiers: [.option])
        let optionSpace = event(
            kind: .keyDown, keyCode: 49, flags: CGEventFlagsShim.alternate
        )
        let match = HotkeyEngine.match(event: optionSpace, against: trigger)
        #expect(match?.edge == .press)
        #expect(match?.consume == true)

        // ⌘⌥Space must not fire an ⌥Space binding.
        let commandOptionSpace = event(
            kind: .keyDown, keyCode: 49,
            flags: CGEventFlagsShim.alternate | CGEventFlagsShim.command
        )
        #expect(HotkeyEngine.match(event: commandOptionSpace, against: trigger) == nil)
    }

    @Test("Mouse side buttons are first-class triggers")
    func mouseButtons() {
        let trigger = Trigger.mouseButton(3)
        #expect(HotkeyEngine.match(
            event: event(kind: .mouseDown, mouseButton: 3), against: trigger
        )?.edge == .press)
        #expect(HotkeyEngine.match(
            event: event(kind: .mouseUp, mouseButton: 3), against: trigger
        )?.edge == .release)
        #expect(HotkeyEngine.match(
            event: event(kind: .mouseDown, mouseButton: 4), against: trigger
        ) == nil)
    }
}

private enum CGEventFlagsShim {
    static let command: UInt64 = 0x0010_0000
    static let alternate: UInt64 = 0x0008_0000
}

@MainActor
@Suite("Multiple simultaneous bindings")
struct MultipleBindingTests {

    private func settings(_ shortcuts: [Shortcut]) -> MasterfulKit.Settings {
        var settings = MasterfulKit.Settings()
        settings.triggers = shortcuts
        return settings
    }

    private func event(
        kind: RawInputEvent.Kind, keyCode: UInt16 = 0, flags: UInt64 = 0, mouseButton: Int = 0
    ) -> RawInputEvent {
        RawInputEvent(
            kind: kind, keyCode: keyCode, rawFlags: flags,
            mouseButton: mouseButton, timestamp: 0
        )
    }

    @Test("Every configured binding is matched, not only the first")
    func allBindingsMatch() {
        // The clamshell case: Globe on the built-in keyboard and a mouse side
        // button must both be live without the user re-recording when they dock.
        let globe = event(
            kind: .flagsChanged, keyCode: 63, flags: ModifierKey.function.deviceMask
        )
        let mouse = event(kind: .mouseDown, mouseButton: 3)

        #expect(HotkeyEngine.match(event: globe, against: .modifier(.function))?.edge == .press)
        #expect(HotkeyEngine.match(event: mouse, against: .mouseButton(3))?.edge == .press)
        // ...and neither matches the other's binding.
        #expect(HotkeyEngine.match(event: globe, against: .mouseButton(3)) == nil)
        #expect(HotkeyEngine.match(event: mouse, against: .modifier(.function)) == nil)
    }

    @Test("Settings carry every binding and name them together")
    func settingsHoldMultiple() {
        let configured = settings([
            .globeKey,
            Shortcut(trigger: .mouseButton(3)),
            Shortcut(trigger: .key(code: 49, modifiers: [.option])),
        ])
        #expect(configured.triggers.count == 3)
        #expect(configured.primaryTrigger == .globeKey)
        #expect(configured.triggersDisplayString.contains("or"))
    }

    @Test("A single-binding install migrates to the list")
    func migratesLegacySettings() throws {
        // Settings written before multiple bindings existed stored one
        // `pushToTalk`. Those installs must not silently lose their shortcut.
        let legacy = """
        {"pushToTalk":{"trigger":{"mouseButton":{"_0":3}}},"soundEffects":true}
        """
        let decoded = try JSONDecoder().decode(
            MasterfulKit.Settings.self, from: Data(legacy.utf8)
        )
        #expect(decoded.triggers == [Shortcut(trigger: .mouseButton(3))])
        #expect(decoded.soundEffects)
    }

    @Test("Unknown and missing keys fall back to defaults instead of throwing")
    func tolerantDecoding() throws {
        // Swift's synthesised decoder throws on any missing key, which would
        // reset the user's whole configuration every time a setting is added.
        let sparse = #"{"soundEffects":true}"#
        let decoded = try JSONDecoder().decode(
            MasterfulKit.Settings.self, from: Data(sparse.utf8)
        )
        #expect(decoded.soundEffects)
        #expect(decoded.triggers == [.globeKey])
        #expect(decoded.refinement == .rules)
    }

    @Test("Settings round-trip through encoding")
    func roundTrip() throws {
        var original = MasterfulKit.Settings()
        original.triggers = [.globeKey, Shortcut(trigger: .mouseButton(4))]
        original.refinement = .onDevice
        original.duckOtherAudio = false
        original.duckLevel = 0.4
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MasterfulKit.Settings.self, from: data)
        #expect(decoded == original)
    }

    /// The reason the decoder is written by hand: a file saved before ducking
    /// existed must gain the new keys at their defaults, rather than throwing
    /// and silently resetting everything else the user configured.
    @Test("Settings saved before ducking existed decode with it on")
    func decodesFileWithoutDuckingKeys() throws {
        let legacy = "{\"refinement\":\"onDevice\",\"voiceCommandPrefix\":\"dash\"}"
        let decoded = try JSONDecoder().decode(
            MasterfulKit.Settings.self, from: Data(legacy.utf8)
        )
        #expect(decoded.duckOtherAudio == true)
        #expect(decoded.duckLevel == 0.25)
        #expect(decoded.refinement == .onDevice)
        #expect(decoded.voiceCommandPrefix == "dash")
    }
}
