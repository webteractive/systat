import Foundation
import Testing
@testable import SystatCore

@Test func protectionClasses() {
    #expect(Protection.classify(uid: 88, currentUID: 501, pid: 163,
                                executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                                name: "WindowServer") == .macOS)
    #expect(Protection.classify(uid: 0, currentUID: 501, pid: 300,
                                executablePath: "/Library/PrivilegedHelperTools/com.vendor.helper", name: "helper") == .notYours)
    #expect(Protection.classify(uid: 0, currentUID: 501, pid: 0, executablePath: nil, name: "kernel_task") == .macOS)
    #expect(Protection.classify(uid: 501, currentUID: 501, pid: 165,
                                executablePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                                name: "loginwindow") == .macOS)
    #expect(Protection.classify(uid: 501, currentUID: 501, pid: 419,
                                executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                                name: "Finder") == .killable)
    #expect(Protection.macOS.label == "macOS — protected")
    #expect(Protection.notYours.label == "system — not yours")
}

@Test func killOutcomeFromErrno() {
    #expect(KillOutcome(errno: 0) == .sent)
    #expect(KillOutcome(errno: ESRCH) == .gone)
    #expect(KillOutcome(errno: EPERM) == .failed("Not permitted"))
}

@Test func denyListMatchesTheExecutableNotOnlyTheDisplayName() {
    // A GUI app's display name is its localized name; the executable name is not localized.
    #expect(Protection.classify(uid: 501, currentUID: 501, pid: 165,
                                executablePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                                name: "Anmeldefenster") == .macOS)
}
