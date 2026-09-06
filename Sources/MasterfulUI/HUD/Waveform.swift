import SwiftUI

/// The live input waveform.
///
/// One `Canvas` rather than a stack of animated bars: at 24 bars redrawing
/// several times a second, individual views would mean hundreds of layout passes
/// a second for a decoration. Canvas draws it in a single pass.
public struct WaveformView: View {
    let samples: [Float]
    let tint: Color

    public init(samples: [Float], tint: Color) {
        self.samples = samples
        self.tint = tint
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard !samples.isEmpty else { return }

            let spacing: CGFloat = 2
            let barWidth = max(
                1.5,
                (size.width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count)
            )

            for (index, sample) in samples.enumerated() {
                // A floor keeps the waveform present in silence — an empty box
                // reads as broken, a flat line reads as listening.
                let magnitude = CGFloat(max(0.06, sample))
                let height = max(2, magnitude * size.height)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(tint.opacity(0.35 + 0.65 * Double(magnitude)))
                )
            }
        }
        .animation(Motion.honouringPreferences(Motion.level), value: samples)
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
