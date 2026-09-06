import CoreGraphics
import Foundation
import MasterfulKit

/// Types the text one synthetic keystroke at a time.
///
/// The last resort. Slower than pasting and can drop characters in apps with
/// aggressive input handling, but it needs neither the clipboard nor
/// Accessibility write access, so it is the only thing that works in a handful
/// of stubborn apps.
public struct TypingInserter: TextInserter {
    public nonisolated var displayName: String { "Simulated typing" }

    /// Unicode payloads are posted in chunks; too large and apps drop the tail.
    private let chunkSize: Int
    private let interChunkDelay: Duration

    public init(chunkSize: Int = 12, interChunkDelay: Duration = .milliseconds(4)) {
        self.chunkSize = chunkSize
        self.interChunkDelay = interChunkDelay
    }

    @MainActor
    public func insert(_ text: String, context: FocusContext) async -> InsertionOutcome {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("No event source")
        }

        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return .failed("Could not create keyboard event")
            }

            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
                event.post(tap: .cgAnnotatedSessionEventTap)
            }

            index = end
            if index < units.count {
                try? await Task.sleep(for: interChunkDelay)
            }
        }
        return .inserted(.focusedField)
    }
}
