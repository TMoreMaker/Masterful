import AppKit
import ApplicationServices
import Foundation
import MasterfulKit

/// What has keyboard focus right now.
public struct FocusContext: Sendable, Equatable {
    public var applicationBundleID: String?
    public var applicationName: String?
    /// The Accessibility role of the focused element, when readable.
    public var role: String?

    public init(applicationBundleID: String? = nil, applicationName: String? = nil, role: String? = nil) {
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.role = role
    }

    /// Roles that accept typed text. Used to decide whether to insert or fall
    /// back to the clipboard.
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    public var looksEditable: Bool {
        guard let role else {
            // Electron and web content frequently expose nothing useful here.
            // Assume editable and let insertion tell us otherwise, rather than
            // refusing to type into half the apps on the machine.
            return true
        }
        return Self.editableRoles.contains(role) || role.hasPrefix("AXWebArea")
    }

    @MainActor
    public static func current() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        return FocusContext(
            applicationBundleID: app?.bundleIdentifier,
            applicationName: app?.localizedName,
            role: AXBridge.focusedElementRole()
        )
    }
}

/// Thin wrapper over the Accessibility C API.
enum AXBridge {
    // Computed rather than stored: `CFString` is not `Sendable`, so a static
    // constant would be shared mutable state as far as Swift 6 is concerned.
    // Bridging a literal per call is free at this frequency.
    static var focusedUIElement: CFString { "AXFocusedUIElement" as CFString }
    static var selectedText: CFString { "AXSelectedText" as CFString }
    static var role: CFString { "AXRole" as CFString }
    static var selectedTextRange: CFString { "AXSelectedTextRange" as CFString }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, focusedUIElement, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// The caret position and selection length in the focused element.
    ///
    /// Used to prove an Accessibility write actually landed. Cheap to read —
    /// unlike `AXValue`, which may be an entire document.
    static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, selectedTextRange, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func focusedElementRole() -> String? {
        guard let element = focusedElement() else { return nil }
        return role(of: element)
    }

    /// The focused element as one app reports it. Chrome answers this when it
    /// leaves the system-wide query unanswered, which is why the correction
    /// watcher asks here first.
    static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, focusedUIElement, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, role, &value) == .success else { return nil }
        return value as? String
    }

    /// The element's whole text. Potentially a whole document, so only the
    /// correction watcher reads it, and only after insertion.
    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
