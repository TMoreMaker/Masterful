import AppKit
import MasterfulKit
import SwiftUI

/// The HUD.
///
/// One black shape at the top of the screen that changes size, and nothing else.
/// On a notched Mac it starts out exactly filling the notch — same colour, same
/// height, same bottom edge — so at rest it is genuinely invisible, and when
/// dictation begins the notch appears to *widen*. That is the entire trick, and
/// it only works because there is a single shape throughout: no panel fades in
/// beneath another, nothing cross-dissolves. SwiftUI interpolates one rounded
/// rectangle's width, height and corner radius, and the eye reads the result as
/// a physical object changing shape.
///
/// Two sizes: a bar while things are going well, a card when there is something
/// to read. `DictationPhase.hudPresentation` owns that decision so the view
/// never has to.
public struct HUDView: View {
    @Bindable var model: HUDModel
    let metrics: HUDMetrics

    public init(model: HUDModel, metrics: HUDMetrics) {
        self.model = model
        self.metrics = metrics
    }

    private var presentation: HUDPresentation {
        model.isPresented ? model.phase.hudPresentation : .compact
    }

    public var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .padding(.top, metrics.topOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            Motion.honouringPreferences(model.isPresented ? Motion.enter : Motion.exit),
            value: model.isPresented
        )
        .animation(Motion.honouringPreferences(Motion.island), value: model.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - The shape

    private var island: some View {
        contents
            .frame(width: size.width, height: size.height)
            .background(Palette.island)
            .clipShape(shape)
            // Only a floating island needs an edge. An attached one is welded to
            // the bezel, and a hairline there would draw a line across the top of
            // the display announcing that this is a window.
            .overlay {
                if !metrics.isAttached {
                    shape.strokeBorder(Palette.stroke, lineWidth: 0.5)
                }
            }
            // No shadow, deliberately — see `Palette`. The island is cut into
            // the top of the display rather than hovering over it, and a drop
            // shadow would be a claim about depth that is not true.
            //
            // On a notched display the collapsed island *is* the notch, so it
            // stays fully opaque and simply has nothing to show. Elsewhere there
            // is no notch to hide in, so it has to actually leave.
            .opacity(model.isPresented || metrics.hasNotch ? 1 : 0)
            // Aligned to the camera, not to the screen. The parent centres the
            // island in a canvas that is centred on the display, which is half a
            // point away from where the notch actually is.
            .offset(x: metrics.notchCenterOffset)
    }

    private var shape: IslandShape {
        IslandShape(
            topRadius: metrics.isAttached
                ? 0
                : (isExpanded ? Token.Island.expandedCorner : Token.Island.floatingCompactCorner),
            bottomRadius: isExpanded ? Token.Island.expandedCorner : Token.Island.compactCorner
        )
    }

    private var isExpanded: Bool { presentation == .expanded }

    // MARK: - Geometry

    /// The island's size is the animation. Every visible transition in the HUD —
    /// appearing, opening, closing, leaving — is this one value changing under a
    /// spring, which is why they all feel like the same object.
    private var size: CGSize {
        guard model.isPresented else {
            // Collapsed: exactly the notch, or nothing at all.
            return CGSize(width: metrics.notchWidth, height: metrics.collapsedHeight)
        }
        switch presentation {
        case .compact:
            return CGSize(
                width: metrics.notchReservation + flank * 2,
                height: metrics.compactHeight
            )
        case .expanded:
            return CGSize(
                width: max(
                    Token.Island.expandedWidth,
                    metrics.notchReservation + Token.Space.xxl * 2
                ),
                height: metrics.contentTopInset + Self.expandedContentHeight
            )
        }
    }

    /// Reserved rather than measured. The card's height has to be known before
    /// its text is laid out, because the shape animates to it; two lines of
    /// detail is the most any message here is allowed to be.
    private static let expandedContentHeight: CGFloat = 86

    /// One width, used on **both** sides of the notch.
    ///
    /// It has to be symmetric. The island is centred on the camera, so the gap
    /// it reserves is only over the camera if the two flanks are equal — give
    /// the trailing side more room for a wider readout and the gap slides left
    /// by half the difference, pushing the readout underneath the notch. That
    /// is why the clipping got worse the more words you dictated: the wider the
    /// text, the further off the reservation drifted.
    ///
    /// So the flank is sized for whichever side needs the most, and the other
    /// side gets the same. A checkmark alone in a flank sized for "12 words"
    /// looks deliberate; a readout with its first characters behind the camera
    /// does not.
    private var flank: CGFloat {
        max(Token.Island.flankMinWidth, flankContentWidth)
    }

    /// What the widest side actually has to hold: the activity indicator, or a
    /// readout whose width is measured rather than guessed.
    private var flankContentWidth: CGFloat {
        switch model.phase {
        case .listening, .transcribing, .refining, .inserting:
            // One width across the whole of "we are working on it". The
            // indicator keeps the same 26pt box on both sides of the morph, so
            // holding the flank still means the island does not flinch at the
            // moment the key is released — the shape stays put and the thing
            // inside it changes. It used to narrow here, which read as a
            // second, smaller indicator replacing the first.
            return 52
        case .delivered(let delivery):
            return max(
                Token.Island.flankMinWidth,
                Self.width(of: compactReadout(delivery)) + Token.Island.flankPadding * 2
            )
        case .idle, .failed, .blocked:
            return Token.Island.flankMinWidth
        }
    }

    /// AppKit's own text measurement, in the font the label actually uses.
    /// Cheap, exact, and evaluated only when the phase changes.
    ///
    /// `readoutFont` below must stay the `NSFont` twin of `Typeface.islandReadout`.
    /// Keeping them in step by hand is only tolerable because the island's type is
    /// fixed by design — a scaling font could not be measured ahead of layout at
    /// all, which is the same reason the island opts out of the system text size.
    private static func width(of string: String) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: readoutFont])
            .width
            .rounded(.up)
    }

    private static let readoutFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: 12) ?? base
    }()

    // MARK: - Contents

    @ViewBuilder
    private var contents: some View {
        ZStack {
            if isExpanded {
                expanded.transition(.islandContent)
            } else {
                compact.transition(.islandContent)
            }
        }
        .opacity(model.isPresented ? 1 : 0)
        .animation(Motion.honouringPreferences(Motion.morph), value: model.phase)
    }

    // MARK: Compact

    /// Leading glyph, the notch, trailing activity. The gap in the middle is
    /// load-bearing: it is where the camera is.
    private var compact: some View {
        HStack(spacing: 0) {
            leadingGlyph
                .frame(width: flank)
            Color.clear
                .frame(width: metrics.notchReservation)
            trailingActivity
                .frame(width: flank)
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch model.phase {
        case .listening(let mode):
            // The one piece of state the waveform cannot convey: whether
            // releasing the key will stop this.
            glyph(mode == .latched ? "infinity" : "mic.fill")
                .transition(.islandContent)

        case .transcribing, .refining, .inserting:
            // Not `waveform`. The glyph opposite a thinking indicator has to
            // name the *output*, because the input is over — a second piece of
            // audio imagery here was the other half of why the island looked
            // like it was still listening. A pencil is also the most legible
            // silhouette at 12pt of anything that means this: one diagonal
            // stroke, which is nothing like the mic's vertical capsule.
            //
            // One glyph for all three phases, not three. Transcribing,
            // refining and inserting are the same promise from where the user
            // sits — your words are being written down — and they can pass in
            // under a second, so distinguishing them would only make the
            // island flicker through symbols nobody has time to read.
            glyph("pencil")

        case .delivered:
            glyph("checkmark")
                .transition(.scale(scale: 0.4).combined(with: .opacity))

        case .failed, .blocked, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailingActivity: some View {
        switch model.phase {
        // One case, not two, and that is the whole design. Listening and
        // thinking are the same view at two values of `coalescence`, so
        // SwiftUI animates the number rather than swapping the view — the bars
        // physically converge and fuse into the ball instead of one indicator
        // fading out under another. Splitting this into two branches would give
        // them separate identities and silently restore the cross-dissolve.
        case .listening, .transcribing, .refining, .inserting:
            VoiceIndicator(
                coalescence: model.posedCoalescence ?? (model.phase.isThinking ? 1 : 0),
                samples: model.levels,
                voice: Palette.live,
                thought: Palette.thinking,
                clock: model.posedClock
            )
            .frame(width: 26, height: waveformHeight)
            // Its own spring, overriding the outer `morph` for this subtree
            // only. The glyph beside it still swaps at the island's usual pace;
            // the fusion is the one thing that has to be watchable.
            .animation(
                Motion.honouringPreferences(Motion.coalesce),
                value: model.phase.isThinking
            )

        case .delivered(let delivery):
            // The one number worth reading after the fact, and the only text the
            // compact bar ever shows. It also stops the island looking broken:
            // a lone glyph on the left of the notch with nothing opposite it
            // reads as a missing element rather than as a deliberately quiet one.
            Text(compactReadout(delivery))
                .font(Typeface.islandReadout)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)

        case .failed, .blocked, .idle:
            EmptyView()
        }
    }

    /// A spoken command with no text would otherwise report "0 words", which
    /// says nothing about what actually happened.
    private func compactReadout(_ delivery: Delivery) -> String {
        if delivery.wordCount == 0, let summary = delivery.commandSummary {
            return summary
        }
        return "\(delivery.wordCount) \(delivery.wordCount == 1 ? "word" : "words")"
    }

    /// Proportional to the bar so the indicator never crowds the black. Capped
    /// because a notch on a 16-inch display is taller than the waveform wants.
    /// It is also what sizes the ball, which is why the cap matters twice.
    private var waveformHeight: CGFloat {
        min(16, metrics.compactHeight * 0.46)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(Typeface.islandGlyph)
            .foregroundStyle(accent)
    }

    // MARK: Expanded

    /// Icon tile, headline, one line of what to do about it. Deliberately the
    /// shape of a Now Playing card rather than of an alert: this appears
    /// unbidden over someone else's work and has no business looking modal.
    private var expanded: some View {
        VStack(spacing: 0) {
            // The camera housing lives here on an attached island. Nothing else
            // may.
            Color.clear.frame(height: metrics.contentTopInset)

            HStack(spacing: Token.Space.md) {
                iconTile
                VStack(alignment: .leading, spacing: 2) {
                    Text(expandedTitle)
                        .font(Typeface.islandTitle)
                        .foregroundStyle(Palette.textPrimary)
                    if let detail = expandedDetail {
                        Text(detail)
                            .font(Typeface.islandDetail)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Token.Space.lg)
            .frame(maxHeight: .infinity)
        }
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: Token.Radius.md, style: .continuous)
            .fill(accent.opacity(0.16))
            .frame(width: Token.Island.tile, height: Token.Island.tile)
            .overlay {
                Image(systemName: expandedSymbol)
                    .font(Typeface.islandSymbol)
                    .foregroundStyle(accent)
            }
    }

    private var expandedSymbol: String {
        switch model.phase {
        case .delivered: "doc.on.clipboard.fill"
        case .blocked(let reason):
            reason == .secureInputActive ? "lock.fill" : "hand.raised.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var expandedTitle: String {
        switch model.phase {
        case .delivered(let delivery): deliveredTitle(delivery)
        case .failed(let error): error.userMessage
        case .blocked(let reason): reason.userMessage
        default: ""
        }
    }

    private var expandedDetail: String? {
        switch model.phase {
        case .delivered: "Nothing was focused — press ⌘V to paste."
        case .failed(let error): error.recoverySuggestion
        case .blocked(let reason): reason.recoverySuggestion
        default: nil
        }
    }

    private func deliveredTitle(_ delivery: Delivery) -> String {
        if delivery.wordCount == 0, let summary = delivery.commandSummary {
            return summary
        }
        let unit = delivery.wordCount == 1 ? "word" : "words"
        return "\(delivery.wordCount) \(unit) copied"
    }

    // MARK: - Accent

    /// White while listening, coloured once there is an outcome to report. The
    /// asymmetry is deliberate: recording is the state the user lives in, and it
    /// has to stay quiet; everything after it is over in a second or two and
    /// earns the right to say something with colour.
    private var accent: Color {
        switch model.phase {
        case .idle, .listening: Palette.live
        case .transcribing, .refining, .inserting: Palette.thinking
        case .delivered: Palette.success
        case .failed: Palette.danger
        case .blocked: Palette.warning
        }
    }

    private var accessibilityDescription: String {
        switch model.phase {
        case .idle: "Masterful idle"
        case .listening(let mode):
            mode == .latched ? "Listening continuously" : "Listening"
        case .transcribing, .refining: "Transcribing"
        case .inserting: "Inserting text"
        case .delivered(let delivery):
            delivery.wordCount == 0
                ? (delivery.commandSummary ?? "Done")
                : "Inserted \(delivery.wordCount) words"
        case .failed(let error): "\(error.userMessage). \(error.recoverySuggestion)"
        case .blocked(let reason): "\(reason.userMessage). \(reason.recoverySuggestion)"
        }
    }
}

