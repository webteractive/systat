import Foundation

/// The fixed critical limits (spec: "Critical limits").
public struct Limits: Sendable {
    public var swapBytes: UInt64 = 4 * Units.gib
    public var cpuBusy: Double = 0.85
    public var cpuHold: TimeInterval = 30
    public var diskCritical: UInt64 = 15 * Units.gb
    public var diskClear: UInt64 = 16 * Units.gb
    public var maxSampleGap: TimeInterval = 15

    public static let pressureWarning: Int32 = 2
    public static let pressureCritical: Int32 = 4
    public static let standard = Limits()

    public init() {}
}

public struct CriticalState: Sendable, Equatable {
    public var memory = false
    public var cpu = false
    public var disk = false

    public init(memory: Bool = false, cpu: Bool = false, disk: Bool = false) {
        self.memory = memory
        self.cpu = cpu
        self.disk = disk
    }

    public var count: Int { [memory, cpu, disk].filter { $0 }.count }
    public var any: Bool { count > 0 }
}

/// Turns samples into critical flags, holding CPU for 30 s each way.
public struct CriticalEvaluator: Sendable {
    public let limits: Limits
    public private(set) var state = CriticalState()
    private var lastTime: Date?
    private var aboveSince: Date?
    private var belowSince: Date?

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public mutating func update(_ sample: MachineSample) -> CriticalState {
        state.memory = sample.pressureLevel >= Limits.pressureCritical
            || (sample.swapUsed > limits.swapBytes && sample.pressureLevel >= Limits.pressureWarning)
        // Capacity 0 means there is no disk reading yet; that is not a full disk.
        state.disk = sample.diskCapacity > 0
            && sample.diskFree < (state.disk ? limits.diskClear : limits.diskCritical)
        updateCPU(sample)
        return state
    }

    private mutating func updateCPU(_ sample: MachineSample) {
        let now = sample.time
        if let last = lastTime, now.timeIntervalSince(last) > limits.maxSampleGap {
            state.cpu = false
            aboveSince = nil
            belowSince = nil
        }
        lastTime = now
        if sample.cpuBusy > limits.cpuBusy {
            belowSince = nil
            let since = aboveSince ?? now
            aboveSince = since
            if !state.cpu && now.timeIntervalSince(since) >= limits.cpuHold { state.cpu = true }
        } else {
            aboveSince = nil
            let since = belowSince ?? now
            belowSince = since
            if state.cpu && now.timeIntervalSince(since) >= limits.cpuHold { state.cpu = false }
        }
    }
}

public enum ListKind: Sendable, Hashable, CaseIterable {
    case memory, cpu
}

/// The list the switch opens on: CPU when only CPU (of the two) is critical.
public func initialList(for state: CriticalState) -> ListKind {
    state.cpu && !state.memory ? .cpu : .memory
}
