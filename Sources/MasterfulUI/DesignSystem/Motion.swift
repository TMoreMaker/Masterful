import AppKit
import SwiftUI

/// Named motion.
///
/// Springs are described by the feeling they should produce, not by their
/// numbers, so that "the island opening" can be tuned in one place and stay
/// consistent everywhere it is used.
///
/// These use the `duration`/`extraBounce` spring family rather than
/// `response`/`dampingFraction`. Same solver underneath, but the parameters are
/// the ones the system's own animations are described in, which makes matching
/// the platform's feel a matter of picking numbers instead of guessing.
public enum Motion {

    /// The island opening out of the notch. Bouncy enough that it reads as
    /// physical, short enough that it is over before it can annoy.
    public static let enter = Animation.snappy(duration: 0.40, extraBounce: 0.26)

    /// Compact ↔ expanded, and any change to the island's size. The signature
    /// move: the shape is one continuous object growing, so the bounce has to
    /// be present but restrained or the card wobbles like jelly.
    public static let island = Animation.snappy(duration: 0.46, extraBounce: 0.20)

    /// Changing contents inside a stable shape: listening → thinking → done.
    public static let morph = Animation.snappy(duration: 0.34, extraBounce: 0.10)

    /// Leaving. Fast and unspringy — a bouncy exit reads as indecision.
    public static let exit = Animation.smooth(duration: 0.22)

    /// Content swapping inside a stable container.
    public static let content = Animation.smooth(duration: 0.26)

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

/// How content enters and leaves the island.
///
/// Not a plain cross-fade. The outgoing content shrinks and blurs while the
/// incoming content resolves out of a blur, so that during a morph the shape
/// looks like it is holding something indistinct rather than briefly holding
/// two things at once. It is the difference between the island *becoming*
/// something else and two views being swapped inside a box.
struct IslandContentTransition: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active && !Motion.reduceMotionEnabled ? 6 : 0)
            .scaleEffect(active && !Motion.reduceMotionEnabled ? 0.86 : 1)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .modifier(
            active: IslandContentTransition(active: true),
            identity: IslandContentTransition(active: false)
        )
    }
}
