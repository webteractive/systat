import Foundation
import SystatCore

/// `systat --sample`: two readings 2 s apart, printed as text, to check figures against Activity Monitor.
enum SampleDump {
    @MainActor static func run() async -> Int32 {
        var machine = MachineReader()
        var tracker = CPUTracker()
        var evaluator = CriticalEvaluator()
        var reader = ProcessReader()
        let uid = getuid()
        _ = machine.sample(now: Date())
        _ = tracker.update(reader.read(apps: runningApps(), currentUID: uid), at: Date())
        try? await Task.sleep(for: .seconds(2))

        let now = Date()
        let s = machine.sample(now: now)
        let records = reader.read(apps: runningApps(), currentUID: uid)
        let cpu = tracker.update(records, at: now)
        let state = evaluator.update(s)
        let rows = ProcessTable.rows(from: records, cpu: cpu, currentUID: uid, selfPID: getpid(),
                                     home: NSHomeDirectory(), now: now)

        print("Memory  \(Format.memoryDetail(used: s.memoryUsed, total: s.memoryTotal, swapUsed: s.swapUsed, swapTotal: s.swapTotal))  pressure \(s.pressureLevel)")
        print("CPU     \(Format.cpuDetail(busy: s.cpuBusy, load: s.load1))")
        print("Disk    \(Format.diskDetail(free: s.diskFree, capacity: s.diskCapacity))")
        print("Status  \(Format.headerStatus(criticalCount: state.count))  (memory \(state.memory), cpu \(state.cpu), disk \(state.disk))")
        for kind in ListKind.allCases {
            print("\nTop \(kind == .memory ? "memory" : "CPU")")
            for (rank, row) in ProcessTable.top(rows, by: kind).enumerated() {
                let value = Format.listValue(for: row, kind: kind)
                let actions = row.protection.label ?? "Quit / Force Quit"
                print(String(format: "%2d  %@  —  %@  %@  [%@]", rank + 1, PSParser.sanitized(row.name),
                             PSParser.sanitized(row.detail), value, actions))
            }
        }
        return 0
    }
}
