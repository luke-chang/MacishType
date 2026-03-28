#!/usr/bin/env swift

import AppKit

// MARK: - Argument parsing

let args = Array(CommandLine.arguments.dropFirst())

guard let character = args.first else {
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("""
    Usage: swift \(script) <character> [output_filename]

    Generate a menu bar icon TIFF for macOS input methods.
    The icon is a rounded rectangle with the character cut out as transparent.

    Arguments:
      character        One CJK character or up to two Latin letters (e.g. "注", "MT")
      output_filename  Output filename without extension (default: "MenuIcon")

    Output:
      MacishType/Resources/<output_filename>.tiff (multi-image TIFF with 1x and 2x)

    Examples:
      swift \(script) 注
      swift \(script) 倉 Cangjie
    """)
    exit(1)
}

let outputName = args.count >= 2 ? args[1] : "MenuIcon"

// MARK: - Path resolution

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let projectDir = scriptDir.deletingLastPathComponent()
let resourceDir = projectDir.appendingPathComponent("MacishType/Resources").path

// MARK: - Icon generation

func generateIcon(size: Int, scale: Int, text: String, outputPath: String) {
    let pointSize = size
    let pixelSize = size * scale

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 2,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceWhite,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context

    let cgContext = context.cgContext
    cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    // Transparent background
    cgContext.clear(CGRect(x: 0, y: 0, width: pointSize, height: pointSize))

    let bounds = CGRect(x: 0, y: 0, width: CGFloat(pointSize), height: CGFloat(pointSize))
    let cornerRadius: CGFloat = 3.5
    let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

    // Fill rounded rectangle with black at full alpha
    NSColor(white: 0, alpha: 1).setFill()
    path.fill()

    // Subtract text from the alpha channel using .destinationOut blend mode
    // Stroke centers become transparent, anti-aliased edges become semi-transparent
    cgContext.saveGState()
    path.addClip()
    cgContext.setBlendMode(.destinationOut)

    let fontScale: CGFloat = text.count > 1 ? 0.55 : 0.75
    let fontSize = CGFloat(pointSize) * fontScale
    let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

    let style = NSMutableParagraphStyle()
    style.alignment = .center

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0, alpha: 1),
        .paragraphStyle: style,
    ]

    let string = text as NSString
    let textSize = string.size(withAttributes: attributes)
    let textRect = CGRect(
        x: 0,
        y: (CGFloat(pointSize) - textSize.height) / 2,
        width: CGFloat(pointSize),
        height: textSize.height
    )
    string.draw(in: textRect, withAttributes: attributes)

    cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    let tiffData = rep.tiffRepresentation!
    try! tiffData.write(to: URL(fileURLWithPath: outputPath))
}

// MARK: - Main

let tmpDir = "/tmp/macishtype_icons"
try! FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

let path1x = "\(tmpDir)/\(outputName)_1x.tiff"
let path2x = "\(tmpDir)/\(outputName)_2x.tiff"
generateIcon(size: 16, scale: 1, text: character, outputPath: path1x)
generateIcon(size: 16, scale: 2, text: character, outputPath: path2x)

// Set 2x DPI to 144
let sips = Process()
sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
sips.arguments = ["-s", "dpiWidth", "144", "-s", "dpiHeight", "144", path2x]
sips.standardOutput = FileHandle.nullDevice
sips.standardError = FileHandle.nullDevice
try! sips.run()
sips.waitUntilExit()

// Merge into single multi-image TIFF
let outputPath = "\(resourceDir)/\(outputName).tiff"
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", path1x, path2x, "-out", outputPath]
tiffutil.standardOutput = FileHandle.nullDevice
tiffutil.standardError = FileHandle.nullDevice
try! tiffutil.run()
tiffutil.waitUntilExit()

print("Generated: \(outputPath)")
