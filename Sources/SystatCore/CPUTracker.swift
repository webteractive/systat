import Foundation

/// Per-process CPU % between two refreshes, as Activity Monitor shows it (share of one core).
public struct CPUTracker: Sendable {
    public private(set) var isReady = false
    private var previous: [ProcessIdentity: UInt64] = [:]
    private var previousTime: Date?

    public init() {}

    public mutating func update(_ records: [ProcessRecord], at time: Date) -> [ProcessIdentity: Double] {
        var result: [ProcessIdentity: Double] = [:]
        var current: [ProcessIdentity: UInt64] = [:]
        let wallNanos = previousTime.map { time.timeIntervalSince($0) * 1_000_000_000 } ?? 0
        for r in records {
            if let nanos = r.cpuTimeNanos {
                current[r.identity] = nanos
                if wallNanos > 0, let before = previous[r.identity], nanos >= before {
                    result[r.identity] = Double(nanos - before) / wallNanos * 100
                }
            } else if let percent = r.psCPUPercent {
                result[r.identity] = percent
            }
        }
        isReady = previousTime != nil
        previous = current
        previousTime = time
        return result
    }

    public mutating func reset() {
        self = CPUTracker()
    }
}
