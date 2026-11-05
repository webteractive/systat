import Foundation

/// One line of `ps -axo pid=,rss=,%cpu=,comm=`.
public struct PSEntry: Sendable, Equatable {
    public var pid: Int32
    public var rssBytes: UInt64
    public var cpuPercent: Double
    public var command: String

    public init(pid: Int32, rssBytes: UInt64, cpuPercent: Double, command: String) {
        self.pid = pid
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
        self.command = command
    }
}

public enum PSParser {
    /// Parses `pid rss(KiB) %cpu command…`; the command is the rest of the line. Bad lines are skipped.
    /// A command name can contain a newline and so forge a line for another PID; any PID that
    /// appears more than once is dropped rather than trusted.
    public static func parse(_ output: String) -> [PSEntry] {
        let entries = output.split(whereSeparator: \.isNewline).compactMap(parseLine)
        let counts = Dictionary(entries.map { ($0.pid, 1) }, uniquingKeysWith: +)
        return entries.filter { counts[$0.pid] == 1 }
    }

    /// Replaces control characters (C0, DEL, C1) with `?` before process text reaches a terminal.
    public static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? "?" : scalar
        }))
    }

    private static func parseLine(_ line: Substring) -> PSEntry? {
        var rest = line
        var fields: [Substring] = []
        for _ in 0..<3 {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            let field = rest.prefix(while: { $0 != " " && $0 != "\t" })
            guard !field.isEmpty else { return nil }
            fields.append(field)
            rest = rest.dropFirst(field.count)
        }
        let command = rest.trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(fields[0]), let rssKiB = UInt64(fields[1]), let cpu = Double(fields[2]),
              !command.isEmpty else { return nil }
        let (rss, overflow) = rssKiB.multipliedReportingOverflow(by: 1024)
        guard !overflow else { return nil }
        return PSEntry(pid: pid, rssBytes: rss, cpuPercent: cpu, command: command)
    }
}
