import Foundation
import Testing
@testable import SystatCore

@Test func claudeSessionFoldsUserOwnedHelpers() throws {
    let recs = [
        record(pid: 100, comm: "claude", args: ["claude", "-n", "proj"], memory: 400_000_000),
        record(pid: 101, ppid: 100, comm: "node", memory: 200_000_000),
        record(pid: 102, ppid: 101, comm: "mcp-server", memory: 100_000_000),
        record(pid: 103, ppid: 100, uid: 0, comm: "rootthing", memory: 50_000_000),
    ]
    let rows = ProcessTable.rows(from: recs, cpu: [:], currentUID: 501, selfPID: 999, home: "/Users/me", now: now)
    let claude = try #require(rows.first { $0.isClaudeSession })
    #expect(claude.memoryBytes == 700_000_000)
    #expect(claude.detail == "proj")
    #expect(!rows.contains { $0.name == "node" || $0.name == "mcp-server" })
    #expect(rows.contains { $0.name == "rootthing" })
    #expect(ProcessTable.sessionMembers(leader: recs[0].identity, in: recs, ownerUID: 501).map(\.pid) == [100, 101, 102])
}

@Test func nestedClaudeFoldsIntoOutermost() {
    let recs = [
        record(pid: 100, comm: "claude", args: ["claude"], cwd: "/x/outer", memory: 400_000_000),
        record(pid: 110, ppid: 100, comm: "zsh", memory: 10_000_000),
        record(pid: 120, ppid: 110, comm: "claude", args: ["claude", "-p", "hi"], memory: 300_000_000),
    ]
    let rows = ProcessTable.rows(from: recs, cpu: [:], currentUID: 501, selfPID: 999, home: "/Users/me", now: now)
    #expect(rows.filter(\.isClaudeSession).count == 1)
    #expect(rows.first { $0.isClaudeSession }?.memoryBytes == 710_000_000)
}

@Test func selfIsExcludedAndTopSorts() {
    let recs = (1...15).map { record(pid: Int32($0), comm: "p\($0)", memory: UInt64($0) * 1_000_000) }
    let cpu = Dictionary(uniqueKeysWithValues: recs.map { ($0.identity, Double(16 - $0.identity.pid)) })
    let rows = ProcessTable.rows(from: recs, cpu: cpu, currentUID: 501, selfPID: 15, home: "/Users/me", now: now)
    #expect(!rows.contains { $0.id.pid == 15 })
    #expect(ProcessTable.top(rows, by: .memory).map(\.id.pid) == Array((5...14).reversed()))
    #expect(ProcessTable.top(rows, by: .cpu).first?.id.pid == 1)
}

@Test func sameNameRowsGetPaths() {
    let a = record(pid: 1, comm: "systat", path: "/tmp/b/systat.app/Contents/MacOS/systat",
                   app: AppInfo(name: "systat", bundlePath: "/tmp/b/systat.app"))
    let b = record(pid: 2, comm: "systat", path: "/Applications/systat.app/Contents/MacOS/systat",
                   app: AppInfo(name: "systat", bundlePath: "/Applications/systat.app"))
    let rows = ProcessTable.rows(from: [a, b], cpu: [:], currentUID: 501, selfPID: 999, home: "/Users/me", now: now)
    #expect(Set(rows.map(\.detail)) == ["/tmp/b", "/Applications"])
}
