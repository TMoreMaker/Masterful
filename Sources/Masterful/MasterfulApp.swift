import AppKit
import MasterfulKit
import SwiftUI

@main
struct MasterfulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(environment: environment)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }

    /// The menu bar icon is the app's only persistent surface, so it doubles as
    /// a status light: filled while listening, struck through when something
    /// needs attention.
    private var menuBarSymbol: String {
        switch environment.coordinator.readiness {
        case .ready:
            environment.coordinator.phase.isCapturing ? "waveform.circle.fill" : "waveform"
        case .starting, .downloadingModel:
            "waveform"
        case .needsAccessibility, .needsMicrophone, .failed:
            "waveform.slash"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces with `LSUIElement`: no Dock icon, no app switcher
        // entry, and critically no stealing focus from the user's text field.
        NSApp.setActivationPolicy(.accessory)
        Log.lifecycle.info("Masterful launched")
        MainActor.assumeIsolated {
            AppEnvironment.shared.bootstrap()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppEnvironment.shared.refreshAfterActivation()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppEnvironment.shared.coordinator.shutdown()
        }
    }
}
