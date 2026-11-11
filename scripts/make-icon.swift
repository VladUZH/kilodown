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
    NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.22, alpha: 1),
               ending: NSColor(calibratedRed: 0.91, green: 0.30, blue: 0.13, alpha: 1))!
        .draw(in: shape, angle: -90)

    // "K" and a down arrow: Kilodown's take on the Markdown mark.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let w = s * 0.08
    let top = s * 0.67, bottom = s * 0.33, mid = s * 0.50

    // The K's strokes run past the cap and base lines and are clipped flat.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 0, y: bottom, width: s, height: top - bottom)).addClip()
    let k = NSBezierPath()
    k.lineWidth = w
    k.lineJoinStyle = .miter
    k.move(to: NSPoint(x: s * 0.27, y: bottom - w))
    k.line(to: NSPoint(x: s * 0.27, y: top + w))
    let reach = (top - mid + w) / (top - mid)   // extend the arms past the clip
    k.move(to: NSPoint(x: s * 0.29 + s * 0.20 * reach, y: mid + (top - mid) * reach))
    k.line(to: NSPoint(x: s * 0.29, y: mid))
    k.line(to: NSPoint(x: s * 0.29 + s * 0.20 * reach, y: mid - (mid - bottom) * reach))
    k.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let stem = NSBezierPath()
    stem.lineWidth = w
    stem.move(to: NSPoint(x: s * 0.69, y: top))
    stem.line(to: NSPoint(x: s * 0.69, y: s * 0.46))
    stem.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: s * 0.575, y: s * 0.48))
    head.line(to: NSPoint(x: s * 0.805, y: s * 0.48))
    head.line(to: NSPoint(x: s * 0.69, y: bottom))
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
