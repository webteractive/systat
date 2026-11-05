import Foundation

/// Byte units. Memory and swap use `gib` (as Activity Monitor); disk uses `gb` (as Finder).
public enum Units {
    public static let mib: UInt64 = 1 << 20
    public static let gib: UInt64 = 1 << 30
    public static let gb: UInt64 = 1_000_000_000
}

/// Every user-visible number and status string.
public enum Format {
    public static func memory(_ bytes: UInt64, approximate: Bool = false) -> String {
        let text: String
        if bytes < Units.mib {
            text = "<1 MB"
        } else if bytes < Units.gib {
            text = "\(roundHalfUp(Double(bytes) / Double(Units.mib))) MB"
        } else {
            text = "\(oneDecimal(Double(bytes) / Double(Units.gib), trimZero: false)) GB"
        }
        return approximate ? "≈ " + text : text
    }

    public static func cpu(_ percent: Double, approximate: Bool = false) -> String {
        let text = "\(roundHalfUp(percent))%"
        return approximate ? "≈ " + text : text
    }

    /// The age suffix for a process running more than a day, e.g. `13 days`.
    public static func age(since start: Date, now: Date) -> String? {
        let seconds = now.timeIntervalSince(start)
        guard seconds > 86_400 else { return nil }
        let days = Int(seconds / 86_400)
        return days == 1 ? "1 day" : "\(days) days"
    }

    public static func memoryDetail(used: UInt64, total: UInt64, swapUsed: UInt64, swapTotal: UInt64) -> String {
        let memory = "\(gib(used)) of \(gib(total)) GB"
        guard swapUsed > 0 || swapTotal > 0 else { return memory }
        return memory + " · swap \(gib(swapUsed)) of \(gib(swapTotal)) GB"
    }

    public static func cpuDetail(busy: Double, load: Double) -> String {
        "\(roundHalfUp(busy * 100))% busy · load \(oneDecimal(load, trimZero: false))"
    }

    public static func diskDetail(free: UInt64, capacity: UInt64) -> String {
        let freeGB = Double(free) / Double(Units.gb)
        let freeText = freeGB < 10 ? oneDecimal(freeGB, trimZero: true) : "\(roundHalfUp(freeGB))"
        return "\(freeText) GB free of \(roundHalfUp(Double(capacity) / Double(Units.gb))) GB"
    }

    public static func headerStatus(criticalCount: Int) -> String {
        switch criticalCount {
        case 0: "All normal"
        case 1: "1 resource critical"
        default: "\(criticalCount) resources critical"
        }
    }

    public static func updated(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return seconds < 60 ? "Updated \(seconds)s ago" : "Updated \(seconds / 60)m ago"
    }

    private static func gib(_ bytes: UInt64) -> String {
        oneDecimal(Double(bytes) / Double(Units.gib), trimZero: true)
    }

    private static func roundHalfUp(_ value: Double) -> Int {
        Int((value + 0.5).rounded(.down))
    }

    private static func oneDecimal(_ value: Double, trimZero: Bool) -> String {
        let tenths = roundHalfUp(value * 10)
        if trimZero && tenths % 10 == 0 { return "\(tenths / 10)" }
        return "\(tenths / 10).\(tenths % 10)"
    }
}
