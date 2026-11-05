import Foundation
import Testing
@testable import SystatCore

@Test func readsAgainOnlyWhenOlderThanMaxAge() {
    var cache = CachedReading<Int>()
    var reads = 0
    func read() -> Int { reads += 1; return reads }
    let t0 = Date(timeIntervalSince1970: 0)
    #expect(cache.value(now: t0, maxAge: 30, read: read) == 1)
    #expect(cache.value(now: t0.addingTimeInterval(29), maxAge: 30, read: read) == 1)
    #expect(cache.value(now: t0.addingTimeInterval(30), maxAge: 30, read: read) == 2)
    #expect(cache.value(now: t0.addingTimeInterval(35), maxAge: 5, read: read) == 3)
    #expect(reads == 3)
}

@Test func failedReadKeepsThePreviousValue() {
    var cache = CachedReading<Int>()
    let t0 = Date(timeIntervalSince1970: 0)
    #expect(cache.value(now: t0, maxAge: 30, read: { 7 }) == 7)
    #expect(cache.value(now: t0.addingTimeInterval(31), maxAge: 30, read: { nil }) == 7)
    var empty = CachedReading<Int>()
    #expect(empty.value(now: t0, maxAge: 30, read: { nil }) == nil)
}
