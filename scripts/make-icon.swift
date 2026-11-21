// Draws the app icon: a comment opener, "/*", whose asterisk is an AI spark, on a near-black tile. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // The tile, inset as macOS icons are, with a faint edge so it holds on dark backgrounds.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.095, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.045, blue: 0.04, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.10).setStroke()
    shape.lineWidth = 6
    shape.stroke()

    // The slash of a comment opener, "/*", in Claude Code's periwinkle.
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: 300, y: 320))
    slash.line(to: NSPoint(x: 440, y: 704))
    slash.lineWidth = 78
    slash.lineCapStyle = .round
    NSColor(srgbRed: 0.694, green: 0.725, blue: 0.976, alpha: 1).setStroke()
    slash.stroke()

    // Its asterisk, drawn as an AI spark: four points, with sides pinched in towards the centre.
    let centre: CGFloat = 620, radius: CGFloat = 165, pinch: CGFloat = 26
    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: centre, y: 512 + radius))
    for (x, y) in [(CGFloat(1), CGFloat(0)), (0, -1), (-1, 0), (0, 1)] {
        // Each side bends through the corner of a small square around the centre.
        let corner = NSPoint(x: centre + (x - y) * pinch, y: 512 + (x + y) * pinch)
        spark.curve(to: NSPoint(x: centre + x * radius, y: 512 + y * radius), controlPoint1: corner, controlPoint2: corner)
    }
    spark.close()
    spark.lineJoinStyle = .round
    spark.lineWidth = 14
    let white = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.905, alpha: 1)
    white.setFill()
    white.setStroke()
    spark.fill()
    spark.stroke()
    return true
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
