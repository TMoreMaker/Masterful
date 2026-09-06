#!/usr/bin/env swift
import AppKit
import Foundation

// Generates Resources/AppIcon.icns.
//
// The icon is drawn in code rather than checked in as a binary so it stays
// reviewable: changing the mark is a diff, not an opaque asset swap. Run with
//   make icon

let mint = NSColor(srgbRed: 0.36, green: 0.92, blue: 0.71, alpha: 1)
let deep = NSColor(srgbRed: 0.05, green: 0.055, blue: 0.07, alpha: 1)
let raised = NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)

/// Relative bar heights. Asymmetric on purpose — a symmetric waveform reads as
/// an equaliser graphic rather than as speech.
let bars: [CGFloat] = [0.30, 0.62, 1.00, 0.78, 0.44]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit inside their canvas rather than filling it.
    let inset = size * 0.085
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // Apple's squircle is very close to 22.5% of the side.
    let radius = rect.width * 0.225

    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    context.saveGState()
    squircle.addClip()

    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [raised.cgColor, deep.cgColor] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )
    }

    // A top-edge highlight so the surface reads as slightly convex. It has to
    // fade to nothing: a flat translucent band leaves a hard horizontal seam
    // across the icon, which reads as a rendering fault rather than as light.
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }
    context.restoreGState()

    // Waveform.
    let barWidth = rect.width * 0.082
    let spacing = barWidth * 0.75
    let totalWidth = barWidth * CGFloat(bars.count) + spacing * CGFloat(bars.count - 1)
    var x = rect.midX - totalWidth / 2
    let maxHeight = rect.height * 0.46

    for magnitude in bars {
        let height = max(barWidth, maxHeight * magnitude)
        let barRect = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        mint.setFill()
        path.fill()
        x += barWidth + spacing
    }

    return image
}

func png(_ image: NSImage, size: CGFloat) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 64, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        guard let data = png(drawIcon(size: pixels), size: pixels) else { continue }
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(base)x\(base)\(suffix).png"
        try data.write(to: iconset.appending(path: name))
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns", iconset.path,
    "-o", root.appending(path: "Resources/AppIcon.icns").path,
]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
