// Renders the Unibrow app icon with Core Graphics and writes
// Resources/AppIcon.icns plus docs/icon.png. Vector all the way, so every size
// is crisp; rerun after changing the design:
//
//   swift scripts/make-icon.swift
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Palette

let backgroundTop = NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
let backgroundBottom = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
let browLight = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.20, alpha: 1)
let browDark = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.04, alpha: 1)

// MARK: - Drawing (1024 × 1024 canvas, origin bottom-left)

func drawIcon(in context: CGContext) {
    // macOS icon grid: an 824 pt squircle centred in 1024.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the tile, as system icons have.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    context.addPath(tilePath)
    context.setFillColor(backgroundBottom.cgColor)
    context.fillPath()
    context.restoreGState()

    // Tile: dark graphite gradient.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [backgroundTop.cgColor, backgroundBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Warm glow behind the island.
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [browDark.withAlphaComponent(0.20).cgColor, browDark.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 540), endRadius: 400,
        options: []
    )
    context.restoreGState()

    // Thin top highlight on the tile edge.
    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // The island: a black capsule.
    let island = CGRect(x: 222, y: 420, width: 580, height: 240)
    let islandPath = CGPath(roundedRect: island, cornerWidth: 120, cornerHeight: 120, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    context.addPath(islandPath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(islandPath)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()

    // The unibrow: one thick stroke with two soft arches and a gentle dip
    // where they meet, tapering to points at both ends.
    let brow = CGMutablePath()
    brow.move(to: CGPoint(x: 296, y: 528))
    // Upper edge, left to right.
    brow.addCurve(to: CGPoint(x: 420, y: 606), control1: CGPoint(x: 330, y: 572), control2: CGPoint(x: 370, y: 604))
    brow.addCurve(to: CGPoint(x: 512, y: 590), control1: CGPoint(x: 462, y: 608), control2: CGPoint(x: 490, y: 592))
    brow.addCurve(to: CGPoint(x: 604, y: 606), control1: CGPoint(x: 534, y: 592), control2: CGPoint(x: 562, y: 608))
    brow.addCurve(to: CGPoint(x: 728, y: 528), control1: CGPoint(x: 654, y: 604), control2: CGPoint(x: 694, y: 572))
    // Lower edge, right to left.
    brow.addCurve(to: CGPoint(x: 604, y: 562), control1: CGPoint(x: 690, y: 552), control2: CGPoint(x: 650, y: 564))
    brow.addCurve(to: CGPoint(x: 512, y: 552), control1: CGPoint(x: 566, y: 561), control2: CGPoint(x: 536, y: 552))
    brow.addCurve(to: CGPoint(x: 420, y: 562), control1: CGPoint(x: 488, y: 552), control2: CGPoint(x: 458, y: 561))
    brow.addCurve(to: CGPoint(x: 296, y: 528), control1: CGPoint(x: 374, y: 564), control2: CGPoint(x: 334, y: 552))
    brow.closeSubpath()

    // Two eyes under the brow: this is what makes it read as a face with a
    // unibrow rather than a moustache.
    for x in [430.0, 594.0] {
        let eye = CGRect(x: x - 22, y: 462, width: 44, height: 44)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 18, color: NSColor.white.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
        context.fillEllipse(in: eye)
        context.restoreGState()
    }

    // Glow, then the gradient fill.
    context.saveGState()
    context.setShadow(offset: .zero, blur: 36, color: browDark.withAlphaComponent(0.9).cgColor)
    context.addPath(brow)
    context.setFillColor(browDark.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(brow)
    context.clip()
    let browGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [browLight.cgColor, browDark.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(browGradient, start: CGPoint(x: 512, y: 608), end: CGPoint(x: 512, y: 528), options: [])
    context.restoreGState()
}

// MARK: - Rendering

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.interpolationQuality = .high
    drawIcon(in: context)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = URL(filePath: NSTemporaryDirectory()).appending(path: "Unibrow-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let icns = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try fileManager.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
try render(size: 1024).write(to: root.appending(path: "docs/icon.png"))
print("✓ \(icns.path)")
print("✓ \(root.appending(path: "docs/icon.png").path)")
