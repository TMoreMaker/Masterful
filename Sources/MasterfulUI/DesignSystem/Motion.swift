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
    ///
    /// Held as a `Spring` for the same reason as `morphSpring` below: this is
    /// the app's signature move, and the specimen renderer samples this exact
    /// curve frame by frame so the documented entrance is the shipping
    /// entrance. `bounce: 0.41` is `.snappy(extraBounce: 0.26)` written out —
    /// `.snappy` is bounce 0.15 plus whatever extra it is given.
    public static let enterSpring = Spring(duration: 0.40, bounce: 0.41)
    public static let enter = Animation.spring(enterSpring)

    /// Compact ↔ expanded, and any change to the island's size. The signature
    /// move: the shape is one continuous object growing, so the bounce has to
    /// be present but restrained or the card wobbles like jelly.
    public static let islandSpring = Spring(duration: 0.46, bounce: 0.35)
    public static let island = Animation.spring(islandSpring)

    /// Changing contents inside a stable shape: listening → thinking → done.
    ///
    /// Held as a `Spring` rather than only as an `Animation` because the
    /// waveform→ball coalescence is a curve someone has to be able to *look
    /// at*: `Spring.value(target:time:)` lets the specimen renderer sample this
    /// exact spring frame by frame, so the documented morph is the shipping
    /// morph rather than a hand-drawn approximation of it. Same reasoning as
    /// rendering the island's states out of `HUDView` instead of screenshotting
    /// them.
    ///
    /// `bounce: 0.25` is `.snappy(extraBounce: 0.10)` written out — `.snappy`
    /// is bounce 0.15 plus whatever extra it is given.
    public static let morphSpring = Spring(duration: 0.34, bounce: 0.25)
    public static let morph = Animation.spring(morphSpring)

    /// The waveform closing into the ball, and the one place the island is
    /// deliberately slower than everything else around it.
    ///
    /// Under `morph` the fusion took three frames: correct as a state change,
    /// useless as a *depiction*. The whole claim of that move is that four
    /// things become one thing, and at 0.34s the eye gets the before and the
    /// after and none of the argument in between. Half a second is long enough
    /// to read the join and still short enough that nobody is waiting on it.
    ///
    /// Barely any bounce, unlike the island's own springs: the shape is meant
    /// to arrive like liquid settling, and a ball that overshoots and springs
    /// back is a rubber one.
    public static let coalesceSpring = Spring(duration: 0.52, bounce: 0.08)
    public static let coalesce = Animation.spring(coalesceSpring)

    /// Leaving. Fast and unspringy — a bouncy exit reads as indecision.
    ///
    /// `bounce: 0` *is* `.smooth`; writing it as a `Spring` changes nothing
    /// about the animation and lets the renderer sample the retraction the same
    /// way it samples the entrance.
    public static let exitSpring = Spring(duration: 0.22, bounce: 0)
    public static let exit = Animation.spring(exitSpring)

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
