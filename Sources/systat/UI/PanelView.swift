import AppKit
import SwiftUI
import SystatCore

let criticalRed = Color(nsColor: GaugeIcon.red)

/// The dropdown panel (spec: "The dropdown").
struct PanelView: View {
    @Bindable var monitor: Monitor
    let openSettings: () -> Void

    private static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            bars
            Picker("List", selection: $monitor.selectedList) {
                Text("Memory").tag(ListKind.memory)
                Text("CPU").tag(ListKind.cpu)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            list
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if monitor.critical.any {
                Circle().fill(criticalRed).frame(width: 8, height: 8)
            }
            Text(Format.headerStatus(criticalCount: monitor.critical.count))
                .font(.headline)
                .foregroundStyle(monitor.critical.any ? criticalRed : Color.primary)
            Spacer()
            if let last = monitor.lastUpdated {
                // Redraws only when the text can change, i.e. once readings are stale.
                TimelineView(.explicit(Format.updatedTicks(after: last))) { context in
                    Text(Format.updated(since: last, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private var bars: some View {
        if let s = monitor.machine {
            VStack(spacing: 10) {
                BarRow(label: "Memory",
                       detail: Format.memoryDetail(used: s.memoryUsed, total: s.memoryTotal, swapUsed: s.swapUsed, swapTotal: s.swapTotal),
                       fraction: s.memoryTotal > 0 ? Double(s.memoryUsed) / Double(s.memoryTotal) : 0,
                       critical: monitor.critical.memory)
                BarRow(label: "CPU", detail: Format.cpuDetail(busy: s.cpuBusy, load: s.load1),
                       fraction: s.cpuBusy, critical: monitor.critical.cpu)
                BarRow(label: "Disk", detail: Format.diskDetail(free: s.diskFree, capacity: s.diskCapacity),
                       fraction: s.diskCapacity > 0 ? 1 - Double(s.diskFree) / Double(s.diskCapacity) : 0,
                       critical: monitor.critical.disk)
            }
        }
    }

    private var list: some View {
        let kind = monitor.selectedList
        let rows = monitor.lists[kind]?.rows ?? []
        return VStack(spacing: 0) {
            if kind == .cpu && !monitor.cpuReady {
                placeholder("Measuring CPU…")
            } else if rows.isEmpty {
                placeholder("Reading processes…")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, display in
                    ProcessRowView(rank: index + 1, display: display, kind: kind, monitor: monitor)
                        .equatable()
                        .frame(height: Self.rowHeight)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: Self.rowHeight * 10, alignment: .top)
        .contentShape(Rectangle())
        .onHover { monitor.pointerOverList = $0 }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button("Open Activity Monitor") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Settings…", action: openSettings)
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(MenuItemButtonStyle())
    }
}

private struct BarRow: View {
    let label: String
    let detail: String
    let fraction: Double
    let critical: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            BarFill(fraction: fraction, critical: critical, animate: !reduceMotion)
                .frame(height: 8)
        }
    }
}

/// A plain menu-style row that highlights under the pointer.
private struct MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuItemRow(configuration: configuration)
    }
}

private struct MenuItemRow: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
