import AppKit

/// The app icon: the menu bar gauge (`GaugeIcon`) drawn large on a graphite tile, with the needle at
/// rest and only the critical end of the dial in red, so the Dock icon never looks like an alert.
/// `scripts/build-app.sh` renders it with `systat --iconset` and turns it into AppIcon.icns.
@MainActor enum AppIcon {
    /// Every size an .icns holds, as `iconutil` names them.
    static let iconsetSizes: [(name: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { points in
        [("icon_\(points)x\(points).png", points), ("icon_\(points)x\(points)@2x.png", points * 2)]
    }

    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, pixels) in iconsetSizes {
            guard let png = render(pixels: pixels).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: directory.appendingPathComponent(name))
        }
    }

    /// Drawn on the macOS 26 grid: a 1024-unit canvas with an 824-unit rounded tile 100 units in.
    /// Coordinates below have y growing downward, like `GaugeIcon`.
    static func render(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        let scale = CGFloat(pixels) / 1024

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(pixels))
        flip.scaleX(by: scale, yBy: -scale)
        flip.concat()

        let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)

        // A soft drop shadow, as macOS icons carry. Shadow offsets ignore the transform, so scale them.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        shadow.shadowBlurRadius = 24 * scale
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.set()
        color(0x1B1E23).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Graphite, lighter at the top, with a glassy sheen over the upper half and a faint edge.
        // NSGradient's angle is unaffected by the flip: 90 starts the gradient at the top of the icon.
        NSGradient(starting: color(0x3B4049), ending: color(0x1B1E23))?.draw(in: tile, angle: 90)
        NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.20), 0),
                   (NSColor.white.withAlphaComponent(0), 0.5))?.draw(in: tile, angle: 90)
        let edge = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 183.5, yRadius: 183.5)
        edge.lineWidth = 3
        NSColor.white.withAlphaComponent(0.18).setStroke()
        edge.stroke()

        // The gauge: an arc over the top, its last stretch red, the needle at rest, a pivot dot.
        let center = NSPoint(x: 512, y: 640)
        let radius: CGFloat = 250
        stroke(arcFrom: 180, to: 300, center: center, radius: radius, width: 60, color: .white)
        stroke(arcFrom: 318, to: 360, center: center, radius: radius, width: 60, color: color(0xE2343D))
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: point(at: 240, distance: 200, from: center))
        needle.lineWidth = 52
        needle.lineCapStyle = .round
        NSColor.white.setStroke()
        needle.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88)).fill()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func stroke(arcFrom start: CGFloat, to end: CGFloat, center: NSPoint, radius: CGFloat,
                               width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func point(at degrees: CGFloat, distance: CGFloat, from center: NSPoint) -> NSPoint {
        let radians = degrees * .pi / 180
        return NSPoint(x: center.x + distance * cos(radians), y: center.y + distance * sin(radians))
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
