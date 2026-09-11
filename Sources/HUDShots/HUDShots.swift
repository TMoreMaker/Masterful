import AppKit
import ImageIO
import MasterfulKit
import MasterfulUI
import SwiftUI

/// Renders the island, in every state, straight out of `HUDView`.
///
/// Not screenshots. The specimen sheet's images come from the same view the app
/// draws, through the same `IslandShape`, at the same tokens — for the reason
/// `Tools/make-icon.swift` draws the app icon in code: an image generated from
/// the real thing cannot quietly drift away from what ships, and it regenerates
/// from a clean checkout. `make shots`.
@main
@MainActor
enum HUDShots {

    /// The notch on a 14-inch MacBook Pro, in points. Measured from the running
    /// display when there is one, so the images match the hardware rather than a
    /// number typed in here; these are the fallback for a machine without one.
    static let fallbackNotch = (width: CGFloat(200), height: CGFloat(32))

    /// A fixed loudness history, so the waveform is identical on every run.
    /// Regenerating the sheet should produce byte-identical images unless the
    /// view actually changed.
    static let levels: [Float] = [
        0.10, 0.22, 0.41, 0.63, 0.78, 0.66, 0.48, 0.35,
        0.52, 0.71, 0.88, 0.74, 0.55, 0.39, 0.61, 0.80,
    ]

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "build/shots")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let metrics = notchMetrics()
        print("island metrics — notch \(Int(metrics.notchWidth))×\(Int(metrics.notchHeight)) pt\n")

        for shot in shots {
            render(shot, metrics: metrics, into: output)
        }
        MotionStrip.render(metrics: metrics, into: output)
        print("\n\(shots.count) images → \(output.path)")

        writeAnnouncements(into: output)
    }

    // MARK: - The states worth documenting

    struct Shot {
        let name: String
        let phase: DictationPhase
        let caption: String
        var levels: [Float] = []
        /// False renders the island at rest, collapsed inside the notch.
        var presented: Bool = true
    }

    static let shots: [Shot] = [
        .init(name: "00-rest", phase: .idle,
              caption: "At rest — the island is the notch, and nothing else",
              presented: false),
        .init(name: "01-listening", phase: .listening(.pushToTalk),
              caption: "Listening — push to talk", levels: levels),
        .init(name: "02-latched", phase: .listening(.latched),
              caption: "Listening — latched on", levels: levels),
        .init(name: "03-transcribing", phase: .transcribing,
              caption: "Transcribing"),
        .init(name: "04-delivered", phase: .delivered(
                Delivery(characterCount: 44, wordCount: 9, destination: .focusedField)),
              caption: "Delivered to the focused field"),
        .init(name: "05-delivered-clipboard", phase: .delivered(
                Delivery(characterCount: 44, wordCount: 18, destination: .clipboard)),
              caption: "Delivered to the clipboard — opens, because there is something to read"),
        .init(name: "06-blocked", phase: .blocked(.secureInputActive),
              caption: "Refused — a password field has focus"),
        .init(name: "07-failed", phase: .failed(.noSpeechDetected),
              caption: "Nothing heard"),
        .init(name: "08-failed-permission", phase: .failed(.microphonePermissionDenied),
              caption: "Microphone permission missing"),
    ]

    // MARK: - What each state says

    /// Writes what a VoiceOver user hears, one state per line.
    ///
    /// Read from `HUDAnnouncer` rather than typed out here, for the same reason
    /// the images come from `HUDView`: the moment the recording and the app
    /// disagree, the recording is a lie about the product. `make voice` renders
    /// these through the system speech engine.
    ///
    /// States that say nothing are absent by design, not by omission — the
    /// island announces starting and the outcome, and stays quiet through
    /// transcribing, refining and inserting.
    static func writeAnnouncements(into directory: URL) {
        var lines: [String] = []
        for shot in shots {
            guard let spoken = HUDAnnouncer.spokenText(for: shot.phase) else {
                print("  · \(shot.name) — silent, by design")
                continue
            }
            lines.append("\(shot.name)\t\(spoken)")
            print("  ♪ \(shot.name) — “\(spoken)”")
        }

        let url = directory.appendingPathComponent("announcements.tsv")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("\n\(lines.count) announcements → \(url.path)")
    }

    // MARK: - Rendering

    /// One canvas for every state, so the island grows and shrinks inside a
    /// stable frame — which is what the animation actually looks like, and what
    /// lets these same renders be strung together into the motion strip.
    static let canvas = CGSize(width: 560, height: 148)

    static func render(_ shot: Shot, metrics: HUDMetrics, into directory: URL) {
        let model = HUDModel.posed(
            phase: shot.phase, levels: shot.levels, presented: shot.presented
        )

        let scene = ZStack(alignment: .top) {
            // A stand-in for the desktop behind the island. Without something
            // under it the black shape is invisible on a white page, and the
            // whole point of the compact bar is the gap where the camera is.
            Backdrop()
            MenuBar(height: metrics.notchHeight)
            Notch(width: metrics.notchWidth, height: metrics.notchHeight)
            HUDView(model: model, metrics: metrics)
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage else {
            print("  ✗ \(shot.name) — renderer returned nothing")
            return
        }

        let url = directory.appendingPathComponent("\(shot.name).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("  ✓ \(shot.name).png  \(image.width)×\(image.height)  — \(shot.caption)")
    }

    /// The menu bar the island sits inside.
    ///
    /// Drawn because without it the island is a black lozenge on a gradient and
    /// the entire idea — that this is the notch, grown — is invisible. With the
    /// menu bar either side of it, the shape reads as the top edge of a Mac at a
    /// glance, and the gap in the middle of the compact bar reads as the camera.
    struct MenuBar: View {
        let height: CGFloat

        var body: some View {
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text("Mail").fontWeight(.semibold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                }
                .padding(.leading, 14)
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Wed 9:41")
                }
                .padding(.trailing, 14)
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.82))
            .frame(height: max(height, 24))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The camera housing.
    ///
    /// Drawn here because it cannot be captured. A screenshot or screen
    /// recording of a notched Mac contains no notch: the cutout is in the
    /// panel, not in the framebuffer, and macOS renders the desktop straight
    /// through the region behind it. Point a capture at the top of this display
    /// with the menu bar showing and the wallpaper runs unbroken across the
    /// middle — which would make a recording of the island a black bar hanging
    /// off the top edge of the screen for no visible reason.
    ///
    /// So the one element the hardware contributes is reconstructed, at the
    /// width and height `HUDController` measured from this very display, and
    /// sits *behind* the island exactly as the real one does: covered the
    /// moment the island grows past it, and on its own when it retracts.
    struct Notch: View {
        let width: CGFloat
        let height: CGFloat

        var body: some View {
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: 0, bottomLeading: 10, bottomTrailing: 10, topTrailing: 0
                ),
                style: .continuous
            )
            .fill(.black)
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// A muted desktop gradient. Deliberately quiet: this is a backdrop for the
    /// island, not a wallpaper showing off.
    struct Backdrop: View {
        var body: some View {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.19, blue: 0.27),
                    Color(red: 0.28, green: 0.24, blue: 0.34),
                    Color(red: 0.19, green: 0.26, blue: 0.31),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Geometry

    /// The real notch, read the way `HUDController` reads it, so the documented
    /// island is the one this hardware actually draws.
    static func notchMetrics() -> HUDMetrics {
        if let screen = NSScreen.main,
           screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = max(0, screen.frame.width - left.width - right.width)
            if width > 0 {
                return HUDMetrics(
                    isAttached: true, notchWidth: width, notchHeight: screen.safeAreaInsets.top
                )
            }
        }
        return HUDMetrics(
            isAttached: true,
            notchWidth: fallbackNotch.width,
            notchHeight: fallbackNotch.height
        )
    }
}
