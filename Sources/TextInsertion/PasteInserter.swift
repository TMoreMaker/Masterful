import AppKit
import CoreGraphics
import Foundation
import MasterfulKit

/// Puts the text on the pasteboard and synthesises ⌘V, then puts back whatever
/// was there before.
///
/// Universally compatible — Electron, terminals, web views, Java apps — which is
/// why it is the default. The cost is that it briefly owns the user's clipboard,
/// so the snapshot/restore below preserves *all* representations rather than
/// just the string, and restores after a delay long enough for the target app to
/// have actually read the paste.
public struct PasteInserter: TextInserter {
    public nonisolated var displayName: String { "Paste" }

    /// How long to wait before restoring. Long enough for a slow Electron app to
    /// service the paste; short enough that the user cannot notice their
    /// clipboard was borrowed.
    private let restoreDelay: Duration

    public init(restoreDelay: Duration = .milliseconds(220)) {
        self.restoreDelay = restoreDelay
    }

    @MainActor
    public func insert(_ text: String, context: FocusContext) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return .failed("Could not write to pasteboard")
        }

        guard postCommandV() else {
            snapshot.restore(to: pasteboard)
            return .failed("Could not synthesise ⌘V")
        }

        // Restore off the critical path so the HUD can already be collapsing.
        Task { @MainActor in
            try? await Task.sleep(for: restoreDelay)
            snapshot.restore(to: pasteboard)
        }

        return .inserted(.focusedField)
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKeyCode: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }
}

/// A full copy of the pasteboard's contents, across every item and type.
///
/// Saving only `.string` is the common shortcut and it silently destroys copied
/// images, files and rich text. Since this runs on every single dictation, that
/// would be a data-loss bug the user hits several times a day.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
