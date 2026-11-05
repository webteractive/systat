import Foundation
import ServiceManagement

/// Open at login, through SMAppService.mainApp.
@MainActor enum LoginItem {
    private static let registeredKey = "loginItemRegistered"

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Turns open-at-login on the first time the installed app runs; afterwards the Settings switch decides.
    static func registerOnFirstLaunch() {
        guard Bundle.main.bundleIdentifier != nil, !UserDefaults.standard.bool(forKey: registeredKey) else { return }
        do {
            try setEnabled(true)
            UserDefaults.standard.set(true, forKey: registeredKey)
        } catch {
            NSLog("systat: could not register as a login item: %@", error.localizedDescription)
        }
    }
}
