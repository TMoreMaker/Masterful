import Foundation
import MasterfulKit
import ServiceManagement

/// Login-item registration.
///
/// `SMAppService` registers the bundle itself rather than a helper, which is why
/// this works for an `LSUIElement` app with no separate launcher target. It
/// requires the app to live somewhere stable — registering from a build folder
/// succeeds and then quietly fails to launch later.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// - Returns: the state actually achieved, which may differ from what was
    ///   asked if macOS refused.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return isEnabled
        } catch {
            Log.lifecycle.error(
                "Login item change failed: \(error.localizedDescription, privacy: .public)"
            )
            return isEnabled
        }
    }

    /// Reconciles the system's state with the user's preference.
    static func synchronise(to preference: Bool) {
        guard isEnabled != preference else { return }
        set(preference)
    }
}
