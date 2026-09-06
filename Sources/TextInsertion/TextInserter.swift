import Foundation
import MasterfulKit

public enum InsertionOutcome: Sendable, Equatable {
    case inserted(Destination)
    case failed(String)
}

/// A way of getting text into whatever the user was focused on.
///
/// There is no single method that works everywhere on macOS, which is why this
/// is a protocol with three implementations rather than a function.
public protocol TextInserter: Sendable {
    nonisolated var displayName: String { get }
    @MainActor func insert(_ text: String, context: FocusContext) async -> InsertionOutcome
}
