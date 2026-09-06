import AppKit
import SwiftUI

/// Named motion.
///
/// Springs are described by the feeling they should produce, not by their
/// numbers, so that "the HUD's entrance" can be tuned in one place and stay
/// consistent everywhere it is used.
public enum Motion {

    /// The pill arriving from behind the notch. Slightly underdamped, so it
    /// settles with a hint of overshoot — the Dynamic Island's signature.
    public static let enter = Animation.spring(response: 0.42, dampingFraction: 0.68)

    /// Changing shape in place: listening → thinking → delivered. Tighter than
    /// the entrance, because the user is watching it closely by then.
    public static let morph = Animation.spring(response: 0.34, dampingFraction: 0.82)

    /// Leaving. Fast and unspringy — a bouncy exit reads as indecision.
    public static let exit = Animation.easeIn(duration: 0.16)

    /// Content swapping inside a stable container.
    public static let content = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// The waveform. Stiff enough to track a syllable, damped enough not to ring.
    public static let level = Animation.interpolatingSpring(stiffness: 260, damping: 24)

    /// Honours the accessibility setting.
    ///
    /// Returning `nil` disables the animation entirely rather than shortening
    /// it: Reduce Motion is a request for no movement, not for faster movement.
    public static func honouringPreferences(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }

    public static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var reduceTransparencyEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
