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

    // MARK: - The whole arc

    /// Rest, out of the notch, listening, the coalescence, and back in again.
    ///
    /// The one sequence that shows what the island *is*. The stills cannot: they
    /// cut from a bare notch to a wide bar, and the reader has to be told that
    /// the second grew out of the first rather than watching it happen. Nor can
    /// a screen recording, which contains no notch at all.
    ///
    /// Every size along the way comes from `Motion.enterSpring` and
    /// `Motion.exitSpring` sampled at the frame times and pushed through
    /// `HUDView`'s own geometry, so what is documented here is what the spring
    /// does, not an impression of it. Deliberately stops short of the delivered
    /// state: that changes the bar's *width* as well, which is a second
    /// interpolation this seam does not model, and a strip that faked it would
    /// be exactly the drift these renders exist to prevent.
    enum Cycle {
        static let rest: Double = 0.45
        static let listening: Double = 1.55
        static let thinking: Double = 1.45
        static let closing: Double = 0.50

        static var total: Double { rest + listening + thinking + closing }

        /// When each thing starts, measured from the top of the strip.
        static var opens: Double { rest }
        static var releases: Double { rest + listening }
        static var retracts: Double { rest + listening + thinking }
    }

    static func renderCycle(metrics: HUDMetrics, into directory: URL) {
        let frames = directory.appendingPathComponent("cycle")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        let total = Int(Cycle.total * fps)
        for frame in 0..<total {
            let time = Double(frame) / fps
            let listening = time < Cycle.releases

            // Out under the entrance spring, back in under the exit one. Each
            // spring's clock starts when its own event fires, not when the
            // strip does.
            let growth: Double
            if time < Cycle.opens {
                growth = 0
            } else if time < Cycle.retracts {
                growth = Motion.enterSpring.value(target: 1, time: time - Cycle.opens)
            } else {
                let settled = Motion.enterSpring.value(target: 1, time: Cycle.retracts - Cycle.opens)
                growth = settled
                    - Motion.exitSpring.value(target: settled, time: time - Cycle.retracts)
            }

            let coalescence = listening
                ? 0
                : Motion.coalesceSpring.value(target: 1, time: time - Cycle.releases)

            let model = HUDModel.posed(
                phase: listening ? .listening(.pushToTalk) : .transcribing,
                levels: speech(upTo: min(time, Cycle.releases)),
                coalescence: coalescence,
                clock: time,
                growth: growth
            )
            write(model: model, metrics: metrics, to: frames, index: frame)
        }
        print("  ✓ cycle/   \(total) frames — notch → island → notch, \(Int(fps)) fps")
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
