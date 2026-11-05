import Darwin
import Foundation

/// The fields systat needs from the kernel's process table.
struct KinfoEntry: Sendable {
    var pid: Int32
    var ppid: Int32
    var uid: UInt32
    /// Microseconds since 1970.
    var startTime: UInt64
    var comm: String
}

enum Sysctl {
    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func allProcesses() -> [KinfoEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            let count = size / stride + 16
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
            var actual = count * stride
            let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &actual, nil, 0) }
            if result == 0 { return buffer.prefix(actual / stride).map(entry) }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    /// The process's start time, or nil when that PID no longer exists.
    static func startTime(pid: Int32) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return entry(info).startTime
    }

    private static func entry(_ k: kinfo_proc) -> KinfoEntry {
        let comm = withUnsafeBytes(of: k.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = k.kp_proc.p_un.__p_starttime
        return KinfoEntry(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid,
                          startTime: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec), comm: comm)
    }
}
