import Foundation
import Testing
@testable import SystatCore

private let gib = Double(Units.gib)

@Test func memoryValues() {
    #expect(Format.memory(UInt64(833 * 1_048_576)) == "833 MB")
    #expect(Format.memory(UInt64(1.2 * gib)) == "1.2 GB")
    #expect(Format.memory(UInt64(1.2 * gib), approximate: true) == "≈ 1.2 GB")
    #expect(Format.memory(500_000) == "<1 MB")
}

@Test func cpuValues() {
    #expect(Format.cpu(68.4) == "68%")
    #expect(Format.cpu(142) == "142%")
    #expect(Format.cpu(40, approximate: true) == "≈ 40%")
}

@Test func ages() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    #expect(Format.age(since: now.addingTimeInterval(-3_600), now: now) == nil)
    #expect(Format.age(since: now.addingTimeInterval(-86_400), now: now) == nil)
    #expect(Format.age(since: now.addingTimeInterval(-1.5 * 86_400), now: now) == "1 day")
    #expect(Format.age(since: now.addingTimeInterval(-13.2 * 86_400), now: now) == "13 days")
}

@Test func barDetails() {
    #expect(Format.memoryDetail(used: UInt64(7.9 * gib), total: 8 * Units.gib,
                                swapUsed: UInt64(4.9 * gib), swapTotal: 6 * Units.gib)
            == "7.9 of 8 GB · swap 4.9 of 6 GB")
    #expect(Format.memoryDetail(used: UInt64(7.9 * gib), total: 16 * Units.gib, swapUsed: 0, swapTotal: 0)
            == "7.9 of 16 GB")
    #expect(Format.cpuDetail(busy: 0.9, load: 17.3) == "90% busy · load 17.3")
    #expect(Format.diskDetail(free: 11 * Units.gb, capacity: 228 * Units.gb) == "11 GB free of 228 GB")
    #expect(Format.diskDetail(free: 9_400_000_000, capacity: 228 * Units.gb) == "9.4 GB free of 228 GB")
}

@Test func headerStrings() {
    #expect(Format.headerStatus(criticalCount: 0) == "All normal")
    #expect(Format.headerStatus(criticalCount: 1) == "1 resource critical")
    #expect(Format.headerStatus(criticalCount: 3) == "3 resources critical")
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(Format.updated(since: now.addingTimeInterval(-2), now: now) == "Updated 2s ago")
    #expect(Format.updated(since: now.addingTimeInterval(-75), now: now) == "Updated 1m ago")
}
