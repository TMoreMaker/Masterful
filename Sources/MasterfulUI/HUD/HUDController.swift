import AppKit
import MasterfulKit
import SwiftUI

/// Owns the HUD window and keeps it positioned.
///
/// The window is deliberately much larger than the pill and fully transparent.
/// Animating an `NSWindow`'s frame in lockstep with its SwiftUI content is where
/// floating HUDs get their jank — the window resizes on one clock and the layer
/// on another. Giving SwiftUI a generous fixed canvas removes the problem
/// entirely: the window never moves during an animation, and the pill is free to
/// spring around inside it.
@MainActor
public final class HUDController {

    public let model = HUDModel()

    private var panel: HUDPanel?
    private var dismissTask: Task<Void, Never>?
    private var screenObserverTask: Task<Void, Never>?
    private var anchor: HUDAnchor

    /// Comfortably wider and taller than the pill can ever be, so the shadow and
    /// the overshoot on the entrance spring are never clipped.
    private static let canvasSize = CGSize(width: 720, height: 180)

    public init(anchor: HUDAnchor = .notch) {
        self.anchor = anchor
        // Observed as an async sequence rather than with a block token: the
        // resulting `Task` is `Sendable`, so it can be cancelled from `deinit`
        // where a stored `NSObjectProtocol` observer could not be.
        screenObserverTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: NSApplication.didChangeScreenParametersNotification
            )
            for await _ in notifications {
                guard let self else { return }
                self.reposition()
            }
        }
    }

    deinit {
        screenObserverTask?.cancel()
    }

    public func setAnchor(_ anchor: HUDAnchor) {
        self.anchor = anchor
        reposition()
    }

    // MARK: - Presentation

    public func present() {
        dismissTask?.cancel()
        dismissTask = nil

        let panel = ensurePanel()
        reposition()
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: we want to
        // be visible without ever becoming the active application.
        panel.orderFrontRegardless()
        model.isPresented = true
    }

    public func dismiss(after delay: Duration, onDismissed: @escaping @MainActor () -> Void = {}) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            self.model.isPresented = false
            onDismissed()
            // Let the exit animation finish before the window disappears,
            // otherwise the pill vanishes instead of retracting.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
            self.model.resetLevels()
        }
    }

    // MARK: - Content

    public func apply(phase: DictationPhase, transcript: String) {
        model.phase = phase
        model.transcript = transcript
    }

    public func push(level: AudioLevel) {
        model.push(level: level)
    }

    // MARK: - Geometry

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize)
        )
        let hosting = NSHostingView(
            rootView: HUDView(model: model, anchorInset: anchorInset(for: activeScreen))
        )
        hosting.frame = NSRect(origin: .zero, size: Self.canvasSize)
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// The screen the user is actually looking at — the one under the pointer —
    /// rather than whichever one happens to hold the key window.
    private var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Distance from the top of the window down to where the pill may begin.
    ///
    /// On a notched display `safeAreaInsets.top` is the notch's height, so the
    /// pill tucks exactly beneath it. Elsewhere we fall back to the menu bar's
    /// thickness, which produces the same relationship to the top of the screen.
    private func anchorInset(for screen: NSScreen?) -> CGFloat {
        switch anchor {
        case .bottomCenter:
            return 0
        case .notch:
            guard let screen else { return NSStatusBar.system.thickness }
            let notch = screen.safeAreaInsets.top
            return notch > 0 ? notch : NSStatusBar.system.thickness
        case .topCenter:
            return NSStatusBar.system.thickness + Token.Space.xs
        }
    }

    private func reposition() {
        guard let panel, let screen = activeScreen else { return }
        let frame = screen.frame
        let size = Self.canvasSize

        let origin: CGPoint = switch anchor {
        case .notch, .topCenter:
            CGPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height
            )
        case .bottomCenter:
            CGPoint(
                x: frame.midX - size.width / 2,
                y: screen.visibleFrame.minY + Token.Space.xxl
            )
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        if let hosting = panel.contentView as? NSHostingView<HUDView> {
            hosting.rootView = HUDView(model: model, anchorInset: anchorInset(for: screen))
        }
    }
}
