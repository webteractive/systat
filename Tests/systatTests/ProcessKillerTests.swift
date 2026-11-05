import Darwin
import Foundation
import SystatCore
import Testing
@testable import systat

/// Starts `bash` with argv[0] "claude" and two sleeping helpers under it, outside any real session.
private func startFakeClaudeTree() throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "exec -a claude /bin/bash -c 'sleep 701 & sleep 702 & wait'"]
    // Survivors must not hold the test runner's output open.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process.processIdentifier
}

private func children(of pid: Int32) -> [KinfoEntry] {
    Sysctl.allProcesses().filter { $0.ppid == pid }
}

private func waitUntil(_ condition: () -> Bool) -> Bool {
    for _ in 0..<50 {
        if condition() { return true }
        usleep(100_000)
    }
    return false
}

private func row(for pid: Int32, claude: Bool) throws -> ProcessRow {
    let start = try #require(Sysctl.startTime(pid: pid))
    return ProcessRow(id: ProcessIdentity(pid: pid, startTime: start), name: "claude", detail: "",
                      memoryBytes: 0, cpuPercent: nil, isApproximate: false, protection: .killable,
                      isApp: false, isClaudeSession: claude)
}

@MainActor @Test func forceQuitTakesTheClaudeSessionAndItsHelpers() throws {
    let leader = try startFakeClaudeTree()
    #expect(waitUntil { children(of: leader).count == 2 })
    let helpers = children(of: leader).map(\.pid)

    let outcome = ProcessKiller.perform(.forceQuit, on: try row(for: leader, claude: true), currentUID: getuid())

    #expect(outcome == .sent)
    #expect(waitUntil { helpers.allSatisfy { Sysctl.startTime(pid: $0) == nil } })
}

@MainActor @Test func reusedPIDIsNotSignalled() throws {
    let leader = try startFakeClaudeTree()
    #expect(waitUntil { children(of: leader).count == 2 })
    defer { _ = ProcessKiller.perform(.forceQuit, on: try! row(for: leader, claude: true), currentUID: getuid()) }
    var stale = try row(for: leader, claude: true)
    stale.id = ProcessIdentity(pid: leader, startTime: stale.id.startTime + 1)

    #expect(ProcessKiller.perform(.forceQuit, on: stale, currentUID: getuid()) == .gone)
    #expect(Sysctl.startTime(pid: leader) != nil)
}

@MainActor @Test func otherProcessesAreSignalledAlone() throws {
    let leader = try startFakeClaudeTree()
    #expect(waitUntil { children(of: leader).count == 2 })
    let helpers = children(of: leader).map(\.pid)
    defer { helpers.forEach { kill($0, SIGKILL) } }

    #expect(ProcessKiller.perform(.forceQuit, on: try row(for: leader, claude: false), currentUID: getuid()) == .sent)
    usleep(300_000)
    #expect(helpers.allSatisfy { Sysctl.startTime(pid: $0) != nil })
}
