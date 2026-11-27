// Draws the app icon and writes Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift
// Two windows on a blue tile: one in place, one sliding back to its dashed outline.
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Tile: the standard macOS icon shape (824 of 1024, rounded).
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.35, green: 0.62, blue: 1, alpha: 1), NSColor(red: 0.16, green: 0.27, blue: 0.82, alpha: 1)])!
        .draw(in: tile, angle: -90)

    func window(_ rect: NSRect, bar: NSColor) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 26 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let body = NSBezierPath(roundedRect: rect, xRadius: 34 * s, yRadius: 34 * s)
        NSColor.white.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        bar.setFill()
        NSRect(x: rect.minX, y: rect.maxY - 70 * s, width: rect.width, height: 70 * s).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + (26 + CGFloat(i) * 38) * s, y: rect.maxY - 48 * s, width: 26 * s, height: 26 * s)).fill()
        }
    }

    // Where the second window belongs.
    let slot = NSBezierPath(roundedRect: r(500, 250, 310, 400), xRadius: 34 * s, yRadius: 34 * s)
    slot.lineWidth = 14 * s
    slot.setLineDash([34 * s, 24 * s], count: 2, phase: 0)
    NSColor.white.withAlphaComponent(0.75).setStroke()
    slot.stroke()

    window(r(215, 420, 420, 350), bar: NSColor(white: 0.9, alpha: 1))
    window(r(420, 215, 310, 400), bar: NSColor(red: 0.83, green: 0.89, blue: 1, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try tool.run()
tool.waitUntilExit()
if CommandLine.arguments.count > 1 { try draw(512).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
try? FileManager.default.removeItem(at: iconset)
print(tool.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
