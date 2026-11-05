import Foundation
@testable import SystatCore

let now = Date(timeIntervalSince1970: 1_000_000_000)

func record(pid: Int32, ppid: Int32 = 1, uid: UInt32 = 501, comm: String, path: String? = nil,
            args: [String]? = nil, cwd: String? = nil, app: AppInfo? = nil, memory: UInt64 = 0,
            cpuNanos: UInt64? = nil, psCPU: Double? = nil, ageDays: Double = 0) -> ProcessRecord {
    let start = UInt64((now.timeIntervalSince1970 - ageDays * 86_400) * 1_000_000)
    return ProcessRecord(identity: ProcessIdentity(pid: pid, startTime: start), parentPID: ppid, uid: uid,
                         commandName: comm, executablePath: path, arguments: args, workingDirectory: cwd,
                         app: app, memoryBytes: memory, cpuTimeNanos: cpuNanos, psCPUPercent: psCPU,
                         isApproximate: psCPU != nil)
}
