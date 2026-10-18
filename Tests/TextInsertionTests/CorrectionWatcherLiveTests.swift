import AppKit
import Foundation
import MasterfulKit
import Testing
@testable import TextInsertion

/// The watcher against a real Chrome, end to end: the probe page is opened, the
/// watch begins exactly as it does after a dictation, a word is fixed with real
/// keystrokes, and focus moves away.
///
/// Opt-in, because it takes over the screen for a few seconds and needs Chrome
/// and Accessibility permission:
///
///     MASTERFUL_LIVE_CHROME=1 swift test --filter CorrectionWatcherLive
@MainActor
@Suite("Correction watcher, live in Chrome",
       .enabled(if: ProcessInfo.processInfo.environment["MASTERFUL_LIVE_CHROME"] == "1"))
struct CorrectionWatcherLiveTests {

    static let seeded = "The simulation is placed front and centre of the paint"

    @Test("A word fixed after dictating is logged, and leaving the field ends the watch")
    func fixIsCaptured() async throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/correction-probe.html")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Google Chrome", page.path]
        try open.run()
        open.waitUntilExit()
        try await Task.sleep(for: .seconds(3))
        try #require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome")

        let watcher = CorrectionWatcher()
        var result: CorrectionResult??
        watcher.begin(inserted: Self.seeded) { result = .some($0) }

        // Let the watch attach, then fix the last word and tab away.
        try await Task.sleep(for: .seconds(2.5))
        try #require(AXBridge.focusedElement().flatMap(AXBridge.value(of:)) == Self.seeded
            || AXBridge.focusedElement(in: AXUIElementCreateApplication(
                NSWorkspace.shared.frontmostApplication!.processIdentifier
            )).flatMap(AXBridge.value(of:)) == Self.seeded,
            "Focus is not on the probe page — not typing anything")
        press(125, .maskCommand)
        press(51, .maskAlternate)
        type("page")
        try await Task.sleep(for: .seconds(1.5))
        press(48)

        for _ in 0..<30 where result == nil { try await Task.sleep(for: .milliseconds(200)) }
        let finished = try #require(result, "The watch never ended")
        let edits = try #require(finished, "The field could not be followed").edits
        #expect(edits == [CorrectionEdit(heard: "paint", written: "page", kind: .word)])
    }

    private func press(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        usleep(50_000)
    }

    private func type(_ string: String) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            let units = Array(string.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
    }
}
