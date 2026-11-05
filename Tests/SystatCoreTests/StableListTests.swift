import Foundation
import Testing
@testable import SystatCore

private func row(_ pid: Int32, mem: UInt64, start: UInt64 = 0) -> ProcessRow {
    ProcessRow(id: ProcessIdentity(pid: pid, startTime: start), name: "p\(pid)", detail: "", memoryBytes: mem,
               cpuPercent: nil, isApproximate: false, protection: .killable, isApp: false, isClaudeSession: false)
}

private func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func unfrozenReorders() {
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 10), row(2, mem: 20)], frozen: false, now: t(0))
    #expect(l.rows.map(\.id.pid) == [2, 1])
    l.update(with: [row(1, mem: 30), row(2, mem: 20)], frozen: false, now: t(2))
    #expect(l.rows.map(\.id.pid) == [1, 2])
}

@Test func frozenKeepsOrderAndUpdatesValues() {
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 10), row(2, mem: 20)], frozen: false, now: t(0))
    l.update(with: [row(1, mem: 30), row(2, mem: 20), row(3, mem: 99)], frozen: true, now: t(2))
    #expect(l.rows.map(\.id.pid) == [2, 1])
    #expect(l.rows[1].row.memoryBytes == 30)
}

@Test func endedRowStaysWhileFrozenThenGoes() {
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 30), row(2, mem: 20), row(3, mem: 10)], frozen: false, now: t(0))
    l.update(with: [row(1, mem: 30), row(3, mem: 10)], frozen: true, now: t(2))
    #expect(l.rows.map(\.id.pid) == [1, 2, 3])
    #expect(l.rows[1].state == .ended)
    l.update(with: [row(1, mem: 30), row(3, mem: 10)], frozen: false, now: t(4))
    #expect(l.rows.map(\.id.pid) == [1, 3])
}

@Test func reusedPIDIsEndedNotAdopted() {
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 30, start: 100)], frozen: false, now: t(0))
    l.update(with: [row(1, mem: 90, start: 200)], frozen: true, now: t(2))
    #expect(l.rows.count == 1)
    #expect(l.rows[0].row.id.startTime == 100)
    #expect(l.rows[0].state == .ended)
}

@Test func quittingRevertsAfterTimeout() {
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 30)], frozen: false, now: t(0))
    l.markQuitting(l.rows[0].id, at: t(0))
    l.update(with: [row(1, mem: 30)], frozen: true, now: t(4))
    #expect(l.rows[0].state == .quitting(since: t(0)))
    l.update(with: [row(1, mem: 30)], frozen: true, now: t(5))
    #expect(l.rows[0].state == .normal)
}

@Test func failedClearsWhenUnfrozen() {
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 30)], frozen: false, now: t(0))
    l.markFailed(l.rows[0].id, reason: "Not permitted")
    l.update(with: [row(1, mem: 30)], frozen: true, now: t(2))
    #expect(l.rows[0].state == .failed("Not permitted"))
    l.update(with: [row(1, mem: 30)], frozen: false, now: t(4))
    #expect(l.rows[0].state == .normal)
}

@Test func frozenUpdateFillsAnEmptyList() {
    // The pointer can reach the list before the first rows arrive; nothing is under it to protect.
    var l = StableList(kind: .memory)
    l.update(with: [row(1, mem: 10), row(2, mem: 20)], frozen: true, now: t(0))
    #expect(l.rows.map(\.id.pid) == [2, 1])
}
