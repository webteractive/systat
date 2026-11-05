import SwiftUI
import SystatCore

/// One row of the top-10 list.
struct ProcessRowView: View {
    let rank: Int
    let display: DisplayRow
    let kind: ListKind
    let onQuit: () -> Void
    let onForceQuit: () -> Void

    private var row: ProcessRow { display.row }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Text(secondLine)
                    .font(.caption)
                    .foregroundStyle(isFailed ? criticalRed : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
            actions.frame(width: 136, alignment: .trailing)
        }
        .opacity(display.state == .ended ? 0.45 : 1)
    }

    private var isFailed: Bool {
        if case .failed = display.state { true } else { false }
    }

    private var secondLine: String {
        switch display.state {
        case .normal: row.detail
        case .quitting: "Quitting…"
        case .ended: "Ended"
        case .failed(let reason): reason
        }
    }

    private var value: String {
        switch kind {
        case .memory: Format.memory(row.memoryBytes, approximate: row.isApproximate)
        case .cpu: row.cpuPercent.map { Format.cpu($0, approximate: row.isApproximate) } ?? "—"
        }
    }

    @ViewBuilder private var actions: some View {
        if display.state == .ended {
            Color.clear
        } else if let label = row.protection.label {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Button("Quit", action: onQuit)
                Button("Force Quit", action: onForceQuit).tint(criticalRed).foregroundStyle(criticalRed)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }
}
