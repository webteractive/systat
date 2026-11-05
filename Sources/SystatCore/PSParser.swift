import Foundation

/// One line of `ps -axo pid=,rss=,%cpu=`. Numbers only: `ps` is never asked for names,
/// since a command name can contain a newline and forge a line for another process.
public struct PSEntry: Sendable, Equatable {
    public var pid: Int32
    public var rssBytes: UInt64
    public var cpuPercent: Double

    public init(pid: Int32, rssBytes: UInt64, cpuPercent: Double) {
        self.pid = pid
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
    }
}

public enum PSParser {
    /// Parses `pid rss(KiB) %cpu` lines. Lines that are not exactly three numbers are skipped,
    /// as are sizes that would overflow; the first line for a PID wins.
    public static func parse(_ output: String) -> [PSEntry] {
        var seen: Set<Int32> = []
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let rssKiB = UInt64(fields[1]),
                  let cpu = Double(fields[2]) else { return nil }
            let (rss, overflow) = rssKiB.multipliedReportingOverflow(by: 1024)
            guard !overflow, seen.insert(pid).inserted else { return nil }
            return PSEntry(pid: pid, rssBytes: rss, cpuPercent: cpu)
        }
    }

    /// Replaces control characters (C0, DEL, C1) with `?` before process text reaches a terminal.
    public static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? "?" : scalar
        }))
    }
}
