#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Reports what your input devices actually emit, and what Masterful would bind.
//
//   make probe-mouse
//
// The question this answers: many mice remap their side buttons in the vendor's
// driver, so pressing one sends ⌘[ or ⇧F13 rather than "mouse button 4". A key
// bound that way is still perfectly bindable here — but you need to know which
// one you are actually pressing, and nothing in the UI can tell you.

let deviceMasks: [(name: String, mask: UInt64)] = [
    ("fn", 0x0080_0000), ("caps", 0x0001_0000),
    ("L-ctrl", 0x0000_0001), ("L-shift", 0x0000_0002), ("R-shift", 0x0000_0004),
    ("L-cmd", 0x0000_0008), ("R-cmd", 0x0000_0010), ("L-opt", 0x0000_0020),
    ("R-opt", 0x0000_0040), ("R-ctrl", 0x0000_2000),
]

func heldModifiers(_ flags: UInt64) -> String {
    let held = deviceMasks.filter { flags & $0.mask != 0 }.map(\.name)
    return held.isEmpty ? "none" : held.joined(separator: "+")
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    let flags = event.flags.rawValue

    switch type {
    case .otherMouseDown:
        print("  MOUSE button \(button) down")
        print("     → bindable as: Mouse \(button + 1)")
    case .keyDown:
        print("  KEY down  code=\(keyCode)  modifiers=\(heldModifiers(flags))")
        print("     → bindable as a key/chord")
    case .flagsChanged:
        print("  MODIFIER  code=\(keyCode)  now held: \(heldModifiers(flags))")
        print("     → bindable on its own if you release it without pressing a key")
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

guard AXIsProcessTrusted() else {
    print("Needs Accessibility permission to observe input.")
    exit(1)
}

let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << CGEventType.otherMouseDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap,
    // Listen only. This probe must never swallow anything.
    options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: nil
) else {
    print("Could not create event tap.")
    exit(1)
}

CFRunLoopAddSource(
    CFRunLoopGetCurrent(),
    CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
    .commonModes
)
CGEvent.tapEnable(tap: tap, enable: true)

// Configurable so the window can outlast however long it takes to read the
// instruction and get a hand to the mouse.
let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 20

print("")
print("Watching input for \(Int(seconds)) seconds. Press your mouse side button now.")
print("(Left and right click are ignored — they are never bindable.)")
print("")

CFRunLoopRunInMode(.defaultMode, seconds, false)
print("\nDone. If pressing the button printed nothing at all, your mouse driver")
print("is swallowing it before macOS sees it — remap it to a keystroke in the")
print("mouse's own software, then bind that keystroke here.")
