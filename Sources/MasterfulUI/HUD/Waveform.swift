import SwiftUI

/// The live input waveform.
///
/// Four bars, not twenty-four. At the size the compact island allows, a dense
/// waveform is a grey smudge: the eye cannot resolve individual bars, so the
/// extra detail costs pixels and returns nothing. Four bars the height of the
/// island read instantly as "your voice is arriving", which is the entire job.
///
/// Two things keep it from looking like a toy. Each bar samples the loudness
/// history at a different lag, so a syllable visibly travels across the group
/// instead of every bar pumping in unison; and a fixed bell-shaped weighting
/// makes the middle bars taller, which gives the cluster a silhouette rather
/// than a picket fence. In silence the bars collapse to a row of dots — present,
/// clearly alive, saying nothing.
///
/// Drawn in one `Canvas` rather than as a stack of animated bars: this redraws
/// thirty times a second, and individual views would mean a layout pass each
/// time for what is ultimately a decoration.
public struct WaveformView: View {
    let samples: [Float]
    let tint: Color
    let bars: Int

    public init(samples: [Float], tint: Color, bars: Int = Token.Size.waveformBars) {
        self.samples = samples
        self.tint = tint
        self.bars = max(1, bars)
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard !samples.isEmpty else { return }

            // Gap as a fixed fraction of bar width rather than of the box, so
            // the group keeps the same rhythm at any size it is asked to draw.
            let ratio: CGFloat = 0.62
            let barWidth = max(2, size.width / (CGFloat(bars) + ratio * CGFloat(bars - 1)))
            let spacing = barWidth * ratio
            // A bar never shrinks below a circle. The floor is what turns
            // silence into a row of dots rather than an empty box, which reads
            // as waiting instead of as broken.
            let minHeight = barWidth

            for index in 0..<bars {
                let magnitude = min(1, gain(CGFloat(level(at: index))) * weight(at: index))
                let height = max(minHeight, min(size.height, magnitude * size.height))
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(tint.opacity(0.45 + 0.55 * Double(magnitude)))
                )
            }
        }
        .animation(Motion.honouringPreferences(Motion.level), value: samples)
    }

    /// Conversational speech sits in the lower half of the normalised range, so
    /// drawn linearly the bars barely leave the floor. The curve lifts ordinary
    /// talking into the top two thirds of the island without letting a shout
    /// clip — which is what makes the waveform look responsive rather than shy.
    private func gain(_ level: CGFloat) -> CGFloat {
        pow(max(0, level), 0.75)
    }

    /// Loudness for one bar, read from its own point in the recent past.
    ///
    /// The rightmost bar gets the newest sample and each bar to its left reads
    /// one stride further back, so a loud syllable enters at the right and
    /// walks out to the left.
    private func level(at index: Int) -> Float {
        let stride = max(1, samples.count / bars)
        let lag = (bars - 1 - index) * stride
        let position = samples.count - 1 - lag
        guard position >= 0 else { return samples[0] }
        return samples[position]
    }

    /// Static per-bar gain: a half-sine across the group, floored so the outer
    /// bars still move. Purely cosmetic, entirely responsible for the cluster
    /// having a shape.
    private func weight(at index: Int) -> CGFloat {
        guard bars > 1 else { return 1 }
        let bell = sin(Double(index + 1) / Double(bars + 1) * .pi)
        let peak = sin(Double(bars / 2 + 1) / Double(bars + 1) * .pi)
        // A half-sine alone is too gentle to see across four bars — it spans
        // barely 15% top to bottom. The exponent steepens it into a silhouette
        // without turning the outer bars into stubs.
        return CGFloat(0.58 + 0.42 * pow(bell / peak, 2.2))
    }
}

/// Three dots for the transcribing and refining phases.
///
/// Driven by `TimelineView` rather than a repeating animation so it stays in
/// step with the display's refresh and stops cleanly when the view goes away.
struct ThinkingIndicator: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: Motion.reduceMotionEnabled)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: Token.Space.xxs) {
                ForEach(0..<3, id: \.self) { index in
                    let offset = Double(index) * 0.22
                    let pulse = (sin((phase - offset) * 4.4) + 1) / 2
                    Circle()
                        .fill(tint.opacity(0.35 + 0.5 * pulse))
                        .frame(width: 5, height: 5)
                        .scaleEffect(Motion.reduceMotionEnabled ? 1 : 0.82 + 0.28 * pulse)
                }
            }
        }
    }
}
