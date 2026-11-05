import Foundation
import Testing
@testable import SystatCore

@Test func cpuNeedsTwoSamples() {
    var t = CPUTracker()
    let a = record(pid: 1, comm: "a", cpuNanos: 1_000_000_000)
    let b = record(pid: 2, uid: 0, comm: "b", psCPU: 12)
    let first = t.update([a, b], at: now)
    #expect(!t.isReady)
    #expect(first[a.identity] == nil)
    var a2 = a
    a2.cpuTimeNanos = 2_000_000_000
    let second = t.update([a2, b], at: now.addingTimeInterval(2))
    #expect(t.isReady)
    #expect(second[a.identity] == 50)
    #expect(second[b.identity] == 12)
}
