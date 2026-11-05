import Foundation
import Testing
@testable import SystatCore

@Test func parsesNumericColumns() {
    let out = """
      163  450000  12.5
     4242  120000   0.0
    garbage line
       77  1000  1.0  trailing-text
    """
    #expect(PSParser.parse(out) == [
        PSEntry(pid: 163, rssBytes: 450_000 * 1024, cpuPercent: 12.5),
        PSEntry(pid: 4242, rssBytes: 120_000 * 1024, cpuPercent: 0),
    ])
}

@Test func rejectsOverflowingResidentSize() {
    #expect(PSParser.parse("  7 18446744073709551615 0.0").isEmpty)
}

@Test func keepsTheFirstLineForAPID() {
    #expect(PSParser.parse("10 1000 1.0\n10 2000 2.0").map(\.rssBytes) == [1000 * 1024])
}

@Test func sanitizesControlCharacters() {
    #expect(PSParser.sanitized("bad\u{1B}[31mname\u{7F}") == "bad?[31mname?")
}
