import Carbon.HIToolbox
import Foundation
import MasterfulKit

/// Detects macOS secure input mode.
///
/// When a password field has focus the system enables secure input, which blocks
/// keystroke observation process-wide. We check it for a stronger reason than
/// "it would not work anyway": dictating into a password field would put the
/// user's credential through a microphone, a recogniser and the clipboard. The
/// right behaviour is to decline, visibly, and say why.
public enum SecureInput {
    public static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}
