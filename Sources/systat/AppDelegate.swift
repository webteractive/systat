import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = Monitor()
        self.monitor = monitor
        status = StatusController(monitor: monitor, openSettings: {})
        monitor.start()
    }
}
