// swift-tools-version: 6.0
import PackageDescription

/// Masterful — a local-first dictation agent for macOS.
///
/// The executable target is deliberately thin: it wires dependencies together and
/// owns nothing. Every subsystem lives in its own library target so it can be
/// exercised in isolation, without a microphone, an event tap, or a focused text
/// field anywhere in sight.
let package = Package(
    name: "Masterful",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Masterful", targets: ["Masterful"]),
        // Measures clean-up quality and latency against a fixed corpus.
        .executable(name: "masterful-eval", targets: ["EvalTool"]),
    ],
    targets: [
        // Pure domain. No AVFoundation, no AppKit, no I/O. Fully deterministic.
        .target(name: "MasterfulKit"),

        // Global input: CGEventTap, shortcut modelling, hold/double-tap resolution.
        .target(name: "InputControl", dependencies: ["MasterfulKit"]),

        // Microphone capture, format conversion, device hot-swap, level metering.
        .target(name: "AudioCapture", dependencies: ["MasterfulKit"]),

        // Speech-to-text behind a protocol. SpeechAnalyzer today, Parakeet later.
        // Depends on AudioCapture for the buffer transport type: transcription
        // consumes captured audio, so the edge points the right way.
        .target(name: "Transcription", dependencies: ["MasterfulKit", "AudioCapture"]),

        // Transcript clean-up. Deterministic rules now, Foundation Models in M3.
        .target(name: "Refinement", dependencies: ["MasterfulKit"]),

        // Getting text into whatever the user was focused on.
        .target(name: "TextInsertion", dependencies: ["MasterfulKit"]),

        // Dictation history, stats and custom vocabulary, on SwiftData.
        .target(name: "Persistence", dependencies: ["MasterfulKit"]),

        // Design system + every pixel the user ever sees.
        .target(
            name: "MasterfulUI",
            dependencies: [
                "MasterfulKit", "InputControl", "Persistence", "Transcription", "Refinement",
            ]
        ),

        .executableTarget(
            name: "Masterful",
            dependencies: [
                "MasterfulKit", "InputControl", "AudioCapture", "Transcription",
                "Refinement", "TextInsertion", "Persistence", "MasterfulUI",
            ]
        ),

        .executableTarget(name: "EvalTool", dependencies: ["MasterfulKit", "Refinement"]),

        .testTarget(name: "MasterfulKitTests", dependencies: ["MasterfulKit"]),
        .testTarget(name: "InputControlTests", dependencies: ["InputControl"]),
        .testTarget(name: "RefinementTests", dependencies: ["Refinement"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ],
    swiftLanguageModes: [.v6]
)
