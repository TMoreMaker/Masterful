#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Answers one question before correction capture is built: after Masterful
// inserts a dictation, can it see the edits the user makes to it?
//
// The logger depends on three things, and Chromium is where each is least
// certain — it is the same engine that accepts an accessibility write and then
// silently discards it (see insertion-probe.swift). So this checks them on the
// real app instead of assuming:
//
//   1. The field's text can be read at all.
//   2. A change to it is visible — by notification, or failing that by polling.
//   3. Moving focus to another field is noticeable, since that is what ends
//      the watch.
//
//   make probe-corrections   # then focus a text field that has some text in it
//
// Edit a word, then click into a different field. It watches for 60 seconds,
// prints every change as a word diff, and modifies nothing.
//
//   make probe-corrections-auto
//
// Does all of that unattended in Chrome: opens correction-probe.html, which
// focuses a seeded field, then edits "paint" to "page" and tabs away with
// synthesised keystrokes. Every keystroke is gated on the focused field holding
// the seeded text, so nothing is ever typed anywhere else.

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func focusedElement() -> AXUIElement? {
    guard let value = attr(AXUIElementCreateSystemWide(), "AXFocusedUIElement"),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func text(of element: AXUIElement) -> String? {
    attr(element, "AXValue") as? String
}

func role(of element: AXUIElement) -> String {
    attr(element, "AXRole") as? String ?? "nil"
}

/// Word-level diff, reduced to the changed runs: the shape the logger records.
func changes(from old: String, to new: String) -> [(from: String, to: String)] {
    let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
    let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
    var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var result: [(String, String)] = []
    var i = 0, j = 0
    var removed: [String] = [], added: [String] = []
    func flush() {
        if !removed.isEmpty || !added.isEmpty {
            result.append((removed.joined(separator: " "), added.joined(separator: " ")))
        }
        removed = []; added = []
    }
    while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] {
            flush(); i += 1; j += 1
        } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
            added.append(b[j]); j += 1
        } else {
            removed.append(a[i]); i += 1
        }
    }
    flush()
    return result
}

guard AXIsProcessTrusted() else {
    print("This process lacks Accessibility permission. Grant it to your terminal in")
    print("System Settings → Privacy & Security → Accessibility, then run again.")
    exit(1)
}

let auto = CommandLine.arguments.contains("--auto")
let seeded = "The simulation is placed front and centre of the paint"

if auto {
    let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("correction-probe.html")
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", "Google Chrome", page.path]
    try open.run()
    open.waitUntilExit()
    print("Opened the test page in Chrome. Probing in 3 seconds…")
    Thread.sleep(forTimeInterval: 3)
} else {
    print("Focus a text field that already has some text in it. Probing in 5 seconds…")
    Thread.sleep(forTimeInterval: 5)
}

guard let app = NSWorkspace.shared.frontmostApplication else {
    print("No frontmost app."); exit(1)
}
print("\nFrontmost: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "—"))")

// Chromium and Electron build their full accessibility tree only when asked:
// Electron answers to AXManualAccessibility, Chrome to AXEnhancedUserInterface.
// Chrome then builds the tree asynchronously, so the first lookups can come back
// empty while it does.
let appElement = AXUIElementCreateApplication(app.processIdentifier)
let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
print("AXManualAccessibility:   \(manual == .success ? "enabled" : "unsupported (\(manual.rawValue))")")

// Enhanced mode is a global switch on the app, and some window managers animate
// differently under it — so it is put back exactly as found when the probe ends.
let enhancedBefore = attr(appElement, "AXEnhancedUserInterface") as? Bool
let enhanced = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
print("AXEnhancedUserInterface: \(enhanced == .success ? "enabled (was \(enhancedBefore.map(String.init) ?? "unset"))" : "unsupported (\(enhanced.rawValue))")")
func restoreEnhanced() {
    guard enhanced == .success else { return }
    AXUIElementSetAttributeValue(
        appElement, "AXEnhancedUserInterface" as CFString,
        (enhancedBefore ?? false) ? kCFBooleanTrue : kCFBooleanFalse
    )
}
signal(SIGINT) { _ in restoreEnhanced(); exit(0) }

/// Asks the app before the system: the system-wide query is the one Chrome
/// most often leaves unanswered.
func focusedField() -> (AXUIElement, String)? {
    if let value = attr(appElement, "AXFocusedUIElement"), CFGetTypeID(value) == AXUIElementGetTypeID() {
        return (value as! AXUIElement, "app")
    }
    if let element = focusedElement() { return (element, "system-wide") }
    return nil
}

var found: (AXUIElement, String)?
for attempt in 1...10 {
    found = focusedField()
    if found != nil {
        if attempt > 1 { print("Focused element appeared after \(attempt) tries") }
        break
    }
    Thread.sleep(forTimeInterval: 0.3)
}
guard let (field, source) = found else {
    print("\n[1] RESULT: no focused element, even after enabling accessibility — corrections cannot be captured here.")
    restoreEnhanced()
    exit(0)
}
print("Focused element via: \(source)")
print("Focused role: \(role(of: field))")

// MARK: 1. Readable

print("\n[1] Read the field")
guard let baseline = text(of: field) else {
    var names: CFArray?
    AXUIElementCopyAttributeNames(field, &names)
    print("    RESULT: no readable AXValue. Attributes offered:")
    print("    \((names as? [String] ?? []).joined(separator: ", "))")
    restoreEnhanced()
    exit(0)
}
let words = baseline.split(whereSeparator: \.isWhitespace).count
print("    RESULT: readable — \(baseline.count) characters, \(words) words")
print("    starts: \"\(baseline.prefix(60))\(baseline.count > 60 ? "…" : "")\"")

// MARK: 2 & 3. Watch

let watchFor: TimeInterval = auto ? 8 : 60
if auto {
    print("\n[2] Editing \"paint\" → \"page\" in 2s. [3] Tabbing to another field in 4s.\n")
} else {
    print("\n[2] Now edit a word in the field. [3] Then click into a different field.")
    print("    Watching for 60 seconds. Ctrl-C to stop early.\n")
}

/// Posts a key, with modifiers, to whatever has focus. Only ever called once
/// the focused field has been proven to be the probe page's.
func press(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.05)
}

func type(_ string: String) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
        let units = Array(string.utf16)
        event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event?.post(tap: .cghidEventTap)
    }
}

func stillOnProbePage() -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome",
          let now = focusedField()?.0 else { return false }
    return CFEqual(now, field)
}

if auto {
    guard baseline == seeded else {
        print("    The focused field is not the probe page's — not typing anything. Aborting.")
        restoreEnhanced()
        exit(1)
    }
    let edit = Timer(timeInterval: 2, repeats: false) { _ in
        guard stillOnProbePage() else { print("    Focus left the probe page — skipping the edit."); return }
        press(125, .maskCommand)        // to the end of the text
        press(51, .maskAlternate)       // delete the previous word
        type("page")
    }
    let leave = Timer(timeInterval: 4, repeats: false) { _ in
        guard stillOnProbePage() else { print("    Focus left the probe page — skipping the tab."); return }
        press(48)                       // Tab to the next field
    }
    RunLoop.main.add(edit, forMode: .default)
    RunLoop.main.add(leave, forMode: .default)
}

var lastSeen = baseline
var notifications = 0
var pollDetections = 0
var focusLeft = false
let start = Date()

func stamp() -> String { String(format: "%5.1fs", Date().timeIntervalSince(start)) }

func report(_ current: String, via source: String) {
    guard current != lastSeen else { return }
    for change in changes(from: lastSeen, to: current) {
        let from = change.from.isEmpty ? "∅" : change.from
        let to = change.to.isEmpty ? "∅" : change.to
        print("    \(stamp())  [\(source)]  \"\(from)\" → \"\(to)\"")
    }
    lastSeen = current
}

// Notifications are preferred — no polling cost — but only count if they fire.
var observer: AXObserver?
let callback: AXObserverCallback = { _, element, _, _ in
    notifications += 1
    if let current = text(of: element) { report(current, via: "notified") }
}
if AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer {
    let added = AXObserverAddNotification(observer, field, kAXValueChangedNotification as CFString, nil)
    print("    value-changed notification: \(added == .success ? "registered" : "refused (\(added.rawValue))")")
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
}

// Polling, as the fallback the logger would use if notifications stay silent.
let poll = Timer(timeInterval: 0.5, repeats: true) { _ in
    if let current = text(of: field), current != lastSeen {
        pollDetections += 1
        report(current, via: "polled")
    }
    if !focusLeft, let now = focusedElement(), !CFEqual(now, field) {
        focusLeft = true
        print("    \(stamp())  focus moved to another element (\(role(of: now)))")
    }
}
RunLoop.main.add(poll, forMode: .default)
RunLoop.main.run(until: Date().addingTimeInterval(watchFor))

// MARK: Verdict

print("\nSummary")
print("    readable:          yes")
print("    notifications:     \(notifications) fired")
print("    changes by poll:   \(pollDetections)")
print("    focus change seen: \(focusLeft ? "yes" : "no")")
if lastSeen == baseline {
    print("    RESULT: no edit was seen. If you did edit, this field hides changes — the logger needs a fallback here.")
} else if notifications > 0 {
    print("    RESULT: works, by notification.")
} else {
    print("    RESULT: works, by polling only.")
}
restoreEnhanced()
