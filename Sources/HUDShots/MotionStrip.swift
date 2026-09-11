import AppKit
import ImageIO
import MasterfulKit
import MasterfulUI
import SwiftUI

/// The coalescence, frame by frame, out of the shipping view.
///
/// The island's still states can be shown as stills. This one cannot: the whole
/// argument for the waveform-into-ball morph is that it is *continuous* — four
/// objects becoming one — and a still of the halfway point looks like a mistake
/// rather than like mercury. So it gets rendered as a sequence.
///
/// Nothing here approximates anything. The coalescence values come from
/// `Motion.coalesceSpring` — the same spring SwiftUI runs in the app, sampled at
/// the frame times — and they are pushed through `HUDView` by way of the pose
/// seam on `HUDModel`. If the spring is retuned, this strip changes with it.
@MainActor
enum MotionStrip {

    static let fps: Double = 30
    /// Held in the listening state first, so the strip shows what the bars are
    /// doing before they are asked to stop doing it. A morph shown without its
    /// "before" is just a shape appearing.
    static let listeningSeconds: Double = 0.9
    /// Long enough after the spring settles to see the ball breathe through a
    /// full squash and most of a breath — the two are on different periods, and
    /// a strip that ended at the settle would make it look static.
    static let thinkingSeconds: Double = 2.6

    static func render(metrics: HUDMetrics, into directory: URL) {
        let frames = directory.appendingPathComponent("motion")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        let total = Int((listeningSeconds + thinkingSeconds) * fps)
        for frame in 0..<total {
            let time = Double(frame) / fps
            let listening = time < listeningSeconds

            // The spring's clock starts when the key comes up, not when the
            // strip does.
            let coalescence = listening
                ? 0
                : Motion.coalesceSpring.value(target: 1, time: time - listeningSeconds)

            let model = HUDModel.posed(
                phase: listening ? .listening(.pushToTalk) : .transcribing,
                levels: speech(upTo: time),
                coalescence: coalescence,
                clock: time
            )
            write(model: model, metrics: metrics, to: frames, index: frame)
        }
        print("  ✓ motion/  \(total) frames — waveform → ball, \(Int(fps)) fps")
    }

    /// A plausible loudness history ending at `time`.
    ///
    /// Synthetic rather than recorded, and deliberately not a sine: two
    /// incommensurate tones plus a syllable-rate gate give the bars the uneven,
    /// bursty shape that speech actually has, which is the property the morph
    /// has to look like it is interrupting.
    static func speech(upTo time: Double) -> [Float] {
        (0..<Token.Size.levelHistory).map { index in
            let t = time - Double(Token.Size.levelHistory - 1 - index) * 0.045
            guard t > 0 else { return 0 }
            let syllable = max(0, sin(t * 7.3))
            let body = 0.55 + 0.45 * sin(t * 2.9 + 1.1)
            return Float(min(1, max(0, syllable * body * 0.95)))
        }
    }

    private static func write(model: HUDModel, metrics: HUDMetrics, to directory: URL, index: Int) {
        let scene = ZStack(alignment: .top) {
            HUDShots.Backdrop()
            HUDShots.MenuBar(height: metrics.notchHeight)
            HUDShots.Notch(width: metrics.notchWidth, height: metrics.notchHeight)
            HUDView(model: model, metrics: metrics)
        }
        .frame(width: HUDShots.canvas.width, height: HUDShots.canvas.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return }

        let url = directory.appendingPathComponent(String(format: "frame-%04d.png", index))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
