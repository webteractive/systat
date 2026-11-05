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
