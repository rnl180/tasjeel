// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the repository root:  swift scripts/make-icon.swift
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels)

    // macOS icon grid: the tile sits inside a margin, with a soft shadow.
    let tile = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let shape = CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [CGColor(red: 0.36, green: 0.25, blue: 0.86, alpha: 1), CGColor(red: 0.78, green: 0.27, blue: 0.62, alpha: 1),
                  CGColor(red: 1.0, green: 0.33, blue: 0.24, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 1, green: 0.8, blue: 0.55, alpha: 0.5),
                                                       CGColor(red: 1, green: 0.8, blue: 0.55, alpha: 0)] as CFArray, locations: [0, 1])!
    let corner = CGPoint(x: tile.maxX - s * 0.1, y: tile.minY + s * 0.08)
    ctx.drawRadialGradient(glow, startCenter: corner, startRadius: 0, endCenter: corner, endRadius: s * 0.5, options: [])
    ctx.restoreGState()

    // The record mark: a ring with a solid dot.
    let centre = CGPoint(x: s / 2, y: s / 2)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(s * 0.052)
    ctx.strokeEllipse(in: CGRect(x: centre.x - s * 0.2, y: centre.y - s * 0.2, width: s * 0.4, height: s * 0.4))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: centre.x - s * 0.098, y: centre.y - s * 0.098, width: s * 0.196, height: s * 0.196))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(points * scale).write(to: iconset.appendingPathComponent(name))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
