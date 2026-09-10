import AppKit
import MasterfulKit
import SwiftUI

/// Owns the HUD window and keeps it positioned.
///
/// The window is deliberately much larger than the island and fully transparent.
/// Animating an `NSWindow`'s frame in lockstep with its SwiftUI content is where
/// floating HUDs get their jank — the window resizes on one clock and the layer
/// on another. Giving SwiftUI a generous fixed canvas removes the problem
/// entirely: the window never moves during an animation, and the island is free
/// to spring around inside it.
@MainActor
public final class HUDController {

    public let model = HUDModel()

    private var panel: HUDPanel?
    /// The last phase spoken, so a run of transcript updates — which arrive many
    /// times a second and never change the phase — cannot stutter the same
    /// announcement over and over.
    private var lastAnnounced: DictationPhase?
    private var dismissTask: Task<Void, Never>?
    private var screenObserverTask: Task<Void, Never>?
    private var anchor: HUDAnchor

    /// Comfortably wider and taller than the island can ever be, so the shadow and
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
            // otherwise the island vanishes instead of retracting into the notch.
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

        // The spoken island. Driven from here rather than from the coordinator
        // so that it stays what the visual one is — a pure function of the
        // phase — and so anything that poses a phase is announced, the preview
        // driver included.
        if phase != lastAnnounced {
            lastAnnounced = phase
            if let spoken = HUDAnnouncer.announce(phase, from: panel) {
                Log.hud.debug("announce: \(spoken, privacy: .public)")
            }
        }
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
            rootView: HUDView(model: model, metrics: metrics(for: activeScreen))
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

    /// Everything the island needs to know about where it is being drawn.
    ///
    /// The notch's dimensions are measured rather than assumed. `safeAreaInsets`
    /// gives its height; the two auxiliary areas are the strips of menu bar
    /// either side of it, so what they do not cover is the notch itself. Both
    /// vary by model — a 14-inch and a 16-inch MacBook Pro do not share a notch —
    /// and being a couple of points out is instantly visible, because the whole
    /// effect rests on the island's edge landing exactly on the notch's.
    private func metrics(for screen: NSScreen?) -> HUDMetrics {
        switch anchor {
        case .notch:
            guard let screen else {
                return HUDMetrics(isAttached: true, notchWidth: 0, notchHeight: 0)
            }
            let notch = notchGeometry(of: screen)
            return HUDMetrics(
                isAttached: true,
                notchWidth: notch.width,
                notchHeight: screen.safeAreaInsets.top,
                notchCenterOffset: notch.centerOffset
            )

        case .topCenter:
            // Floating below the menu bar rather than welded to the bezel. Same
            // island, same states, but it reads as a card because it has to —
            // there is no notch here for it to pretend to be.
            return HUDMetrics(
                isAttached: false,
                notchWidth: 0,
                notchHeight: 0,
                topOffset: NSStatusBar.system.thickness + Token.Space.xs
            )

        case .bottomCenter:
            return .floating
        }
    }

    /// How wide the notch is, and how far its centre is from the screen's.
    ///
    /// Both zero on a display without one, which is also exactly what the island
    /// wants: the gap in the middle of the compact bar simply closes.
    ///
    /// The centre is worth measuring rather than assuming. The two menu-bar
    /// strips are not equal — 763pt and 762pt on this 14-inch — so the notch
    /// sits half a point right of the display's midline, and an island centred
    /// on the display reserves its gap half a point off the camera. Computed
    /// from the strips' widths rather than their origins, because on a second
    /// display those origins are in global coordinates that do not start at zero.
    private func notchGeometry(of screen: NSScreen) -> (width: CGFloat, centerOffset: CGFloat) {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return (width: 0, centerOffset: 0) }
        return (
            width: max(0, screen.frame.width - left.width - right.width),
            centerOffset: (left.width - right.width) / 2
        )
    }

    private func reposition() {
        guard let panel, let screen = activeScreen else { return }
        let frame = screen.frame
        let size = Self.canvasSize

        let origin: CGPoint = switch anchor {
        case .notch, .topCenter:
            // Flush with the physical top of the display, menu bar included. An
            // attached island has to start at the bezel; a floating one insets
            // itself from there.
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
            hosting.rootView = HUDView(model: model, metrics: metrics(for: screen))
        }
    }
}
