import Foundation
import Testing
@testable import SystatCore

@Test func displayNamePrefersAppThenArgv0() {
    #expect(Naming.displayName(record(pid: 1, comm: "2.1.318", path: "/Users/me/.local/share/claude/versions/2.1.318",
                                      args: ["claude", "-n", "x"])) == "claude")
    #expect(Naming.displayName(record(pid: 2, comm: "Safari",
                                      app: AppInfo(name: "Safari", bundlePath: "/Applications/Safari.app"))) == "Safari")
    #expect(Naming.displayName(record(pid: 3, comm: "fseventsd",
                                      path: "/System/Library/Frameworks/CoreServices.framework/fseventsd")) == "fseventsd")
}

@Test func claudeLabels() {
    #expect(Naming.claudeLabel(arguments: ["claude", "-n", "my-project"], workingDirectory: nil, pid: 9) == "my-project")
    #expect(Naming.claudeLabel(arguments: ["claude", "--resume", "1a2b3c4d5e6f"], workingDirectory: nil, pid: 9) == "session 1a2b3c4d")
    #expect(Naming.claudeLabel(arguments: ["claude", "-c"], workingDirectory: "/Users/me/AI/systat", pid: 9) == "resumed · systat")
    #expect(Naming.claudeLabel(arguments: ["claude", "--resume"], workingDirectory: nil, pid: 9) == "resumed")
    #expect(Naming.claudeLabel(arguments: ["claude"], workingDirectory: "/Users/me/AI/systat", pid: 9) == "systat")
    #expect(Naming.claudeLabel(arguments: nil, workingDirectory: nil, pid: 9) == "pid 9")
}

@Test func claudeLabelEdgeCases() {
    #expect(Naming.claudeLabel(arguments: ["claude", "--resume=abcdef0123"], workingDirectory: nil, pid: 9) == "session abcdef01")
    #expect(Naming.claudeLabel(arguments: ["claude", "-r", "--verbose"], workingDirectory: "/x/proj", pid: 9) == "resumed · proj")
    #expect(Naming.claudeLabel(arguments: ["claude", "-n"], workingDirectory: "/x/proj", pid: 9) == "proj")
    #expect(Naming.claudeLabel(arguments: ["claude", "-r", "abcdef0123", "-n", "named"], workingDirectory: nil, pid: 9) == "named")
    #expect(Naming.claudeLabel(arguments: ["claude"], workingDirectory: "/", pid: 9) == "pid 9")
}

@Test func detailLines() {
    let build = record(pid: 4, comm: "systat", path: "/tmp/test-build/systat.app/Contents/MacOS/systat",
                       app: AppInfo(name: "systat", bundlePath: "/tmp/test-build/systat.app"))
    #expect(Naming.detail(for: build, name: "systat", nameIsShared: true, home: "/Users/me", now: now) == "/tmp/test-build")
    let installed = record(pid: 5, comm: "systat", path: "/Applications/systat.app/Contents/MacOS/systat",
                           app: AppInfo(name: "systat", bundlePath: "/Applications/systat.app"))
    #expect(Naming.detail(for: installed, name: "systat", nameIsShared: true, home: "/Users/me", now: now) == "/Applications")
    let fse = record(pid: 6, uid: 0, comm: "fseventsd",
                     path: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/fseventsd")
    #expect(Naming.detail(for: fse, name: "fseventsd", nameIsShared: false, home: "/Users/me", now: now) == "File change tracker")
    let tool = record(pid: 7, comm: "node", path: "/Users/me/.nvm/versions/node/v22/bin/node", ageDays: 3.2)
    #expect(Naming.detail(for: tool, name: "node", nameIsShared: false, home: "/Users/me", now: now)
            == "~/.nvm/versions/node/v22/bin · 3 days")
    let old = record(pid: 8, comm: "claude", args: ["claude", "--resume", "1a2b3c4d99"], ageDays: 13.5)
    #expect(Naming.detail(for: old, name: "claude", nameIsShared: true, home: "/Users/me", now: now) == "session 1a2b3c4d · 13 days")
    #expect(Naming.detail(for: record(pid: 10, comm: "mystery"), name: "mystery", nameIsShared: false,
                          home: "/Users/me", now: now) == "pid 10")
}

@Test func detailOmitsAgeWhenStartTimeUnknown() {
    var root = record(pid: 163, uid: 88, comm: "WindowServer",
                      path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
    root.identity = ProcessIdentity(pid: 163, startTime: 0)   // kernel hides other users' start times
    #expect(Naming.detail(for: root, name: "WindowServer", nameIsShared: false, home: "/Users/me", now: now) == "Display server")
}
