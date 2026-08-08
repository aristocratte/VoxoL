#!/usr/bin/env swift

import AppKit
import Foundation

let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDirectory = repositoryRoot
    .appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)

for representation in representations {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: representation.pixels,
        pixelsHigh: representation.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: representation.pixels, height: representation.pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    drawIcon(in: NSRect(x: 0, y: 0, width: representation.pixels, height: representation.pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: iconDirectory.appendingPathComponent(representation.name), options: .atomic)
}

/// The Grain identity: a halftone sphere of ink dots on warm paper, lit from the upper left,
/// ringed by six arcs. Matches the preflight's `GrainSphere` at readiness 1.
func drawIcon(in rect: NSRect) {
    NSColor.clear.setFill()
    rect.fill()

    let inset = rect.width * 0.07
    let tile = rect.insetBy(dx: inset, dy: inset)
    let tilePath = NSBezierPath(
        roundedRect: tile,
        xRadius: rect.width * 0.22,
        yRadius: rect.width * 0.22
    )
    NSColor(srgbRed: 244 / 255, green: 240 / 255, blue: 232 / 255, alpha: 1).setFill()
    tilePath.fill()

    NSColor(srgbRed: 220 / 255, green: 215 / 255, blue: 206 / 255, alpha: 1).setStroke()
    tilePath.lineWidth = max(1, rect.width * 0.008)
    tilePath.stroke()

    let ink = NSColor(srgbRed: 23 / 255, green: 23 / 255, blue: 19 / 255, alpha: 1)
    let coral = NSColor(srgbRed: 255 / 255, green: 112 / 255, blue: 72 / 255, alpha: 1)
    let centre = NSPoint(x: rect.midX, y: rect.midY)
    let radius = tile.width * 0.295

    // A faint warm atmosphere behind the sphere, like the preflight backdrop.
    if let glow = NSGradient(
        colors: [coral.withAlphaComponent(0.14), coral.withAlphaComponent(0)]
    ) {
        let glowRadius = radius * 1.9
        let glowRect = NSRect(
            x: centre.x - glowRadius,
            y: centre.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )
        NSGraphicsContext.current?.saveGraphicsState()
        tilePath.addClip()
        glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // Light from the upper left (AppKit is y-up).
    var lightX = -0.45
    var lightY = 0.55
    var lightZ = 0.72
    let norm = (lightX * lightX + lightY * lightY + lightZ * lightZ).squareRoot()
    lightX /= norm
    lightY /= norm
    lightZ /= norm

    func hash(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 127.1 + y * 311.7 + 47.3) * 43758.5453
        return value - value.rounded(.down)
    }

    let cell = max(1.6, radius / 14)
    var row = 0.0
    var y = centre.y - radius
    while y <= centre.y + radius {
        var column = 0.0
        var x = centre.x - radius
        while x <= centre.x + radius {
            defer {
                x += cell
                column += 1
            }
            let sampleX = Double(x - centre.x) / Double(radius)
            let sampleY = Double(y - centre.y) / Double(radius)
            let radial = sampleX * sampleX + sampleY * sampleY
            guard radial < 1 else { continue }

            let normalZ = (1 - radial).squareRoot()
            let lambert = max(0, sampleX * lightX + sampleY * lightY + normalZ * lightZ)
            let density = 0.24 + 0.7 * (1 - pow(lambert, 0.95))
            let grain = hash(column, row)
            guard grain < density else { continue }

            let dot = cell * (0.4 + 0.62 * min(1, density))
            let dotRect = NSRect(
                x: x - dot / 2,
                y: y - dot / 2,
                width: dot,
                height: dot
            )
            if grain > 0.88 {
                coral.setFill()
            } else {
                ink.withAlphaComponent(0.9).setFill()
            }
            NSBezierPath(ovalIn: dotRect).fill()
        }
        y += cell
        row += 1
    }

    // The ring of six arcs, a few resting faint — the mark carries its own readiness metaphor.
    let ringRadius = radius * 1.3
    let gap = 6.0
    let litPattern = [1.0, 0.3, 1.0, 1.0, 0.3, 1.0]
    for index in 0..<6 {
        let lit = litPattern[index]
        let start = 90.0 - Double(index) * 60.0 - gap
        let end = start - (60.0 - gap * 2)
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: centre,
            radius: ringRadius,
            startAngle: start,
            endAngle: end,
            clockwise: true
        )
        arc.lineWidth = max(1, radius * (0.03 + 0.02 * lit))
        arc.lineCapStyle = .round
        ink.withAlphaComponent(0.14 + 0.76 * lit).setStroke()
        arc.stroke()
    }
}
