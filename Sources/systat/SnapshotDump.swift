import AppKit
import SwiftUI

/// `systat --snapshot <dir>`: renders the live panel (with both icons) and Settings offscreen to
/// `panel-light.png`, `panel-dark.png` and `settings-light.png`, for checking the UI without clicking the menu bar.
enum SnapshotDump {
    @MainActor static func run(directory: String) async -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let monitor = Monitor()
        monitor.menuWillOpen()
        try? await Task.sleep(for: .seconds(4.5))   // three refreshes, so the CPU list is ready
        let pages: [(String, NSAppearance.Name, AnyView)] = [
            ("panel-light", .aqua, AnyView(SnapshotView(monitor: monitor))),
            ("panel-dark", .darkAqua, AnyView(SnapshotView(monitor: monitor))),
            ("settings-light", .aqua, AnyView(SettingsView().background(Color(nsColor: .windowBackgroundColor)))),
        ]
        for (name, appearance, page) in pages {
            let view = NSHostingView(rootView: page)
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            do { try rep.representation(using: .png, properties: [:])?.write(to: url) } catch {
                FileHandle.standardError.write(Data("systat: \(error.localizedDescription)\n".utf8))
                return 1
            }
            print(url.path)
        }
        return 0
    }
}

private struct SnapshotView: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                icon(critical: false)
                icon(critical: true)
            }
            .padding(14)
            PanelView(monitor: monitor, openSettings: {})
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func icon(critical: Bool) -> some View {
        Image(nsImage: GaugeIcon.image(critical: critical))
            .resizable()
            .interpolation(.none)
            .frame(width: 72, height: 72)
            .border(Color.secondary.opacity(0.3))
    }
}
