// Draws the app icon: a prompt on a near-black tile. Usage: swift scripts/make-icon.swift out.png
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

    // The chevron of a prompt, in the app's green.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 300, y: 660))
    chevron.line(to: NSPoint(x: 470, y: 512))
    chevron.line(to: NSPoint(x: 300, y: 364))
    chevron.lineWidth = 78
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor(srgbRed: 0.247, green: 0.725, blue: 0.314, alpha: 1).setStroke()
    chevron.stroke()

    // The cursor after it.
    NSColor(srgbRed: 0.90, green: 0.91, blue: 0.905, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 540, y: 364, width: 184, height: 78), xRadius: 39, yRadius: 39).fill()
    return true
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
