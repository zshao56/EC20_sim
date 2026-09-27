import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Assets/EC20Companion.iconset/icon_512x512@2x.png")
let outputDirectory = root.appendingPathComponent(
    "iOS/EC20Mobile/Resources/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)
let outputURL = outputDirectory.appendingPathComponent("AppIcon.png")

guard let source = NSImage(contentsOf: sourceURL),
      let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    throw NSError(domain: "IOSIconGenerator", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Unable to read the 1024 px source icon"
    ])
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    throw NSError(domain: "IOSIconGenerator", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Unable to create an opaque icon context"
    ])
}

// The source Mac artwork has transparent corners. iOS applies its own icon
// mask, so fill those pixels with the artwork's dark blue edge color and emit
// an RGB PNG with no alpha channel.
context.setFillColor(CGColor(red: 0.035, green: 0.20, blue: 0.52, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.interpolationQuality = .high
context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))

guard let result = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else {
    throw NSError(domain: "IOSIconGenerator", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Unable to encode the iOS icon"
    ])
}

try png.write(to: outputURL, options: .atomic)
print("Generated \(outputURL.path)")
