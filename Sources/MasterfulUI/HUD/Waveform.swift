import SwiftUI

/// Where the bars are and how tall, given a box to draw in.
///
/// Split out of `WaveformView` because the island's indicator now has to draw
/// this same arrangement while it is turning into something else, and two
/// copies of the staggered-lag trick would drift apart the first time either
/// was tuned.
struct WaveformBars {
    let samples: [Float]
    let bars: Int

    init(samples: [Float], bars: Int) {
        self.samples = samples
        self.bars = max(1, bars)
    }

    /// Gap as a fixed fraction of bar width rather than of the box, so the
    /// group keeps the same rhythm at any size it is asked to draw.
    static let gapRatio: CGFloat = 0.62

    func barWidth(in size: CGSize) -> CGFloat {
        max(2, size.width / (CGFloat(bars) + Self.gapRatio * CGFloat(bars - 1)))
    }

    /// Centre of one bar. The row is laid out from the left edge; the caller
    /// owns any centring.
    func centre(of index: Int, in size: CGSize) -> CGPoint {
        let width = barWidth(in: size)
        let spacing = width * Self.gapRatio
        return CGPoint(
            x: CGFloat(index) * (width + spacing) + width / 2,
            y: size.height / 2
        )
    }

    /// A bar never shrinks below a circle. The floor is what turns silence into
    /// a row of dots rather than an empty box, which reads as waiting instead
    /// of as broken.
    func height(of index: Int, in size: CGSize) -> CGFloat {
        let width = barWidth(in: size)
        return max(width, min(size.height, magnitude(at: index) * size.height))
    }

    /// This bar's share of the box, 0...1.
    func magnitude(at index: Int) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        return min(1, gain(CGFloat(level(at: index))) * weight(at: index))
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
///
/// The island does not use this directly — it uses `VoiceIndicator`, which has
/// to hold the waveform as one end of a morph. This is the plain version, for
/// onboarding, where a waveform is only ever a waveform.
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
            let geometry = WaveformBars(samples: samples, bars: bars)
            let width = geometry.barWidth(in: size)

            for index in 0..<bars {
                let magnitude = geometry.magnitude(at: index)
                let height = geometry.height(of: index, in: size)
                let centre = geometry.centre(of: index, in: size)
                let rect = CGRect(
                    x: centre.x - width / 2,
                    y: centre.y - height / 2,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(tint.opacity(0.45 + 0.55 * Double(magnitude)))
                )
            }
        }
        .animation(Motion.honouringPreferences(Motion.level), value: samples)
    }
}

/// The island's activity indicator: the voice, and then the thought about it.
///
/// One view for both, because they are one event. The old pair — a waveform
/// that vanished and three dots that faded in — had the failure you only see on
/// the hardware: at the top of a screen, in the corner of your eye, *anything
/// small that throbs reads as the waveform*. Listening and thinking were being
/// told apart by hue and by a 12pt glyph, neither of which peripheral vision
/// resolves, so the island appeared to keep listening after the key was up.
///
/// So the states are now separated by the fastest thing the eye reports, which
/// is not colour or shape but **how many things there are**. Listening is four
/// separate objects, jostling, driven by you. Thinking is one object, whole,
/// breathing on its own. You cannot mistake four for one at any size.
///
/// And the way it gets from four to one is the point. `coalescence` runs 0 → 1
/// under the island's own morph spring, and the bars physically converge and
/// fuse: drawn into a blurred layer and then cut with an alpha threshold, so
/// overlapping shapes merge at their boundaries the way two drops of mercury
/// do, rather than sliding over one another. Nothing cross-dissolves, which is
/// the same rule the island's outer shape already obeys — there is one thing on
/// screen throughout, and it changes state. It is the reason the handover reads
/// as *your voice becoming a thought* instead of as one indicator being
/// swapped for another.
///
/// Once merged, the ball is never quite still: four blobs still exist inside it,
/// orbiting slowly under the threshold, so the silhouette undulates instead of
/// pulsing. That is what makes it read as something soft and alive rather than
/// as a circle being scaled — the same reason the waveform staggers its bars.
public struct VoiceIndicator: View, Animatable {
    /// 0 — four bars, driven by the microphone.
    /// 1 — one ball, driven by a clock.
    public var coalescence: Double

    let samples: [Float]
    let bars: Int
    /// The colour of listening, and the colour of thinking. Both, rather than
    /// one resolved tint, because the crossing between them belongs to
    /// `coalescence` too: a `Canvas` cannot animate a colour handed to it, and
    /// a tint that snapped teal a beat before the shape finished merging would
    /// give the whole move away.
    let voice: Color
    let thought: Color
    /// A frozen instant, for the specimen renderer. `nil` runs live.
    ///
    /// The same seam `HUDModel.posed` opens, for the same reason: the
    /// documentation's images have to come out of the shipping view, and a
    /// self-driving animation cannot be photographed without one.
    let clock: TimeInterval?

    public init(
        coalescence: Double,
        samples: [Float],
        bars: Int = Token.Size.waveformBars,
        voice: Color,
        thought: Color,
        clock: TimeInterval? = nil
    ) {
        self.coalescence = coalescence
        self.samples = samples
        self.bars = max(1, bars)
        self.voice = voice
        self.thought = thought
        self.clock = clock
    }

    // `nonisolated` because `Animatable` is not main-actor bound: SwiftUI
    // interpolates this off the main actor while the spring runs. Safe here —
    // it is a stored `Double` on a value type and touches nothing else.
    nonisolated public var animatableData: Double {
        get { coalescence }
        set { coalescence = newValue }
    }

    @ViewBuilder
    public var body: some View {
        if let clock {
            canvas(at: clock)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: Motion.reduceMotionEnabled)) { timeline in
                // Reduce Motion gets the ball's canonical pose rather than
                // whatever instant the clock happened to stop at: a request for
                // no movement, not for movement frozen at random.
                canvas(at: Motion.reduceMotionEnabled ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    // MARK: - Drawing

    private func canvas(at time: TimeInterval) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let progress = min(1, max(0, coalescence))
            let blobs = blobs(in: size, at: time, coalescence: progress)

            // The edges go liquid as the shapes start travelling, not as they
            // start falling — there is nothing to fuse while the bars are still
            // dropping in place. Below this the waveform is drawn plainly: an
            // alpha threshold has no antialiasing to give back, and the state
            // you spend the most time looking at should not pay for the
            // transition out of it.
            let liquid = min(1, progress / 0.34)

            if liquid < 1 {
                // Drawn at full strength, with the gooey pass laid over the top
                // rather than dissolved against it. Two half-opacity copies of
                // the same shapes composite to less than one opaque copy, and
                // the indicator visibly dimmed for a few frames mid-morph.
                for blob in blobs {
                    context.fill(blob.path, with: .color(voice.opacity(blob.opacity)))
                }
            }

            if liquid > 0 {
                var gooey = context
                gooey.opacity = liquid
                // Read bottom-up: blur first, then cut everything above half
                // alpha back to a hard edge. Two shapes whose blurs overlap
                // cross that threshold in the gap between them, which is where
                // the join comes from — there is no shape being drawn there.
                gooey.addFilter(.alphaThreshold(min: 0.5, color: tint(progress)))
                gooey.addFilter(.blur(radius: blurRadius(of: blobs)))
                gooey.drawLayer { layer in
                    for blob in blobs {
                        layer.fill(blob.path, with: .color(.white))
                    }
                }
            }
        }
    }

    /// One drawn element, somewhere between a bar and a quarter of a ball.
    private struct Blob {
        let rect: CGRect
        let opacity: Double
        /// Always a capsule, which is a bar at one end of the morph and a
        /// circle at the other without anything having to switch.
        var path: Path { Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2) }
    }

    /// The morph is two beats, not one, and overlapping them is what makes it
    /// look like a substance rather than a tween.
    ///
    /// **First the bars fall.** Whatever they were doing, they drop to the row
    /// of dots the waveform already draws in silence. That is the sentence
    /// "you have stopped speaking", said in the vocabulary the indicator
    /// already has — it is the same floor, not a new state.
    ///
    /// **Then the dots close.** They travel to the centre and fuse. This beat
    /// starts before the first has finished, so nothing ever pauses; what the
    /// eye gets is a fall that turns into a gather.
    private func blobs(in size: CGSize, at time: TimeInterval, coalescence: Double) -> [Blob] {
        let waveform = WaveformBars(samples: samples, bars: bars)
        let barWidth = waveform.barWidth(in: size)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let orb = Orb(box: size.height)
        let squash = orb.squash(at: time)

        let fall = ease(min(1, coalescence / 0.42))
        let gather = ease(max(0, (coalescence - 0.24) / 0.76))

        return (0..<bars).map { index in
            let barCentre = waveform.centre(of: index, in: size)
            // Beat one: the bar's own height gives way to the silent floor,
            // which is a circle of the bar's width.
            let fallen = lerp(waveform.height(of: index, in: size), barWidth, fall)

            let orbit = orb.orbit(of: index, count: bars, at: time)
            let orbCentre = CGPoint(
                x: centre.x + orbit.dx * squash.width,
                y: centre.y + orbit.dy * squash.height
            )

            // Beat two: dot to blob, and everything travels to the middle.
            let width = lerp(barWidth, orb.component * squash.width, gather)
            let height = lerp(fallen, orb.component * squash.height, gather)
            let x = lerp(barCentre.x, orbCentre.x, gather)
            let y = lerp(barCentre.y, orbCentre.y, gather)

            return Blob(
                rect: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height),
                // The waveform varies its bars by loudness; a single body has
                // one opacity by definition, so the variation is spent as the
                // shapes fuse.
                opacity: lerp(0.45 + 0.55 * Double(waveform.magnitude(at: index)), 1, fall)
            )
        }
    }

    /// Smoothstep. The sub-beats are cut out of one spring's output, and a raw
    /// linear slice of a spring has a corner at each end where it joins.
    private func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }

    /// Proportional to the *blobs*, not to the box — the one number here that
    /// was worth getting wrong first to understand.
    ///
    /// The instinct is to make the blur widest halfway through, since blur is
    /// what bridges a gap. It is also what destroys a shape: cut a blurred disc
    /// at half alpha and it survives only while the blur stays under about a
    /// third of the disc's own width. Scaled to the box, that third was fine
    /// for the ball and far too wide for the four small dots on their way to
    /// it, whose blurred alpha never reached the threshold at all — the
    /// indicator went completely blank for two frames in the middle of the
    /// morph.
    ///
    /// So the blur is a fixed fraction of whatever is currently being drawn,
    /// and the join is left to actual overlap: the blobs genuinely arrive on
    /// top of one another, and the blur only rounds the seam where they meet.
    /// That also means the weld happens late and fast, in the last fifth of the
    /// gather, which is how two drops of anything behave — they hold their own
    /// shape until they are nearly touching and then go at once.
    private func blurRadius(of blobs: [Blob]) -> CGFloat {
        let unit = blobs.map { min($0.rect.width, $0.rect.height) }.min() ?? 2
        return unit * 0.30
    }

    /// White while it is still your voice, teal once it is the machine's
    /// problem — crossing over exactly as the shape does.
    private func tint(_ coalescence: Double) -> Color {
        voice.mix(with: thought, by: coalescence)
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat, _ t: Double) -> CGFloat {
        from + (to - from) * CGFloat(t)
    }

    private func lerp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from + (to - from) * t
    }
}

/// The ball, once the bars have arrived.
///
/// Everything here is a fraction of the box it is given, and every rate is in
/// seconds — the two frequencies are deliberately not multiples of each other,
/// so the squash and the breath drift in and out of phase and the loop never
/// becomes visible.
private struct Orb {
    /// The height available. The ball is sized from this, never from the width:
    /// the trailing flank is wider than it is tall and a ball that filled it
    /// would be an oval.
    let box: CGFloat

    /// Each of the four blobs. Two thirds of the box rather than a quarter of
    /// it, on purpose — they overlap heavily, which is what lets the threshold
    /// read them as one body instead of as a flower.
    var component: CGFloat { box * 0.64 }

    /// How far each blob sits off centre. Small: enough for the silhouette to
    /// breathe, not enough to show four lobes.
    var radius: CGFloat { box * 0.10 }

    /// `component + 2 * radius` is 0.84 of the box, and the squash below can
    /// add 19% to one axis — which lands the widest frame exactly on the edge.
    /// The ball is drawn in a `Canvas`, so anything past that is not a slightly
    /// large ball, it is a flat-sided one.

    /// Squash and stretch. Wide-and-short, then tall-and-narrow, at roughly
    /// constant area — which is what a soft body does and a scaled circle does
    /// not. The slow breath on top keeps it from reading as a metronome.
    func squash(at time: TimeInterval) -> CGSize {
        let squish = sin(time * 2 * .pi / 1.15)
        let breath = 1 + 0.05 * sin(time * 2 * .pi / 1.87)
        return CGSize(
            width: CGFloat(breath * (1 + 0.13 * squish)),
            height: CGFloat(breath * (1 - 0.13 * squish))
        )
    }

    /// Where one blob sits relative to the centre. The ring turns slowly and
    /// each blob's distance from centre wanders on its own period, so the
    /// merged edge is never the same shape twice.
    func orbit(of index: Int, count: Int, at time: TimeInterval) -> CGVector {
        let angle = Double(index) / Double(count) * 2 * .pi + time * 1.05
        let wander = 1 + 0.45 * sin(time * 1.7 + Double(index) * 1.3)
        let distance = radius * CGFloat(wander)
        return CGVector(dx: distance * CGFloat(cos(angle)), dy: distance * CGFloat(sin(angle)))
    }
}
