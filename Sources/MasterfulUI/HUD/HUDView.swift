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
            return CGSize(width: metrics.notchWidth, height: metrics.compactCollapsedHeight)
        }
        switch presentation {
        case .compact:
            return CGSize(
                width: metrics.notchWidth + leadingFlank + trailingFlank,
                height: metrics.compactHeight
            )
        case .expanded:
            return CGSize(
                width: max(Token.Island.expandedWidth, metrics.notchWidth + Token.Space.xxl * 2),
                height: metrics.contentTopInset + Self.expandedContentHeight
            )
        }
    }

    /// Reserved rather than measured. The card's height has to be known before
    /// its text is laid out, because the shape animates to it; two lines of
    /// detail is the most any message here is allowed to be.
    private static let expandedContentHeight: CGFloat = 86

    private var leadingFlank: CGFloat { Token.Island.flankMinWidth }

    /// The trailing flank is sized to whatever it has to hold: a waveform, three
    /// dots, or a readout whose width is measured rather than guessed. A glyph's
    /// worth of slack here is not a rounding error — the bar is symmetric about
    /// the notch, so anything mis-sized on the right visibly drags the whole
    /// island off the camera's centre line.
    private var trailingFlank: CGFloat {
        switch model.phase {
        case .listening:
            return 52
        case .delivered(let delivery):
            return max(
                Token.Island.flankMinWidth,
                Self.width(of: compactReadout(delivery)) + Token.Island.flankPadding * 2
            )
        case .idle, .transcribing, .refining, .inserting, .failed, .blocked:
            return Token.Island.flankMinWidth
        }
    }

    /// AppKit's own text measurement, in the font the label actually uses.
    /// Cheap, exact, and evaluated only when the phase changes.
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
                .frame(width: leadingFlank)
            Color.clear
                .frame(width: metrics.notchWidth)
            trailingActivity
                .frame(width: trailingFlank)
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
            glyph("waveform")

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
        case .listening:
            WaveformView(samples: model.levels, tint: accent)
                .frame(width: 26, height: waveformHeight)

        case .transcribing, .refining, .inserting:
            ThinkingIndicator(tint: accent)

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

    /// Proportional to the bar so the waveform never crowds the black. Capped
    /// because a notch on a 16-inch display is taller than the waveform wants.
    private var waveformHeight: CGFloat {
        min(16, metrics.compactHeight * 0.46)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 19, weight: .medium))
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

private extension HUDMetrics {
    /// The height the island rests at when nothing is happening: the notch's,
    /// so it disappears into it, or nothing on a display without one.
    var compactCollapsedHeight: CGFloat { hasNotch ? notchHeight : 0 }
}
