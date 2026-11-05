import AppKit
import Darwin
import Foundation
import SystatCore

/// Running GUI apps by PID, read on the main actor.
@MainActor func runningApps() -> [Int32: AppInfo] {
    var apps: [Int32: AppInfo] = [:]
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy != .prohibited {
        guard let name = app.localizedName, let url = app.bundleURL else { continue }
        apps[app.processIdentifier] = AppInfo(name: name, bundlePath: url.path)
    }
    return apps
}

/// Lists every process: libproc for the user's own, `ps` for everyone else's figures.
/// Paths come from `proc_pidpath`, which works for every process; `ps` supplies numbers only.
struct ProcessReader: Sendable {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func read(apps: [Int32: AppInfo], currentUID: UInt32) -> [ProcessRecord] {
        let kernel = Sysctl.allProcesses()
        let ps = Dictionary(PSParser.parse(runPS()).map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return kernel.compactMap { k in
            // The kernel's start time for other users' processes is not wall-clock time; 0 marks it unknown.
            let identity = ProcessIdentity(pid: k.pid, startTime: k.uid == currentUID ? k.startTime : 0)
            var record = ProcessRecord(identity: identity, parentPID: k.ppid, uid: k.uid, commandName: k.comm,
                                       app: apps[k.pid])
            if k.uid == currentUID, let usage = rusage(pid: k.pid) {
                record.memoryBytes = usage.footprint
                record.cpuTimeNanos = usage.cpuNanos
                record.executablePath = executablePath(pid: k.pid)
                record.arguments = arguments(pid: k.pid)
                record.workingDirectory = workingDirectory(pid: k.pid)
            } else if let entry = ps[k.pid] {
                record.memoryBytes = entry.rssBytes
                record.psCPUPercent = entry.cpuPercent
                record.executablePath = executablePath(pid: k.pid)
                record.isApproximate = true
            } else {
                return nil
            }
            return record
        }
    }

    private func runPS() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,%cpu="]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func rusage(pid: Int32) -> (footprint: UInt64, cpuNanos: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // ri_user_time / ri_system_time are Mach absolute-time units on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return (info.ri_phys_footprint, ticks * Self.timebase.numer / Self.timebase.denom)
    }

    private func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// argv from KERN_PROCARGS2: Int32 argc, exec path, NUL padding, then argc NUL-terminated strings.
    private func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }      // exec path
        while index < size, buffer[index] == 0 { index += 1 }      // padding
        var args: [String] = []
        while args.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args
    }

    private func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
