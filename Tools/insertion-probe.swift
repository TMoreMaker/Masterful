#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Tests each insertion strategy against whatever app is frontmost.
//
// This exists because the failure it diagnoses is invisible to unit tests.
// Chromium and Electron apps accept an `AXSelectedText` write, report the
// attribute as settable, return `.success`, and then silently discard the text.
// Nothing about that is observable without a real application on the other end,
// so when a user reports "text does not appear in app X", this is the tool that
// answers why.
//
//   make probe          # then switch to the app and focus a text field
//
// Focus the field you want to test, then run it. It reports what each strategy
// would do, and restores the pasteboard afterwards.

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func focusedElement() -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        AXUIElementCreateSystemWide(), "AXFocusedUIElement" as CFString, &value
    ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func caret(_ element: AXUIElement) -> CFRange? {
    guard let value = attr(element, "AXSelectedTextRange"),
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

guard AXIsProcessTrusted() else {
    print("This process lacks Accessibility permission — nothing can be probed.")
    exit(1)
}

// Give the operator time to leave the terminal and focus the field under test.
print("Focus the text field you want to test. Probing in 5 seconds…")
Thread.sleep(forTimeInterval: 5)

let app = NSWorkspace.shared.frontmostApplication
print("\nFrontmost: \(app?.localizedName ?? "unknown") (\(app?.bundleIdentifier ?? "—"))")

guard let element = focusedElement() else {
    print("No focused element. Masterful would route to the clipboard.")
    exit(0)
}
print("Focused role: \(attr(element, "AXRole") as? String ?? "nil")")

// MARK: Accessibility

print("\n[1] Accessibility")
if let before = caret(element) {
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, "AXSelectedText" as CFString, &settable)
    print("    settable: \(settable.boolValue)")

    if settable.boolValue {
        let status = AXUIElementSetAttributeValue(
            element, "AXSelectedText" as CFString, "«probe»" as CFTypeRef
        )
        let after = caret(element)
        print("    set status: \(status.rawValue) (0 == success)")
        print("    caret: \(before.location) → \(after?.location.description ?? "unreadable")")

        if status == .success, let after, after.location != before.location {
            print("    RESULT: works — text inserted and proven")
        } else {
            print("    RESULT: silent failure — declines, falls through to paste")
        }
    } else {
        print("    RESULT: declines — element refuses text")
    }
} else {
    print("    RESULT: caret unreadable — declines without mutating anything")
}

// MARK: Paste

print("\n[2] Paste")
let pasteboard = NSPasteboard.general
let saved = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
    var contents: [NSPasteboard.PasteboardType: Data] = [:]
    for type in item.types where item.data(forType: type) != nil {
        contents[type] = item.data(forType: type)
    }
    return contents
}

pasteboard.clearContents()
pasteboard.setString("«paste»", forType: .string)
if let source = CGEventSource(stateID: .combinedSessionState) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
        else { continue }
        event.flags = .maskCommand
        event.post(tap: .cgAnnotatedSessionEventTap)
    }
}
Thread.sleep(forTimeInterval: 0.8)
let landed = focusedElement().flatMap { attr($0, "AXValue") as? String } ?? ""
print("    RESULT: \(landed.contains("«paste»") ? "works" : "no confirmation (value unreadable or not pasted)")")

pasteboard.clearContents()
if !saved.isEmpty {
    pasteboard.writeObjects(saved.map { contents in
        let item = NSPasteboardItem()
        for (type, data) in contents { item.setData(data, forType: type) }
        return item
    })
}
print("\nPasteboard restored (\(saved.count) item(s)). Remove any «probe» text by hand.")
