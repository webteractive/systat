import AppKit

/// The menu bar gauge (spec: "The menu bar icon"), drawn from the spec's 18×18 SVG geometry.
enum GaugeIcon {
    static let red = NSColor(srgbRed: 0xC8 / 255, green: 0x23 / 255, blue: 0x2C / 255, alpha: 1)

    static func image(critical: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            (critical ? red : NSColor.black).set()
            let stroke = NSBezierPath()
            stroke.lineWidth = 2
            stroke.lineCapStyle = .round
            // Upper half-circle: (2.5, 12.5) over (9, 6) to (15.5, 12.5). y grows downward here.
            stroke.appendArc(withCenter: NSPoint(x: 9, y: 12.5), radius: 6.5, startAngle: 180, endAngle: 360, clockwise: false)
            stroke.move(to: NSPoint(x: 9, y: 12.5))
            stroke.line(to: critical ? NSPoint(x: 12.6, y: 7.2) : NSPoint(x: 6.2, y: 7.6))
            stroke.stroke()
            NSBezierPath(ovalIn: NSRect(x: 9 - 1.6, y: 12.5 - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = !critical
        image.accessibilityDescription = critical ? "systat: resources critical" : "systat: all normal"
        return image
    }
}
