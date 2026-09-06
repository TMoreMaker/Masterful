import Foundation

extension Bundle {
    /// Marketing version, falling back so debug builds run from the command
    /// line (where there is no bundle) do not display "nil".
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
