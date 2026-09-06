import AppKit
import Foundation
import MasterfulKit

/// Picks an insertion strategy and falls back gracefully.
///
/// The ordering in `.automatic` is deliberate. Accessibility first because it is
/// the least invasive when it works. Paste second because it works nearly
/// everywhere. Typing last because it is slow. And if all three fail, the text
/// goes to the clipboard rather than being lost — a user who just spoke three
/// sentences should never end up with nothing.
public struct InsertionCoordinator: Sendable {
    private let strategy: InsertionStrategy

    public init(strategy: InsertionStrategy) {
        self.strategy = strategy
    }

    private var chain: [any TextInserter] {
        switch strategy {
        case .automatic: [AccessibilityInserter(), PasteInserter(), TypingInserter()]
        case .accessibility: [AccessibilityInserter()]
        case .paste: [PasteInserter()]
        case .typing: [TypingInserter()]
        }
    }

    @MainActor
    public func insert(_ text: String) async -> InsertionOutcome {
        guard !SecureInput.isActive else {
            return .failed("Secure input is active")
        }

        let context = FocusContext.current()

        // Nothing editable has focus. Going straight to the clipboard is more
        // useful than typing into whatever happens to be frontmost.
        guard context.looksEditable else {
            Log.insertion.notice("No editable focus — routing to clipboard")
            return copyToClipboard(text)
        }

        for inserter in chain {
            let outcome = await inserter.insert(text, context: context)
            if case .inserted(let destination) = outcome {
                Log.insertion.info(
                    "Inserted \(text.count) chars via \(inserter.displayName, privacy: .public) into \(context.applicationName ?? "unknown", privacy: .public)"
                )
                return .inserted(destination)
            }
            if case .failed(let reason) = outcome {
                // Deliberately `notice`, not `debug`: debug messages are not
                // persisted by default, and a strategy quietly declining is
                // exactly the thing you need to see after the fact when text
                // does not turn up where the user expected it.
                Log.insertion.notice(
                    "\(inserter.displayName, privacy: .public) declined: \(reason, privacy: .public)"
                )
            }
        }

        Log.insertion.warning("All insertion strategies failed — routing to clipboard")
        return copyToClipboard(text)
    }

    @MainActor
    private func copyToClipboard(_ text: String) -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failed("Could not write to pasteboard")
        }
        return .inserted(.clipboard)
    }
}
