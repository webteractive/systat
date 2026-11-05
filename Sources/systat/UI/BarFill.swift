import AppKit
import SwiftUI

/// The 8 pt bar under each resource. Its fill is a Core Animation layer, so the ease to a new
/// reading is run by the render server: systat does no per-frame work at all.
struct BarFill: NSViewRepresentable {
    let fraction: Double
    let critical: Bool
    let animate: Bool

    func makeNSView(context: Context) -> BarFillView { BarFillView() }

    func updateNSView(_ view: BarFillView, context: Context) {
        view.set(fraction: min(max(fraction, 0), 1), critical: critical, animate: animate)
    }
}

final class BarFillView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private var fraction = 0.0
    private var critical = false
    private var animate = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for sublayer in [track, fill] {
            sublayer.cornerRadius = 4
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }
    override var wantsUpdateLayer: Bool { true }

    func set(fraction: Double, critical: Bool, animate: Bool) {
        let recolor = critical != self.critical
        self.fraction = fraction
        self.critical = critical
        self.animate = animate
        transaction(animated: animate) { fill.frame = fillFrame }
        if recolor { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        transaction(animated: false) {
            track.frame = bounds
            fill.frame = fillFrame
        }
    }

    /// Colours are resolved here so they follow light and dark mode.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            transaction(animated: animate) {
                track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
                fill.backgroundColor = (critical ? GaugeIcon.red : NSColor.secondaryLabelColor).cgColor
            }
        }
    }

    private var fillFrame: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }

    private func transaction(animated: Bool, _ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        changes()
        CATransaction.commit()
    }
}
