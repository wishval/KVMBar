// Generates AppIcon.icns for KVMBar.
// Usage: swift scripts/generate-icon.swift <output-dir>
// Renders a macOS-style squircle with a display + switch-arrows glyph,
// writes an .iconset and compiles it with iconutil.

import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func tintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    else { return nil }
    return NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func fit(_ imageSize: NSSize, width: CGFloat, centerX: CGFloat, centerY: CGFloat) -> NSRect {
    let scale = width / imageSize.width
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    return NSRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
}

func drawIcon(in canvas: NSRect) {
    let size = canvas.width

    // Squircle with a margin, like system icons
    let inset = size * 0.095
    let rect = canvas.insetBy(dx: inset, dy: inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    // Soft shadow
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.018
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.006)
    shadow.set()
    NSColor.black.set()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Gradient background: deep indigo -> vivid blue
    NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.38, alpha: 1),
        NSColor(calibratedRed: 0.25, green: 0.48, blue: 0.97, alpha: 1),
    ])!.draw(in: squircle, angle: 90)

    // Display glyph
    if let display = tintedSymbol("display", pointSize: 600, weight: .regular) {
        let target = fit(display.size, width: rect.width * 0.62,
                         centerX: rect.midX, centerY: rect.midY)
        display.draw(in: target)

        // Switch arrows inside the screen area (upper part of the glyph)
        if let arrows = tintedSymbol("arrow.left.arrow.right", pointSize: 600, weight: .bold)
            ?? tintedSymbol("arrow.triangle.2.circlepath", pointSize: 600, weight: .bold) {
            let arrowsRect = fit(arrows.size, width: rect.width * 0.24,
                                 centerX: rect.midX,
                                 centerY: target.midY + target.height * 0.06)
            arrows.draw(in: arrowsRect)
        }
    }
}

func renderPNG(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let outURL = URL(fileURLWithPath: outputDir)

if CommandLine.arguments.contains("--preview") {
    renderPNG(pixels: 512, to: outURL.appendingPathComponent("preview.png"))
    print("preview.png written")
    exit(0)
}

let iconsetURL = outURL.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconsetURL)
try! fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    renderPNG(pixels: size, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size).png"))
    renderPNG(pixels: size * 2, to: iconsetURL.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", outURL.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
