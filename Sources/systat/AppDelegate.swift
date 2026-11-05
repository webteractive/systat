import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var status: StatusController?
    private let settings = SettingsWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.registerOnFirstLaunch()
        let monitor = Monitor()
        self.monitor = monitor
        status = StatusController(monitor: monitor, openSettings: { [settings] in settings.show() })
        monitor.start()
    }
}
