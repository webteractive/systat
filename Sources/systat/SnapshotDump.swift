import AppKit
import SwiftUI

/// `systat --snapshot <dir>`: renders the live panel and both icons offscreen to
/// `panel-light.png` and `panel-dark.png`, for checking the UI without clicking the menu bar.
enum SnapshotDump {
    @MainActor static func run(directory: String) async -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let monitor = Monitor()
        monitor.menuWillOpen()
        try? await Task.sleep(for: .seconds(4.5))   // three refreshes, so the CPU list is ready
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: SnapshotView(monitor: monitor))
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.setContentSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("panel-\(name).png")
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
