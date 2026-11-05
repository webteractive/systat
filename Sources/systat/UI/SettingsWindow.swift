import AppKit
import ServiceManagement
import SwiftUI
import SystatCore

/// The Settings… window: open at login, and the limits that turn the icon red (read-only).
@MainActor final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "systat Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var status = LoginItem.status
    @State private var error: String?

    private let limits = Limits.standard

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { enabled }, set: { setLoginItem($0) }))
                if status == .requiresApproval {
                    Text("Allow systat in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(criticalRed)
                }
            }
            Section("What turns the icon red") {
                Text("Memory: pressure critical, or over \(limits.swapBytes / Units.gib) GB swap while pressure is raised")
                Text("CPU: over \(Int(limits.cpuBusy * 100))% busy for \(Int(limits.cpuHold)) seconds")
                Text("Disk: under \(limits.diskCritical / Units.gb) GB free")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        enabled = LoginItem.isEnabled
        status = LoginItem.status
    }
}
