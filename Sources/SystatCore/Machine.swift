import Foundation

/// Host CPU tick counters, summed over all cores.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    var total: UInt64 { user &+ system &+ idle &+ nice }

    /// Share of time busy (0...1) between two readings; 0 when no ticks elapsed.
    public static func busyFraction(from a: CPUTicks, to b: CPUTicks) -> Double {
        guard b.total > a.total else { return 0 }
        let total = b.total - a.total
        let idle = b.idle &- a.idle
        return max(0, min(1, 1 - Double(idle) / Double(total)))
    }
}

/// One reading of the machine-wide figures that drive the icon and the bars.
public struct MachineSample: Sendable, Equatable {
    public var time: Date
    public var pressureLevel: Int32
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var cpuBusy: Double
    public var load1: Double
    public var diskFree: UInt64
    public var diskCapacity: UInt64

    public init(time: Date, pressureLevel: Int32, swapUsed: UInt64, swapTotal: UInt64,
                memoryUsed: UInt64, memoryTotal: UInt64, cpuBusy: Double, load1: Double,
                diskFree: UInt64, diskCapacity: UInt64) {
        self.time = time
        self.pressureLevel = pressureLevel
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.cpuBusy = cpuBusy
        self.load1 = load1
        self.diskFree = diskFree
        self.diskCapacity = diskCapacity
    }
}
