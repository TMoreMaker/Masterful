import AppKit
import MasterfulKit
import SwiftUI

/// The window the HUD lives in.
///
/// Non-activating and incapable of becoming key, which is not a detail — it is
/// the requirement the whole product rests on. If this window takes focus, the
/// text field the user was typing into loses it, and there is nowhere left to
/// insert the transcript. Everything else here follows from keeping that true.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // The pill draws its own shadow; a window shadow would trace the
        // oversized transparent frame instead of the visible shape.
        hasShadow = false
        isMovableByWindowBackground = false
        // Purely informational in this milestone, so it must never intercept a
        // click meant for the app underneath.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,      // follows the user across Spaces
            .fullScreenAuxiliary,   // visible over full-screen apps
            .stationary,            // does not slide during Mission Control
            .ignoresCycle,          // never appears in ⌘`
        ]
        animationBehavior = .none
    }
}
