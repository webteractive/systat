import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var status: StatusController?
    private let updater = Updater(currentVersion: systatVersion)
    private lazy var settings = SettingsWindow(updater: updater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.registerOnFirstLaunch()
        let monitor = Monitor()
        self.monitor = monitor
        status = StatusController(monitor: monitor, updater: updater, openSettings: { [settings] in settings.show() })
        monitor.start()
        updater.start()
    }
}
