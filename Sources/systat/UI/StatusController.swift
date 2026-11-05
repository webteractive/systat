import AppKit
import SwiftUI

/// Owns the status item and the popover panel.
@MainActor final class StatusController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor: Monitor
    private let openSettings: () -> Void

    init(monitor: Monitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
        super.init()
        item.button?.image = GaugeIcon.image(critical: false)
        item.button?.target = self
        item.button?.action = #selector(toggle)

        popover.behavior = .transient
        popover.delegate = self

        monitor.onCriticalChange = { [weak self] critical in
            self?.item.button?.image = GaugeIcon.image(critical: critical)
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            // The panel exists only while shown: a closed panel left in place would keep re-rendering
            // on every background reading, which costs more CPU than the readings themselves.
            let panel = PanelView(monitor: monitor, openSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettings()
            })
            let host = NSHostingController(rootView: panel)
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        monitor.menuWillOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.menuDidClose()
        popover.contentViewController = nil
    }
}
