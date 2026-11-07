import AppKit
import ServiceManagement
import SwiftUI
import SystatCore

/// The Settings… window: open at login, updates, and the limits that turn the icon red (read-only).
@MainActor final class SettingsWindow {
    private let updater: Updater
    private var window: NSWindow?

    init(updater: Updater) { self.updater = updater }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(updater: updater)))
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
    @Bindable var updater: Updater
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
            Section("Updates") {
                Toggle("Check for updates daily", isOn: $updater.checksAutomatically)
                HStack {
                    Text(updateStatus).foregroundStyle(updateFailed ? criticalRed : Color.secondary)
                    Spacer()
                    if case .available(let update) = updater.state {
                        Button(update.isInstallable ? "Update" : "Download", action: updater.install)
                    } else {
                        Button("Check Now") { Task { await updater.check() } }
                            .disabled(updater.state == .checking)
                    }
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

    private var updateStatus: String {
        switch updater.state {
        case .idle: "This is systat \(updater.currentVersion)."
        case .checking: "Checking…"
        case .upToDate: "systat \(updater.currentVersion) is up to date."
        case .checkFailed(let message): message
        case .available(let u): "systat \(u.version) is available."
        case .installing(let u): "Updating to systat \(u.version)…"
        case .installFailed(_, let message): "Update failed: \(message)"
        }
    }

    private var updateFailed: Bool {
        switch updater.state {
        case .checkFailed, .installFailed: true
        default: false
        }
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
