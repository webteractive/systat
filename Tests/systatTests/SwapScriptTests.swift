import Foundation
import Testing
@testable import SystatCore

/// Runs the real generated script against small ad-hoc-signed bundles in a temp folder.
private struct Sandbox {
    let root: URL
    var target: URL { root.appendingPathComponent("Applications/systat.app") }
    var work: URL { root.appendingPathComponent("run") }
    var staged: URL { work.appendingPathComponent("systat.app") }
    var lock: URL { root.appendingPathComponent("lock") }
    var result: URL { root.appendingPathComponent("result") }
    var relaunched: URL { root.appendingPathComponent("relaunched") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("systat-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func cleanUp() {
        _ = try? run("/bin/chmod", ["-R", "u+w", root.path])
        try? FileManager.default.removeItem(at: root)
    }

    /// A signed bundle whose Info.plist names its version, so the test can tell old from new.
    func makeApp(at url: URL, version: String) throws {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("systat").path)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.inggo.systat.test", "CFBundleExecutable": "systat",
                                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }

    func makeOldAndNew() throws {
        try makeApp(at: target, version: "0.1.0")
        try makeApp(at: staged, version: "0.2.0")
    }

    func version(at url: URL) -> String? {
        (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    var resultText: String? { try? String(contentsOf: result, encoding: .utf8) }
    var wasRelaunched: Bool { FileManager.default.fileExists(atPath: relaunched.path) }
    var targetVerifies: Bool { (try? run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path])) == 0 }

    /// Runs the helper as the app would. With no `app`, for a process that has already exited.
    @discardableResult
    func swap(app: (pid: Int32, start: String)? = nil, quitTimeoutTenths: Int = 300, lockTimeout: Int = 120,
              environment: [String: String]? = nil) throws -> Int32 {
        let (pid, start): (Int32, String)
        if let app {
            (pid, start) = app
        } else {
            let gone = try Process.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
            gone.waitUntilExit()
            (pid, start) = (gone.processIdentifier, "")
        }
        let script = SwapScript.render(
            appPID: pid, appStart: start, target: target.path, staged: staged.path, workDir: work.path,
            lockFile: lock.path, resultFile: result.path, requirement: nil,
            relaunch: "/usr/bin/touch \(SwapScript.quote(relaunched.path))",
            quitTimeoutTenths: quitTimeoutTenths, lockTimeout: lockTimeout)
        let file = work.appendingPathComponent("swap.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return try run("/bin/sh", [file.path], environment: environment)
    }

    @discardableResult func run(_ tool: String, _ args: [String], environment: [String: String]? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let environment { p.environment = environment }
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// A live process standing in for the app, with the start time the app would pass.
private func liveProcess(seconds: Int) throws -> (process: Process, pid: Int32, start: String) {
    let p = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["\(seconds)"])
    return (p, p.processIdentifier, try #require(SwapScript.startTime(of: p.processIdentifier)))
}

@Test func swapPutsTheNewAppInPlaceAndRelaunchesIt() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()

    try box.swap()

    #expect(box.version(at: box.target) == "0.2.0")
    #expect(box.targetVerifies)
    #expect(!FileManager.default.fileExists(atPath: box.work.path), "the work folder and the old app are gone")
    #expect(box.wasRelaunched)
    #expect(box.resultText == "installed 0.2.0\n")
}

@Test func swapLeavesTheInstalledAppAloneWhenTheNewOneDoesNotVerify() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // Tamper after signing: the seal no longer matches.
    try Data("x".utf8).write(to: box.staged.appendingPathComponent("Contents/MacOS/extra"))

    try box.swap()

    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.targetVerifies)
    #expect(!FileManager.default.fileExists(atPath: box.work.path))
    #expect(box.wasRelaunched, "the old app is relaunched")
    #expect(box.resultText?.hasPrefix("failed: ") == true)
}

@Test func swapPutsTheOldAppBackWhenTheNewOneCannotBeMovedIn() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // Moving a folder to a new parent needs write access to the folder itself, so a read-only
    // staged app can't move in, while the old app can still move out to the work folder.
    try box.run("/bin/chmod", ["a-w", box.staged.path])

    try box.swap()

    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.targetVerifies)
    #expect(box.wasRelaunched)
    #expect(box.resultText?.hasPrefix("failed: ") == true)
}

@Test func swapRefusesAStagedSymlink() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    // A valid, signed app elsewhere, reached through a symlink where the staged app should be.
    let elsewhere = box.root.appendingPathComponent("elsewhere.app")
    try box.makeApp(at: elsewhere, version: "0.2.0")
    try FileManager.default.createSymbolicLink(at: box.staged, withDestinationURL: elsewhere)

    try box.swap()

    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.resultText?.hasPrefix("failed: ") == true)
}

@Test func swapWaitsForTheAppToQuit() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let app = try liveProcess(seconds: 1)

    let started = Date()
    try box.swap(app: (app.pid, app.start))

    #expect(Date().timeIntervalSince(started) > 0.7, "it waited for the app")
    #expect(box.version(at: box.target) == "0.2.0")
}

@Test func aReusedPIDDoesNotHoldTheSwapUp() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // A live process on the PID, but not the one that started the update.
    let other = try liveProcess(seconds: 30)
    defer { other.process.terminate() }

    let started = Date()
    try box.swap(app: (other.pid, "Thu Jan  1 00:00:00 2001"))

    #expect(Date().timeIntervalSince(started) < 5)
    #expect(box.version(at: box.target) == "0.2.0")
}

@Test func anAppThatNeverQuitsChangesNothing() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let app = try liveProcess(seconds: 30)
    defer { app.process.terminate() }

    let status = try box.swap(app: (app.pid, app.start), quitTimeoutTenths: 3)

    #expect(status != 0)
    #expect(box.version(at: box.target) == "0.1.0")
    #expect(!box.wasRelaunched, "the app is still running, so nothing is opened")
    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

@Test func anotherUpdateHoldingTheLockStopsThisOne() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let holder = try Process.run(URL(fileURLWithPath: "/usr/bin/lockf"), arguments: ["-k", box.lock.path, "/bin/sleep", "10"])
    defer { holder.terminate() }
    for _ in 0..<50 where !FileManager.default.fileExists(atPath: box.lock.path) { usleep(20_000) }

    try box.swap(lockTimeout: 1)

    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.resultText?.hasPrefix("failed: ") == true)
    #expect(box.wasRelaunched)
}

@Test func swapNeverOpensAnAppThatDoesNotVerify() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // Whatever ends up in the slot (here a tampered app, where the new one was refused too) is
    // not this developer's app, so it is never launched as this user.
    try Data("x".utf8).write(to: box.target.appendingPathComponent("Contents/MacOS/extra"))
    try Data("x".utf8).write(to: box.staged.appendingPathComponent("Contents/MacOS/extra"))

    try box.swap()

    #expect(!box.wasRelaunched)
    #expect(box.resultText?.hasPrefix("failed: ") == true)
}

@Test func swapIgnoresTheInheritedPath() throws {
    let box = try Sandbox()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // A PATH whose mv, rm and sleep fail: the helper must use the system's own.
    let bin = box.root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for tool in ["mv", "rm", "sleep"] {
        let url = bin.appendingPathComponent(tool)
        try "#!/bin/sh\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    try box.swap(environment: ["PATH": bin.path])

    #expect(box.version(at: box.target) == "0.2.0")
    #expect(box.resultText == "installed 0.2.0\n")
}

@Test func quotingSurvivesQuotesAndSpaces() {
    #expect(SwapScript.quote("/a b/it's") == #"'/a b/it'\''s'"#)
}
