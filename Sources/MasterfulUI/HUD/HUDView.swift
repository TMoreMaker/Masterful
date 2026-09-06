import MasterfulKit
import SwiftUI

/// The HUD.
///
/// A single capsule that changes size and contents rather than a set of separate
/// panels that cross-fade. That is the whole illusion: because the container is
/// one shape animating between intrinsic sizes, SwiftUI interpolates the
/// geometry and the pill appears to physically reshape itself around whatever it
/// currently has to say.
public struct HUDView: View {
    @Bindable var model: HUDModel
    /// Distance from the top of the window to the notch's lower edge. Content
    /// above this line is masked away, so the pill is genuinely occluded by the
    /// notch on its way out rather than merely fading in beneath it.
    let anchorInset: CGFloat

    public init(model: HUDModel, anchorInset: CGFloat) {
        self.model = model
        self.anchorInset = anchorInset
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isPresented {
                pill
                    .transition(
                        .offset(y: -(Token.Size.hudHeight + Token.Space.md))
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.86, anchor: .top))
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.top, anchorInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Everything above the notch line is clipped, which is what makes the
        // entrance read as "out from behind the notch".
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: anchorInset)
                Rectangle()
            }
        }
        .animation(Motion.honouringPreferences(Motion.enter), value: model.isPresented)
        .animation(Motion.honouringPreferences(Motion.morph), value: model.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Pill

    private var pill: some View {
        HStack(spacing: Token.Space.sm) {
            leading
            label
        }
        .padding(.horizontal, Token.Space.md)
        .frame(height: Token.Size.hudHeight)
        .frame(minWidth: Token.Size.hudMinWidth)
        .background(background)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 0.5)
        )
        .clipShape(Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.34), radius: 18, y: 6)
        // A hairline of the accent bleeding past the shadow. Reads as the pill
        // being lit from within by whatever it is doing.
        .shadow(color: accent.opacity(model.phase.isCapturing ? 0.28 : 0), radius: 14)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var background: some View {
        if Motion.reduceTransparencyEnabled {
            Palette.surface
        } else {
            ZStack {
                Palette.surface.opacity(0.86)
                LinearGradient(
                    colors: [Color.white.opacity(0.07), Color.white.opacity(0.01)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Contents

    @ViewBuilder
    private var leading: some View {
        switch model.phase {
        case .listening(let mode):
            HStack(spacing: Token.Space.xs) {
                WaveformView(samples: model.levels, tint: accent)
                    .frame(width: Token.Size.waveformWidth, height: 18)
                if mode == .latched {
                    // The one piece of state the user cannot infer from the
                    // waveform: whether releasing the key will stop it.
                    Image(systemName: "infinity")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(accent.opacity(Token.Opacity.muted))
                        .transition(.scale.combined(with: .opacity))
                }
            }

        case .transcribing, .refining, .inserting:
            ThinkingIndicator(tint: accent)
                .frame(width: 26)

        case .delivered(let delivery):
            Image(systemName: delivery.destination == .clipboard
                  ? "doc.on.clipboard.fill" : "checkmark.circle.fill")
                .font(.system(size: Token.Size.glyph, weight: .semibold))
                .foregroundStyle(accent)
                .transition(.scale(scale: 0.5).combined(with: .opacity))

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Token.Size.glyph, weight: .semibold))
                .foregroundStyle(accent)

        case .blocked(let reason):
            Image(systemName: reason == .secureInputActive ? "lock.fill" : "hand.raised.fill")
                .font(.system(size: Token.Size.glyph, weight: .semibold))
                .foregroundStyle(accent)

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var label: some View {
        switch model.phase {
        case .listening:
            if model.transcript.isEmpty {
                Text("Listening")
                    .font(Typeface.hudLabel)
                    .foregroundStyle(Palette.textSecondary)
                    .transition(.opacity)
            } else {
                transcriptText
            }

        case .transcribing, .refining, .inserting:
            if model.transcript.isEmpty {
                Text("Transcribing")
                    .font(Typeface.hudLabel)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                transcriptText.opacity(Token.Opacity.subtle)
            }

        case .delivered(let delivery):
            Text(deliveredMessage(delivery))
                .font(Typeface.hudLabel)
                .foregroundStyle(Palette.textPrimary)
                .transition(.opacity)

        case .failed(let error):
            Text(error.userMessage)
                .font(Typeface.hudLabel)
                .foregroundStyle(Palette.textPrimary)

        case .blocked(let reason):
            Text(reason.userMessage)
                .font(Typeface.hudLabel)
                .foregroundStyle(Palette.textPrimary)

        case .idle:
            EmptyView()
        }
    }

    /// Truncates from the *head*, so the newest words stay visible as the
    /// transcript grows past the pill's maximum width.
    private var transcriptText: some View {
        Text(model.transcript)
            .font(Typeface.hudTranscript)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: Token.Size.hudMaxWidth, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func deliveredMessage(_ delivery: Delivery) -> String {
        // A spoken command with no text would otherwise report "0 words", which
        // says nothing about what actually happened.
        if delivery.wordCount == 0, let summary = delivery.commandSummary {
            return summary
        }
        let unit = delivery.wordCount == 1 ? "word" : "words"
        let base = delivery.destination == .clipboard
            ? "Copied · \(delivery.wordCount) \(unit)"
            : "\(delivery.wordCount) \(unit)"
        guard let summary = delivery.commandSummary else { return base }
        return "\(base) · \(summary)"
    }

    // MARK: - Accent

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
        case .failed(let error): error.userMessage
        case .blocked(let reason): reason.userMessage
        }
    }
}
