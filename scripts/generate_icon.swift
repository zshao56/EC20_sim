import AppKit
import CoreGraphics
import Foundation

// Generate the application icon from vector drawing commands so every size
// stays crisp and the bundle has no dependency on an external design tool.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("EC20Companion.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func render(_ pixels: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high

    let backdrop = CGPath(roundedRect: CGRect(x: 40, y: 40, width: 944, height: 944), cornerWidth: 205, cornerHeight: 205, transform: nil)
    context.saveGState()
    context.addPath(backdrop)
    context.clip()
    let blue = CGGradient(
        colorsSpace: space,
        colors: [rgba(0.09, 0.51, 0.90), rgba(0.04, 0.21, 0.55)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(blue, start: CGPoint(x: 130, y: 910), end: CGPoint(x: 900, y: 80), options: [])
    context.setFillColor(rgba(1, 1, 1, 0.08))
    context.fillEllipse(in: CGRect(x: -170, y: 530, width: 790, height: 790))
    context.restoreGState()

    // White SIM card, with its familiar clipped upper-right corner.
    let sim = CGMutablePath()
    sim.move(to: CGPoint(x: 268, y: 230))
    sim.addLine(to: CGPoint(x: 268, y: 760))
    sim.addQuadCurve(to: CGPoint(x: 314, y: 806), control: CGPoint(x: 268, y: 806))
    sim.addLine(to: CGPoint(x: 620, y: 806))
    sim.addLine(to: CGPoint(x: 756, y: 670))
    sim.addLine(to: CGPoint(x: 756, y: 230))
    sim.addQuadCurve(to: CGPoint(x: 710, y: 184), control: CGPoint(x: 756, y: 184))
    sim.addLine(to: CGPoint(x: 314, y: 184))
    sim.addQuadCurve(to: CGPoint(x: 268, y: 230), control: CGPoint(x: 268, y: 184))
    sim.closeSubpath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: rgba(0, 0.08, 0.25, 0.28))
    context.addPath(sim)
    context.setFillColor(rgba(0.97, 0.99, 1))
    context.fillPath()
    context.restoreGState()

    let chip = CGPath(roundedRect: CGRect(x: 345, y: 394, width: 270, height: 226), cornerWidth: 29, cornerHeight: 29, transform: nil)
    context.addPath(chip)
    context.setFillColor(rgba(0.99, 0.72, 0.28))
    context.fillPath()
    context.addPath(chip)
    context.setStrokeColor(rgba(0.72, 0.41, 0.12))
    context.setLineWidth(11)
    context.strokePath()
    context.setStrokeColor(rgba(0.74, 0.45, 0.16, 0.8))
    context.setLineWidth(10)
    for x in [425.0, 535.0] {
        context.move(to: CGPoint(x: x, y: 394))
        context.addLine(to: CGPoint(x: x, y: 620))
    }
    context.move(to: CGPoint(x: 345, y: 507))
    context.addLine(to: CGPoint(x: 615, y: 507))
    context.strokePath()

    // Green SMS bubble remains legible in the smallest Finder icon size.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: rgba(0, 0.08, 0.25, 0.22))
    context.setFillColor(rgba(0.12, 0.76, 0.52))
    context.fillEllipse(in: CGRect(x: 555, y: 132, width: 330, height: 330))
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 625, y: 167))
    tail.addLine(to: CGPoint(x: 565, y: 105))
    tail.addLine(to: CGPoint(x: 705, y: 148))
    tail.closeSubpath()
    context.addPath(tail)
    context.fillPath()
    context.restoreGState()
    context.setFillColor(rgba(1, 1, 1))
    for x in [635.0, 720.0, 805.0] {
        context.fillEllipse(in: CGRect(x: x, y: 272, width: 43, height: 43))
    }

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in variants {
    try render(size).write(to: iconset.appendingPathComponent(name))
}

let icon = assets.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icon.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconGenerator", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
print("Generated \(icon.path)")
