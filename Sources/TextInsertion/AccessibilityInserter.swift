import ApplicationServices
import Foundation
import MasterfulKit

/// Writes directly into the focused element via `AXSelectedText`.
///
/// The cleanest option when it works: no clipboard is touched, no keystrokes are
/// synthesised, and the text replaces the selection exactly as typing would.
///
/// The catch, and the reason this file is more careful than it looks: Chromium
/// and Electron apps — Chrome, VS Code, Slack, Discord — accept the write, return
/// `.success`, report the attribute as settable, and then do nothing at all.
/// Trusting the return value means reporting success for text that was silently
/// discarded, and because this strategy runs first, the paste fallback never gets
/// a turn. So success here is *proven*, not assumed: the caret has to have moved.
public struct AccessibilityInserter: TextInserter {
    public nonisolated var displayName: String { "Accessibility" }

    public init() {}

    @MainActor
    public func insert(_ text: String, context: FocusContext) async -> InsertionOutcome {
        guard let element = AXBridge.focusedElement() else {
            return .failed("No focused element")
        }

        // Pre-flight. If the caret is not readable we cannot tell afterwards
        // whether the write landed, and a wrong guess in that state means either
        // losing the text or pasting it twice. Declining before touching
        // anything makes the ambiguity impossible.
        guard let before = AXBridge.selectedTextRange(of: element) else {
            return .failed("Caret position unreadable — cannot verify")
        }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, AXBridge.selectedText, &settable) == .success,
              settable.boolValue
        else {
            return .failed("Focused element does not accept text")
        }

        let status = AXUIElementSetAttributeValue(element, AXBridge.selectedText, text as CFTypeRef)
        guard status == .success else {
            return .failed("AXSetAttributeValue failed (\(status.rawValue))")
        }

        // Proof. Inserting at the caret must advance it. An unchanged caret
        // means the app took the write and dropped it.
        guard let after = AXBridge.selectedTextRange(of: element) else {
            return .failed("Insertion could not be confirmed")
        }
        guard after.location != before.location else {
            return .failed("App accepted the text but did not insert it")
        }

        return .inserted(.focusedField)
    }
}
