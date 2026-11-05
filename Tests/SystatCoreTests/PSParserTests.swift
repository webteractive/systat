import Foundation
import Testing
@testable import SystatCore

@Test func parsesCommandWithSpacesAndParens() {
    let out = """
      163  450000  12.5 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
     4242  120000   0.0 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
    garbage line
    """
    let e = PSParser.parse(out)
    #expect(e.count == 2)
    #expect(e[0] == PSEntry(pid: 163, rssBytes: 450_000 * 1024, cpuPercent: 12.5,
                            command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"))
    #expect(e[1].command.hasSuffix("Google Chrome Helper (Renderer)"))
}

@Test func rejectsOverflowingResidentSize() {
    #expect(PSParser.parse("  7 18446744073709551615 0.0 /bin/evil").isEmpty)
}

@Test func dropsPIDsThatAppearTwice() {
    // A command name containing a newline can forge a second line for another PID.
    let out = """
      10  1000  1.0 /bin/real
      20  2000  2.0 /tmp/x
      10  999999  99.0 forged
    """
    #expect(PSParser.parse(out).map(\.pid) == [20])
}

@Test func sanitizesControlCharacters() {
    #expect(PSParser.sanitized("bad\u{1B}[31mname\u{7F}") == "bad?[31mname?")
}
