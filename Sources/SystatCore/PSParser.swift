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
    public static func parse(_ output: String) -> [PSEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<3 {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                let field = rest.prefix(while: { $0 != " " && $0 != "\t" })
                guard !field.isEmpty else { return nil }
                fields.append(field)
                rest = rest.dropFirst(field.count)
            }
            let command = rest.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(fields[0]), let rss = UInt64(fields[1]), let cpu = Double(fields[2]),
                  !command.isEmpty else { return nil }
            return PSEntry(pid: pid, rssBytes: rss * 1024, cpuPercent: cpu, command: command)
        }
    }
}
