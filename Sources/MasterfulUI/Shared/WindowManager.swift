import AppKit
import MasterfulKit
import SwiftUI

/// Presents the app's ordinary windows.
///
/// An `LSUIElement` app has no windows by default and no Dock icon to click, so
/// each one is created on demand and explicitly brought forward. `NSApp.activate`
/// is required: without it a window from an accessory app opens *behind* whatever
/// the user is looking at, which reads as the app being broken.
@MainActor
public final class WindowManager {
    public static let shared = WindowManager()

    public enum WindowID: String, Hashable, Sendable {
        case onboarding, settings, main
    }

    private var windows: [WindowID: NSWindow] = [:]
    private init() {}

    public func show<Content: View>(
        _ id: WindowID,
        title: String,
        size: CGSize,
        resizable: Bool = true,
        minimumSize: CGSize? = nil,
        bridgesToolbar: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content())
        // A window built by hand gets no toolbar from SwiftUI unless asked, and
        // without one a sidebar toggle or a search field has nowhere to go.
        if bridgesToolbar {
            hosting.sceneBridgingOptions = [.toolbars, .title]
            window.toolbarStyle = .unified
        }
        window.contentView = hosting
        if let minimumSize { window.contentMinSize = minimumSize }
        window.center()

        // Without this the window is retained only by AppKit's ordering, and
        // closing it would deallocate the hosting view mid-animation.
        windows[id] = window

        let observer = WindowCloseObserver { [weak self] in
            self?.windows[id] = nil
        }
        window.delegate = observer
        closeObservers[id] = observer

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func close(_ id: WindowID) {
        windows[id]?.close()
        windows[id] = nil
        closeObservers[id] = nil
    }

    public func isOpen(_ id: WindowID) -> Bool { windows[id] != nil }

    private var closeObservers: [WindowID: WindowCloseObserver] = [:]
}

private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
