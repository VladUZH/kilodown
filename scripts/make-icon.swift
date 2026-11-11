// Draws the app icon into an .iconset folder: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.32, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.16, alpha: 1))!
        .draw(in: shape, angle: -90)

    // "M" and a down arrow: the conventional Markdown mark.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let w = s * 0.075
    let m = NSBezierPath()
    m.lineWidth = w
    m.lineJoinStyle = .miter
    let top = s * 0.66, bottom = s * 0.34
    m.move(to: NSPoint(x: s * 0.24, y: bottom))
    m.line(to: NSPoint(x: s * 0.24, y: top))
    m.line(to: NSPoint(x: s * 0.36, y: s * 0.50))
    m.line(to: NSPoint(x: s * 0.48, y: top))
    m.line(to: NSPoint(x: s * 0.48, y: bottom))
    m.stroke()

    let stem = NSBezierPath()
    stem.lineWidth = w
    stem.move(to: NSPoint(x: s * 0.68, y: top))
    stem.line(to: NSPoint(x: s * 0.68, y: s * 0.46))
    stem.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: s * 0.57, y: s * 0.48))
    head.line(to: NSPoint(x: s * 0.79, y: s * 0.48))
    head.line(to: NSPoint(x: s * 0.68, y: s * 0.32))
    head.close()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
