import AppKit
import Darwin
import SystatCore

enum KillAction: Sendable {
    case quit, forceQuit
}

/// Sends Quit or Force Quit to the exact process in a row, after checking it is still the same process.
@MainActor enum ProcessKiller {
    static func perform(_ action: KillAction, on row: ProcessRow, currentUID: UInt32) -> KillOutcome {
        guard isAlive(row.id) else { return .gone }
        var targets = [row.id]
        if row.isClaudeSession {
            // Collect the session's helpers at the moment of the click.
            let records = Sysctl.allProcesses().filter { $0.uid == currentUID }.map {
                ProcessRecord(identity: ProcessIdentity(pid: $0.pid, startTime: $0.startTime),
                              parentPID: $0.ppid, uid: $0.uid, commandName: $0.comm)
            }
            targets = ProcessTable.sessionMembers(leader: row.id, in: records, ownerUID: currentUID)
        }
        var leaderOutcome = KillOutcome.gone
        for target in targets {
            let outcome = signal(target, action: action, asApp: target == row.id && row.isApp)
            if target == row.id { leaderOutcome = outcome }
        }
        return leaderOutcome
    }

    private static func isAlive(_ id: ProcessIdentity) -> Bool {
        Sysctl.startTime(pid: id.pid) == id.startTime
    }

    private static func signal(_ id: ProcessIdentity, action: KillAction, asApp: Bool) -> KillOutcome {
        guard isAlive(id) else { return .gone }
        if asApp, let app = NSRunningApplication(processIdentifier: id.pid) {
            let asked = action == .quit ? app.terminate() : app.forceTerminate()
            return asked ? .sent : .failed("Did not respond")
        }
        return kill(id.pid, action == .quit ? SIGTERM : SIGKILL) == 0 ? .sent : KillOutcome(errno: errno)
    }
}
