#!/usr/bin/env swift
import AppKit

// Rebuild with: swift Scripts/build_midas_icon.swift
// Draws original Midas artwork from a native SF Symbol. Preserves upstream Icon.icns.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("work/midas-icon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { fatalError("Cannot create icon bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSColor(calibratedRed: 0.977, green: 0.970, blue: 0.939, alpha: 1).setFill()
    tile.fill()
    NSColor(calibratedRed: 0.73, green: 0.63, blue: 0.40, alpha: 0.25).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    guard let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 480, weight: .regular))
    else { fatalError("Missing native sparkles symbol") }
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor(calibratedRed: 0.64, green: 0.45, blue: 0.14, alpha: 1).setFill()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let targetWidth: CGFloat = 548
    let targetHeight = targetWidth * symbol.size.height / symbol.size.width
    tinted.draw(in: NSRect(
        x: (1024 - targetWidth) / 2,
        y: (1024 - targetHeight) / 2,
        width: targetWidth,
        height: targetHeight))
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon")
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let destination = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try renderIcon(pixels: points * scale).write(to: destination)
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", root.appendingPathComponent("Midas.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created Midas.icns; upstream Icon.icns unchanged.")
