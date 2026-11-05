import Foundation
import Testing
@testable import SystatCore

private func sample(t: Double, busy: Double = 0.1, pressure: Int32 = 1, swap: UInt64 = 0,
                    diskFree: UInt64 = 100 * Units.gb) -> MachineSample {
    MachineSample(time: Date(timeIntervalSince1970: t), pressureLevel: pressure,
                  swapUsed: swap, swapTotal: 8 * Units.gib,
                  memoryUsed: 8 * Units.gib, memoryTotal: 16 * Units.gib,
                  cpuBusy: busy, load1: 2, diskFree: diskFree, diskCapacity: 500 * Units.gb)
}

@Test func busyFractionFromTicks() {
    let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
    let b = CPUTicks(user: 160, system: 80, idle: 860, nice: 0)
    #expect(abs(CPUTicks.busyFraction(from: a, to: b) - 0.9) < 1e-9)
    #expect(CPUTicks.busyFraction(from: a, to: a) == 0)
}

@Test func memoryRule() {
    var e = CriticalEvaluator()
    #expect(e.update(sample(t: 0, pressure: 4)).memory)
    #expect(!e.update(sample(t: 2, pressure: 1, swap: 5 * Units.gib)).memory)   // stale swap alone
    #expect(e.update(sample(t: 4, pressure: 2, swap: 5 * Units.gib)).memory)
    #expect(!e.update(sample(t: 6, pressure: 2, swap: 4 * Units.gib)).memory)   // not more than 4 GB
}

@Test func diskRuleWithGap() {
    var e = CriticalEvaluator()
    #expect(!e.update(sample(t: 0, diskFree: 15 * Units.gb)).disk)
    #expect(e.update(sample(t: 2, diskFree: 14_900_000_000)).disk)
    #expect(e.update(sample(t: 4, diskFree: 15_500_000_000)).disk)   // still under 16
    #expect(!e.update(sample(t: 6, diskFree: 16 * Units.gb)).disk)
}

@Test func cpuHoldTurnsOnAfter30sAndClearsAfter30s() {
    var e = CriticalEvaluator()
    for t in stride(from: 0.0, through: 28, by: 2) { #expect(!e.update(sample(t: t, busy: 0.9)).cpu) }
    #expect(e.update(sample(t: 30, busy: 0.9)).cpu)
    for t in stride(from: 32.0, through: 60, by: 2) { #expect(e.update(sample(t: t, busy: 0.5)).cpu) }
    #expect(!e.update(sample(t: 62, busy: 0.5)).cpu)
}

@Test func cpuSpikeInterruptionRestartsHold() {
    var e = CriticalEvaluator()
    for t in stride(from: 0.0, through: 20, by: 2) { _ = e.update(sample(t: t, busy: 0.9)) }
    _ = e.update(sample(t: 22, busy: 0.85))                         // at the line is not over it
    for t in stride(from: 24.0, through: 52, by: 2) { #expect(!e.update(sample(t: t, busy: 0.9)).cpu) }
    #expect(e.update(sample(t: 54, busy: 0.9)).cpu)
}

@Test func cpuHoldResetsAfterSampleGap() {
    var e = CriticalEvaluator()
    for t in stride(from: 0.0, through: 40, by: 2) { _ = e.update(sample(t: t, busy: 0.9)) }
    #expect(e.state.cpu)
    for t in stride(from: 640.0, through: 668, by: 2) {             // slept 10 minutes
        #expect(!e.update(sample(t: t, busy: 0.9)).cpu)
    }
    #expect(e.update(sample(t: 670, busy: 0.9)).cpu)
}

@Test func initialListFollowsCritical() {
    #expect(initialList(for: CriticalState(memory: false, cpu: true, disk: false)) == .cpu)
    #expect(initialList(for: CriticalState(memory: true, cpu: true, disk: false)) == .memory)
    #expect(initialList(for: CriticalState()) == .memory)
}
