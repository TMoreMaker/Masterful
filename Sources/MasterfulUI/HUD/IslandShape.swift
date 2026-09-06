import SwiftUI

/// The island's silhouette.
///
/// Top and bottom corners are independent because the island has two lives. Cut
/// into the top of the screen it shares an edge with the bezel, so its top
/// corners must be square — any rounding there would open a sliver of desktop
/// between the island and the display's edge and destroy the illusion that this
/// is the notch, grown. Floating away from the bezel it is an ordinary card and
/// rounds all four.
///
/// `Animatable` is the point of writing this by hand: during the compact →
/// expanded morph the radius travels from 16 to 30 while the box is also
/// growing, and a corner that snaps halfway through is the single most obvious
/// tell that a shape was swapped rather than resized.
struct IslandShape: InsettableShape, Animatable {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Set by `strokeBorder`, so the hairline sits wholly inside the silhouette
    /// instead of straddling it and being half clipped away.
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        // Radii that exceed half the box produce a self-intersecting path, and
        // the island is genuinely that small in its compact form.
        let limit = min(box.width, box.height) / 2
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: min(topRadius, limit),
                bottomLeading: min(bottomRadius, limit),
                bottomTrailing: min(bottomRadius, limit),
                topTrailing: min(topRadius, limit)
            ),
            style: .continuous
        )
        .path(in: box)
    }
}

/// What the island needs to know about the screen it is drawn on.
///
/// Passed in rather than read from `NSScreen` inside the view: the HUD is
/// rendered into a fixed canvas by a controller that already knows which display
/// the user is looking at, and a view that reaches for the "main" screen would
/// be wrong on exactly the multi-display setups this app has to survive.
public struct HUDMetrics: Equatable, Sendable {
    /// True when the island is cut into the top edge of the display, sharing a
    /// border with the bezel. False when it floats as a card.
    public var isAttached: Bool
    /// Width of the physical notch, or zero on a display without one. The
    /// compact layout straddles this gap the way the Dynamic Island does.
    public var notchWidth: CGFloat
    /// Height of the notch, which is also the compact island's height when
    /// attached — matching it exactly is what makes the two read as one shape.
    public var notchHeight: CGFloat
    /// Distance from the top of the HUD's canvas down to where a *floating*
    /// island begins. Zero when attached, since an attached island starts at
    /// the bezel by definition.
    public var topOffset: CGFloat

    public init(
        isAttached: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        topOffset: CGFloat = 0
    ) {
        self.isAttached = isAttached
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.topOffset = topOffset
    }

    /// A conventional display: no notch to hide inside, so the island is a card.
    public static let floating = HUDMetrics(
        isAttached: false, notchWidth: 0, notchHeight: 0
    )

    /// True when there is a physical notch for the island to grow out of, which
    /// is what lets the collapsed island rest invisibly inside it.
    var hasNotch: Bool { isAttached && notchWidth > 0 && notchHeight > 0 }

    var compactHeight: CGFloat {
        isAttached && notchHeight > 0 ? notchHeight : Token.Island.compactHeight
    }

    /// Where the island's contents may begin vertically. On an attached island
    /// the notch physically occupies the top of the expanded card, so anything
    /// drawn there would be behind the camera housing.
    var contentTopInset: CGFloat {
        isAttached ? notchHeight : 0
    }
}
