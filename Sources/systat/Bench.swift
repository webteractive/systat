import AppKit
import Darwin
import SwiftUI

/// `systat --bench <seconds>`: runs the real monitor with the menu closed, then open with the real
/// panel in an off-screen window, and prints the CPU each phase used (systat plus its `ps` runs).
enum Bench {
    @MainActor static func run(seconds: Double) async -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let monitor = Monitor()
        monitor.start()
        try? await Task.sleep(for: .seconds(1))   // settle past launch work

        let closedStart = cpuSeconds()
        try? await Task.sleep(for: .seconds(seconds))
        let closed = cpuSeconds() - closedStart

        monitor.menuWillOpen()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 380, height: 760),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PanelView(monitor: monitor, updater: Updater(currentVersion: systatVersion), openSettings: {}))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2))   // let the CPU list become ready
        let openStart = cpuSeconds()
        try? await Task.sleep(for: .seconds(seconds))
        let open = cpuSeconds() - openStart
        window.orderOut(nil)

        print(String(format: "closed: %.3f s CPU in %.0f s = %.2f%%", closed, seconds, closed / seconds * 100))
        print(String(format: "open:   %.3f s CPU in %.0f s = %.2f%%", open, seconds, open / seconds * 100))
        return 0
    }

    private static func cpuSeconds() -> Double {
        func seconds(_ who: Int32) -> Double {
            var usage = rusage()
            getrusage(who, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        return seconds(RUSAGE_SELF) + seconds(RUSAGE_CHILDREN)
    }
}
