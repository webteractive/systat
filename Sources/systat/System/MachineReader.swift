import Darwin
import Foundation
import SystatCore

/// Reads the machine-wide figures: memory pressure, swap, memory used, CPU busy, load and disk.
struct MachineReader: Sendable {
    private let host = mach_host_self()
    private let pageSize = UInt64(getpagesize())
    private var previousTicks: CPUTicks?

    init() {}

    mutating func sample(now: Date) -> MachineSample {
        let swap = Sysctl.swapUsage() ?? (0, 0)
        let ticks = cpuTicks()
        let busy = ticks.map { CPUTicks.busyFraction(from: previousTicks ?? CPUTicks(user: 0, system: 0, idle: 0, nice: 0), to: $0) } ?? 0
        if let ticks { previousTicks = ticks }
        var load = [0.0]
        _ = getloadavg(&load, 1)
        let disk = diskSpace()
        return MachineSample(time: now,
                             pressureLevel: Sysctl.int32("kern.memorystatus_vm_pressure_level") ?? 1,
                             swapUsed: swap.used, swapTotal: swap.total,
                             memoryUsed: memoryUsed(), memoryTotal: Sysctl.uint64("hw.memsize") ?? 0,
                             cpuBusy: busy, load1: load[0],
                             diskFree: disk.free, diskCapacity: disk.capacity)
    }

    /// Activity Monitor's Memory Used: app memory + wired + compressed.
    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    private func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    private func diskSpace() -> (free: UInt64, capacity: UInt64) {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0)),
                UInt64(max(0, values?.volumeTotalCapacity ?? 0)))
    }
}
