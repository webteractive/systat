import Foundation
import Testing
@testable import systat
@testable import SystatCore

/// The app swaps the new bundle into place itself, in one rename, before it quits; a small helper
/// reopens it afterwards. Run against small ad-hoc-signed bundles in a temp folder.
private struct Box {
    let root: URL
    var target: URL { root.appendingPathComponent("Applications/systat.app") }
    var work: URL { root.appendingPathComponent("run") }
    var staged: URL { work.appendingPathComponent("systat.app") }
    var lock: URL { root.appendingPathComponent("lock") }
    var result: URL { root.appendingPathComponent("result") }
    var opened: URL { root.appendingPathComponent("opened") }
    var alerted: URL { root.appendingPathComponent("alerted") }

    /// `name` is the box's folder, under the temp folder: a path can hold anything a folder name can.
    init(name: String = "systat-swap-\(UUID().uuidString)") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func cleanUp() {
        _ = try? run("/bin/chmod", ["-R", "u+rwx", root.path])
        try? FileManager.default.removeItem(at: root)
    }

    /// A signed bundle whose Info.plist names its version, so the test can tell old from new.
    func makeApp(at url: URL, version: String) throws {
        try? FileManager.default.removeItem(at: url)
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

    /// This exact build: the test apps' identifier, pinned by code directory hash, every architecture
    /// of it (the test apps are a copy of /usr/bin/true, universal on macOS 26).
    func exact(_ app: URL) throws -> String {
        try #require(CodeSigning.pinned(base, to: app))
    }

    /// Any build of the test app: what a working copy in place must meet.
    let base = #"identifier "dev.inggo.systat.test""#

    func swapIn(verify: (URL) -> Bool, exchange: ((URL, URL) -> Int32)? = nil) throws {
        if let exchange {
            try UpdateInstaller.swapIn(staged, at: target, work: work, verify: verify, exchange: exchange)
        } else {
            try UpdateInstaller.swapIn(staged, at: target, work: work, verify: verify)
        }
    }

    var resultText: String? { try? String(contentsOf: result, encoding: .utf8) }
    var wasOpened: Bool { FileManager.default.fileExists(atPath: opened.path) }
    var testOpen: [String] { ["/usr/bin/touch", opened.path] }
    /// Writes the alert's message to `alerted` instead of putting one on screen.
    var testAlert: [String] { ["/bin/sh", "-c", #"printf '%s' "$1" > "$0""#, alerted.path] }
    var alertText: String? { try? String(contentsOf: alerted, encoding: .utf8) }

    func update(exact: String) throws -> UpdateInstaller.Staged {
        UpdateInstaller.Staged(work: work, app: staged, target: target, targetID: UpdateInstaller.FileID(of: target),
                               exact: exact, lock: try UpdateInstaller.Lock.take(lock))
    }

    /// Starts the relaunch helper as the app does: `sh -c`, the script never written to a file, its
    /// stdin a pipe whose write end the test holds, as the app does.
    func startHelper(requirement: String, appPID: Int32? = nil, open: [String]? = nil,
                     environment: [String: String]? = nil) throws -> (process: Process, pipe: FileHandle) {
        let script = RelaunchScript.render(appPID: try appPID ?? deadPID(), target: target.path, workDir: work.path,
                                           oldApp: staged.path, resultFile: result.path, requirement: requirement,
                                           open: open ?? testOpen, alert: testAlert)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        if let environment { p.environment = environment }
        let pipe = Pipe()
        p.standardInput = pipe
        try p.run()
        return (p, pipe.fileHandleForWriting)
    }

    /// The helper's whole run: told the swap went in, then the app exits at once.
    @discardableResult
    func relaunch(requirement: String, appPID: Int32? = nil, open: [String]? = nil,
                  environment: [String: String]? = nil) throws -> Int32 {
        let helper = try startHelper(requirement: requirement, appPID: appPID, open: open, environment: environment)
        try helper.pipe.write(contentsOf: Data("go\n".utf8))
        try helper.pipe.close()
        helper.process.waitUntilExit()
        return helper.process.terminationStatus
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

    /// A bundle whose code can't be reached, its `Contents/MacOS` closed: how an earlier build
    /// disabled one (the swap now closes only the executable, mode 0, covered on its own).
    func disable(_ app: URL) throws {
        try run("/bin/chmod", ["0", app.appendingPathComponent("Contents/MacOS").path])
    }
}

/// Whether a helper started for this box is still running: its script names the box's own folder.
private func helperIsRunning(in box: Box) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", box.root.path]
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// Whether the helper `install` started has exited; reaps it if so.
private func hasExited(_ helper: UpdateInstaller.Helper) -> Bool {
    var status: Int32 = 0
    return waitpid(helper.pid, &status, WNOHANG) == helper.pid
}

/// Waits for the helper `install` started to exit.
private func waitFor(_ helper: UpdateInstaller.Helper) {
    var status: Int32 = 0
    _ = waitpid(helper.pid, &status, 0)
}

/// A real exchange the first time, then one that fails: the swap goes in, and can't be put back.
private func swapsOnlyOnce() -> (URL, URL) -> Int32 {
    var exchanges = 0
    return { a, b in
        exchanges += 1
        return exchanges == 1 ? UpdateInstaller.exchange(a, b) : EIO
    }
}

/// The PID of a process that has exited.
private func deadPID() throws -> Int32 {
    let gone = try Process.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    gone.waitUntilExit()
    return gone.processIdentifier
}

// MARK: - The swap, in the app

@Test func theNewAppIsSwappedIntoPlaceInOneStep() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let exact = try box.exact(box.staged)

    try box.swapIn(verify: { CodeSigning.isExactly($0, requirement: exact) })

    #expect(box.version(at: box.target) == "0.2.0")
    #expect(box.version(at: box.staged) == "0.1.0", "the old app took the staged one's place")
}

@Test func aStagedAppChangedSinceItWasCheckedIsRefused() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let exact = try box.exact(box.staged)
    // Another validly signed build put in its place: same identifier, different code directory.
    try box.makeApp(at: box.staged, version: "0.2.1")

    #expect(throws: UpdateInstaller.Failure.changed) {
        try box.swapIn(verify: { CodeSigning.isExactly($0, requirement: exact) })
    }
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func aNewAppThatFailsInPlaceIsSwappedBack() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    var checks = 0

    #expect(throws: UpdateInstaller.Failure.notInPlace) {
        try box.swapIn(verify: { _ in checks += 1; return checks == 1 })
    }
    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.version(at: box.staged) == "0.2.0")
}

@Test func aSwapTheVolumeRefusesChangesNothing() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()

    #expect(throws: UpdateInstaller.Failure.swap) {
        try box.swapIn(verify: { _ in true }, exchange: { _, _ in EIO })
    }
    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.version(at: box.staged) == "0.2.0")
}

@Test func whenNothingCanBePutRightTheNewAppCannotOpen() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    var checks = 0
    let previous = box.work.appendingPathComponent("previous.app")

    #expect(throws: UpdateInstaller.Failure.stranded(previous: previous.path, disabled: true, target: box.target.path)) {
        try box.swapIn(verify: { _ in checks += 1; return checks == 1 }, exchange: swapsOnlyOnce())
    }
    // Neither LaunchServices nor a login item can start what's in the slot, and the old app is
    // kept where pruning leaves it.
    let executable = box.target.appendingPathComponent("Contents/MacOS/systat").path
    #expect((try? FileManager.default.attributesOfItem(atPath: executable))?[.posixPermissions] as? Int == 0)
    #expect(box.version(at: previous) == "0.1.0")
    // And the next offer of that same update can replace it: it isn't taken for a newer copy put in
    // place by hand, though it is newer than the running one.
    let again = AvailableUpdate(version: "0.2.0", releasePage: UpdateCheck.releasesPage, dmg: nil, checksum: nil)
    #expect(!UpdateInstaller.inPlaceBlocks(box.target, update: again))
    let older = AvailableUpdate(version: "0.1.5", releasePage: UpdateCheck.releasesPage, dmg: nil, checksum: nil)
    #expect(UpdateInstaller.inPlaceBlocks(box.target, update: older), "an older update than what is there")
    // Yet it can still be thrown away like any app: Finder, the Trash and rm all can.
    try FileManager.default.removeItem(at: box.target)
}

@Test func theStrandedMessageNeverClaimsTheAppWasDisabledWhenItWasnt() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // Nothing to disable: the new app has no code folder for the chmod to close.
    try FileManager.default.removeItem(at: box.staged.appendingPathComponent("Contents/MacOS"))
    var checks = 0

    #expect(throws: UpdateInstaller.Failure.stranded(previous: box.work.appendingPathComponent("previous.app").path,
                                                     disabled: false, target: box.target.path)) {
        try box.swapIn(verify: { _ in checks += 1; return checks == 1 }, exchange: swapsOnlyOnce())
    }
}

@Test func anotherUpdateHoldingTheLockStopsThisOne() throws {
    let box = try Box()
    defer { box.cleanUp() }
    // Held by lockf around a cat reading a pipe: closing the pipe ends both, leaving nothing behind.
    let holder = Process(), feed = Pipe()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    holder.arguments = ["-k", box.lock.path, "/bin/cat"]
    holder.standardInput = feed
    holder.standardOutput = FileHandle.nullDevice
    try holder.run()
    defer { try? feed.fileHandleForWriting.close(); holder.waitUntilExit() }
    // Until lockf really holds it (it creates the file first, then locks it).
    var held = false
    for _ in 0..<250 where !held {
        let fd = open(box.lock.path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 { held = flock(fd, LOCK_SH | LOCK_NB) != 0; close(fd) }
        if !held { usleep(4_000) }
    }
    try #require(held)

    #expect(throws: UpdateInstaller.Failure.busy) { try UpdateInstaller.Lock.take(box.lock) }
}

@Test func theUpdateLockIsPrivateEvenIfItsFileWasLeftOpen() throws {
    // Another user who could open it could hold it, and stop every update: no read for them, by mode
    // or by an ACL the file carried (or inherited).
    let box = try Box()
    defer { box.cleanUp() }
    FileManager.default.createFile(atPath: box.lock.path, contents: nil, attributes: [.posixPermissions: 0o644])
    try box.run("/bin/chmod", ["+a", "group:everyone allow read", box.lock.path])
    try #require(acl_get_file(box.lock.path, ACL_TYPE_EXTENDED) != nil)

    let lock = try UpdateInstaller.Lock.take(box.lock)
    withExtendedLifetime(lock) {}
    #expect(try FileManager.default.attributesOfItem(atPath: box.lock.path)[.posixPermissions] as? Int == 0o600)
    #expect(acl_get_file(box.lock.path, ACL_TYPE_EXTENDED) == nil, "no ACL left")
}

@Test func aLockLetGoOfAMomentLaterIsTaken() throws {
    // Another side's probe holds it for an instant: that isn't another update.
    let box = try Box()
    defer { box.cleanUp() }
    // Held by another process until the test lets go of it, 0.05 s in, while Lock.take is retrying
    // (for 0.5 s: room for a slow machine); taken only once it is really held, so the retry is what
    // gets it.
    let holder = Process(), feed = Pipe()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    holder.arguments = ["-k", box.lock.path, "/bin/cat"]
    holder.standardInput = feed
    holder.standardOutput = FileHandle.nullDevice
    try holder.run()
    defer { try? feed.fileHandleForWriting.close(); holder.waitUntilExit() }
    var held = false
    for _ in 0..<5000 where !held {
        let fd = open(box.lock.path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 { held = flock(fd, LOCK_SH | LOCK_NB) != 0; close(fd) }
        if !held { usleep(2_000) }
    }
    try #require(held)
    let writer = feed.fileHandleForWriting
    // A thread of its own: the test's own thread is the one retrying.
    Thread.detachNewThread { usleep(50_000); try? writer.close() }
    #expect(throws: Never.self) { _ = try UpdateInstaller.Lock.take(box.lock) }
}

@Test func anInstallRunningMeanwhileStopsThisOne() throws {
    // The installer's lock is a flock on its lock file, as the updater's is: held while it runs,
    // gone when it ends however it ends, so a file left behind means nothing.
    let box = try Box()
    defer { box.cleanUp() }
    let lock = box.root.appendingPathComponent("systat-install.lock")
    #expect(!UpdateInstaller.installerIsRunning(lock), "no lock")
    try Data().write(to: lock)
    #expect(!UpdateInstaller.installerIsRunning(lock), "a lock file no one holds")

    let holder = Process(), feed = Pipe()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    holder.arguments = ["-k", lock.path, "/bin/cat"]
    holder.standardInput = feed
    holder.standardOutput = FileHandle.nullDevice
    try holder.run()
    defer { try? feed.fileHandleForWriting.close(); holder.waitUntilExit() }
    var running = false
    for _ in 0..<50 where !running {
        running = UpdateInstaller.installerIsRunning(lock)
        if !running { usleep(20_000) }
    }
    #expect(running)
}

@Test func theLockIsHeldForAsLongAsTheStagedUpdate() throws {
    // The panel's Update clicked twice, or the panel and a terminal at once: the second is refused
    // while the first is still downloading, not just during the swap.
    let box = try Box()
    defer { box.cleanUp() }
    var first: UpdateInstaller.Lock? = try UpdateInstaller.Lock.take(box.lock)

    #expect(throws: UpdateInstaller.Failure.busy) { try UpdateInstaller.Lock.take(box.lock) }
    withExtendedLifetime(first) {}
    first = nil
    // macOS releases a flock only once no process holds a copy of the file, and a child another test
    // is spawning holds one for a moment, close-on-exec or not: a second click comes far later.
    var next: UpdateInstaller.Lock?
    for _ in 0..<50 where next == nil {
        next = try? UpdateInstaller.Lock.take(box.lock)
        if next == nil { Thread.sleep(forTimeInterval: 0.02) }
    }
    #expect(next != nil, "dropping the staged update lets the next one go")
}

@Test func aLockThatCantBeOpenedSaysSo() throws {
    let box = try Box()
    defer { box.cleanUp() }

    #expect(throws: UpdateInstaller.Failure.lock) {
        try UpdateInstaller.Lock.take(box.root.appendingPathComponent("missing/lock"))
    }
}

@Test func anAppMovedDuringTheDownloadSaysSo() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    try FileManager.default.moveItem(at: box.target, to: box.root.appendingPathComponent("Applications/moved.app"))

    #expect(throws: UpdateInstaller.Failure.moved) { try box.swapIn(verify: { _ in true }) }
}

@Test func aSwapMacOSForbidsSaysWhy() throws {
    // App Management: the terminal that ran systat --update may not change apps.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()

    #expect(throws: UpdateInstaller.Failure.blocked) {
        try box.swapIn(verify: { _ in true }, exchange: { _, _ in EPERM })
    }
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func anUpdateThatCouldntIdentifyTheInstalledAppIsntSwappedIn() throws {
    // Without the app's file identity from the checks, a replacement couldn't be told apart.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let staged = UpdateInstaller.Staged(work: box.work, app: box.staged, target: box.target, targetID: nil,
                                        exact: try box.exact(box.staged), lock: try UpdateInstaller.Lock.take(box.lock))

    #expect(throws: UpdateInstaller.Failure.moved) {
        try UpdateInstaller.install(staged, appPID: try deadPID(), open: box.testOpen, resultFile: box.result, alert: box.testAlert)
    }
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func anAppLockedDuringTheDownloadSaysToUnlockIt() throws {
    // Locked in Finder after the checks: not blamed on App Management.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    try #require(chflags(box.target.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(box.target.path, 0) }

    #expect(throws: UpdateInstaller.Failure.locked) { try box.swapIn(verify: { _ in true }) }
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func onlyAStrandedOrMovedAppIsntThereToReopen() {
    #expect(!UpdateInstaller.Failure.stranded(previous: "/x", disabled: true, target: "/y").keptInstalledApp)
    // Whatever is at the path now (nothing, or something put there) isn't what was quit.
    #expect(!UpdateInstaller.Failure.moved.keptInstalledApp)
    for kept: UpdateInstaller.Failure in [.helper, .lock, .busy, .blocked, .changed, .swap, .notInPlace] {
        #expect(kept.keptInstalledApp, "\(kept)")
    }
}

@Test func aStagedLinkIsNeverSwappedIn() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    let elsewhere = box.root.appendingPathComponent("elsewhere.app")
    try box.makeApp(at: elsewhere, version: "0.2.0")
    try FileManager.default.createSymbolicLink(at: box.staged, withDestinationURL: elsewhere)

    #expect(throws: UpdateInstaller.Failure.changed) { try box.swapIn(verify: { _ in true }) }
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func aLinkPutInPlaceAfterTheStagedAppWasCheckedIsNeverSwappedIn() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // The same URL value staging checked: what it learned then is cached on it.
    let staged = box.staged
    #expect(try staged.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true)
    let elsewhere = box.root.appendingPathComponent("elsewhere.app")
    try FileManager.default.moveItem(at: staged, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: elsewhere)

    #expect(throws: UpdateInstaller.Failure.changed) {
        try UpdateInstaller.swapIn(staged, at: box.target, work: box.work, verify: { _ in true })
    }
    #expect(box.version(at: box.target) == "0.1.0")
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.target.path)) == nil)
}

@Test func anAppReplacedDuringTheDownloadIsNotSwappedOut() throws {
    // Another bundle at the same path is not the systat that was checked, and the old app swapped
    // out is removed afterwards.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let checked = try #require(UpdateInstaller.FileID(of: box.target))
    try FileManager.default.moveItem(at: box.target, to: box.root.appendingPathComponent("moved.app"))
    try box.makeApp(at: box.target, version: "9.9.9")

    #expect(throws: UpdateInstaller.Failure.moved) {
        try UpdateInstaller.swapIn(box.staged, at: box.target, work: box.work, expected: checked, verify: { _ in true })
    }
    #expect(box.version(at: box.target) == "9.9.9")
}

@Test func aHelperThatIsGoneIsNoticed() throws {
    // Told nothing, systat would quit and nothing would reopen it or say why.
    var ends: [Int32] = [0, 0]
    try #require(pipe(&ends) == 0)
    close(ends[0])
    _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
    defer { close(ends[1]) }

    #expect(!UpdateInstaller.Helper(pid: 0, pipe: ends[1]).go())
}

@Test func aSwapWhoseHelperIsGoneLeavesANote() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()

    try UpdateInstaller.noteUnopened(box.target, in: box.result)

    #expect(box.resultText?.hasPrefix("failed: ") == true)
    #expect(box.resultText?.contains(box.target.path) == true)
}

// MARK: - Install: the swap with its helper

@Test func installSwapsInAndTheHelperOpensOnlyOnceTheAppHasExited() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let exact = try box.exact(box.staged)

    // Started exactly as the app starts it, environment and all.
    let helper = try UpdateInstaller.install(try box.update(exact: exact), appPID: try deadPID(), open: box.testOpen,
                                             resultFile: box.result, alert: box.testAlert)

    #expect(box.version(at: box.target) == "0.2.0")
    #expect(helper.told)
    usleep(500_000)
    #expect(!box.wasOpened, "nothing is opened while the app is still running")
    #expect(!hasExited(helper))
    close(helper.pipe)   // the app exits
    waitFor(helper)
    #expect(box.wasOpened)
    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

@Test func aFailedInstallLeavesTheHelperNothingToDo() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let exact = try box.exact(box.staged)
    try box.makeApp(at: box.staged, version: "0.2.1")

    #expect(throws: UpdateInstaller.Failure.changed) {
        try UpdateInstaller.install(try box.update(exact: exact), appPID: try deadPID(), open: box.testOpen,
                                    resultFile: box.result, alert: box.testAlert)
    }
    for _ in 0..<100 where helperIsRunning(in: box) { usleep(20_000) }
    #expect(!helperIsRunning(in: box), "the helper was let go")
    #expect(!box.wasOpened)
    #expect(box.resultText == nil)
    #expect(box.version(at: box.target) == "0.1.0")
    #expect(!FileManager.default.fileExists(atPath: box.work.path), "the staged copy is discarded")
}

@Test func aStrandedInstallKeepsTheOldApp() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    var checks = 0

    #expect(throws: UpdateInstaller.Failure.stranded(previous: box.work.appendingPathComponent("previous.app").path,
                                                     disabled: true, target: box.target.path)) {
        try UpdateInstaller.install(try box.update(exact: "never"), appPID: try deadPID(), open: box.testOpen,
                                    resultFile: box.result, alert: box.testAlert, verify: { _ in checks += 1; return checks == 1 },
                                    exchange: swapsOnlyOnce())
    }
    for _ in 0..<100 where helperIsRunning(in: box) { usleep(20_000) }
    #expect(!helperIsRunning(in: box), "the helper was let go")
    #expect(!box.wasOpened)
    #expect(box.version(at: box.work.appendingPathComponent("previous.app")) == "0.1.0")
}

@Test func aStrandedInstallLeavesANoteSayingWhereTheOldAppIs() throws {
    // Read again at the next launch: the login item may not start the disabled copy, and the panel's
    // message is gone once systat quits.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let previous = box.work.appendingPathComponent("previous.app").path
    var checks = 0

    #expect(throws: UpdateInstaller.Failure.stranded(previous: previous, disabled: true, target: box.target.path)) {
        try UpdateInstaller.install(try box.update(exact: "never"), appPID: try deadPID(), open: box.testOpen,
                                    resultFile: box.result, alert: box.testAlert, verify: { _ in checks += 1; return checks == 1 },
                                    exchange: swapsOnlyOnce())
    }
    #expect(box.resultText?.hasPrefix("failed: ") == true)
    #expect(box.resultText?.contains(previous) == true)
}

@Test func anUpdateThatChangedAfterItsChecksKeepsTheEarlierNote() throws {
    // Refused before anything was swapped: nothing changed, so what the last update left stands.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let exact = try box.exact(box.staged)
    try box.makeApp(at: box.staged, version: "0.2.1")
    try Data("failed: earlier\n".utf8).write(to: box.result)

    #expect(throws: UpdateInstaller.Failure.changed) {
        try UpdateInstaller.install(try box.update(exact: exact), appPID: try deadPID(), open: box.testOpen,
                                    resultFile: box.result, alert: box.testAlert)
    }
    #expect(box.resultText == "failed: earlier\n")
}

@Test func aSwapMacOSRefusesKeepsTheEarlierNote() throws {
    // App Management refusing the exchange itself, after the run is marked.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    try Data("failed: earlier\n".utf8).write(to: box.result)

    #expect(throws: UpdateInstaller.Failure.blocked) {
        try UpdateInstaller.install(try box.update(exact: try box.exact(box.staged)), appPID: try deadPID(),
                                    open: box.testOpen, resultFile: box.result, alert: box.testAlert, exchange: { _, _ in EPERM })
    }
    #expect(box.resultText == "failed: earlier\n")
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func aNoteIsNeverWrittenThroughALink() throws {
    // The state folder is private, but a link left in it must not aim systat's write elsewhere.
    let box = try Box()
    defer { box.cleanUp() }
    let elsewhere = box.root.appendingPathComponent("elsewhere")
    try Data("untouched".utf8).write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: box.result, withDestinationURL: elsewhere)

    try? UpdateInstaller.noteUnopened(box.target, in: box.result)

    #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "untouched")
}

@Test func theHelpersNoteIsNeverWrittenThroughALink() throws {
    let box = try Box()
    defer { box.cleanUp() }
    let elsewhere = box.root.appendingPathComponent("elsewhere")
    try Data("untouched".utf8).write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: box.result, withDestinationURL: elsewhere)
    try box.makeApp(at: box.target, version: "0.2.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")

    try box.relaunch(requirement: exact)

    #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "untouched")
    #expect(box.resultText?.hasPrefix("failed: ") == true, "the note is written in the link's place")
}

@Test func theHelpersNoteIsNeverWrittenThroughALinkToADevice() throws {
    // sh's set -C refuses an existing file, but still opens a link to a device.
    let box = try Box()
    defer { box.cleanUp() }
    try FileManager.default.createSymbolicLink(at: box.result, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
    try box.makeApp(at: box.target, version: "0.2.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")

    try box.relaunch(requirement: exact)

    #expect(box.resultText?.hasPrefix("failed: ") == true, "the note replaces the link")
}

@Test func aHelperGoneBeforeItWasToldIsANoteOnlyIfItWasToReopen() throws {
    // systat --update with systat not running: nothing was due to reopen, so nothing went wrong.
    let box = try Box()
    defer { box.cleanUp() }

    UpdateInstaller.noteIfUnopened(told: false, reopening: false, target: box.target, in: box.result)
    #expect(box.resultText == nil)
    UpdateInstaller.noteIfUnopened(told: true, reopening: true, target: box.target, in: box.result)
    #expect(box.resultText == nil)
    UpdateInstaller.noteIfUnopened(told: false, reopening: true, target: box.target, in: box.result)
    #expect(box.resultText?.contains(box.target.path) == true)
}

@Test func theCopyQuitForAnUpdateIsReopenedIfItIsStillThere() throws {
    // systat --update quit what was at the path, then found it wasn't the app it had checked
    // (replaced during the download): that copy is reopened, not left quit.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    let quit = UpdateInstaller.FileID(of: box.target)
    try #require(quit != nil)
    let elsewhere = UpdateInstaller.FileID(of: box.root)

    #expect(UpdateInstaller.Failure.moved.reopensQuitApp(quit: quit, now: UpdateInstaller.FileID(of: box.target)))
    #expect(!UpdateInstaller.Failure.moved.reopensQuitApp(quit: quit, now: elsewhere))
    #expect(!UpdateInstaller.Failure.moved.reopensQuitApp(quit: quit, now: nil))
    #expect(UpdateInstaller.Failure.blocked.reopensQuitApp(quit: quit, now: UpdateInstaller.FileID(of: box.target)))
    #expect(!UpdateInstaller.Failure.stranded(previous: nil, disabled: true, target: box.target.path)
        .reopensQuitApp(quit: quit, now: UpdateInstaller.FileID(of: box.target)))
}

@Test func theCopyQuitForAnUpdateIsReopenedOnlyIfItIsStillThatBuild() throws {
    // systat --update opens again what it quit only if it is the very build it quit, and can still
    // start: not another build put there meanwhile, nor a copy whose executable was closed.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    let quit = UpdateInstaller.QuitCopy(at: box.target, requirement: box.base)
    #expect(quit.isStill(at: box.target))

    try box.disable(box.target)
    #expect(!quit.isStill(at: box.target))
    try box.run("/bin/chmod", ["-R", "u+rwx", box.target.path])
    // Still verifies (permissions aren't sealed), but can't start.
    try box.run("/bin/chmod", ["0644", box.target.appendingPathComponent("Contents/MacOS/systat").path])
    #expect(!quit.isStill(at: box.target))

    try box.makeApp(at: box.target, version: "0.1.9")
    #expect(!quit.isStill(at: box.target))
    try FileManager.default.removeItem(at: box.target)
    #expect(!quit.isStill(at: box.target))
}

@Test func aCopyQuitForAnUpdateThatIsntReopenedIsSaid() throws {
    // systat --update quit it: the user is told whenever it isn't opened again, unless the error
    // itself says what is in place.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    let quit = UpdateInstaller.QuitCopy(at: box.target, requirement: box.base)
    let stranded = UpdateInstaller.Failure.stranded(previous: nil, disabled: false, target: box.target.path)

    #expect(quit.afterFailure(.blocked, at: box.target) == .reopen)
    #expect(quit.afterFailure(.moved, at: box.target) == .reopen)
    #expect(quit.afterFailure(stranded, at: box.target) == .leave)

    // Replaced while it was being quit.
    try box.makeApp(at: box.target, version: "0.1.9")
    for error in [UpdateInstaller.Failure.moved, .blocked] {
        guard case .say(let message) = quit.afterFailure(error, at: box.target) else {
            Issue.record("\(error) says nothing"); continue
        }
        #expect(message.contains(box.target.path) && message.contains("wasn't opened again"))
        #expect(message.contains("no longer"))
    }

    // The same file, but it can't start: not claimed to be another copy.
    let disabled = UpdateInstaller.QuitCopy(at: box.target, requirement: box.base)
    try box.run("/bin/chmod", ["0644", box.target.appendingPathComponent("Contents/MacOS/systat").path])
    guard case .say(let same) = disabled.afterFailure(.blocked, at: box.target) else {
        Issue.record("says nothing"); return
    }
    #expect(same.contains("couldn't confirm") && !same.contains("no longer"))

    // Removed while it was being quit: not another copy, just none.
    try box.run("/bin/chmod", ["-R", "u+rwx", box.target.path])
    try FileManager.default.removeItem(at: box.target)
    guard case .say(let gone) = quit.afterFailure(.moved, at: box.target) else {
        Issue.record("says nothing"); return
    }
    #expect(gone.contains("gone") && !gone.contains("no longer"))
    try box.makeApp(at: box.target, version: "0.1.0")

    // Its build couldn't be read before the quit: not claimed to have changed.
    let unread = UpdateInstaller.QuitCopy(at: box.root.appendingPathComponent("none.app"), requirement: box.base)
    guard case .say(let message) = unread.afterFailure(.blocked, at: box.target) else {
        Issue.record("says nothing"); return
    }
    #expect(message.contains("couldn't confirm"))
}

@Test func anImageWithoutSystatSaysSo() throws {
    // It opened: "couldn't be opened" would send the user looking in the wrong place.
    let box = try Box()
    defer { box.cleanUp() }
    let image = box.root.appendingPathComponent("image")
    try FileManager.default.createDirectory(at: image, withIntermediateDirectories: false)

    #expect(throws: UpdateInstaller.Failure.badImage) {
        try UpdateInstaller.takeApp(from: image, to: box.root.appendingPathComponent("copied.app"), detach: { _ in true })
    }
}

@Test func anImageThatWontEjectSaysSo() throws {
    let box = try Box()
    defer { box.cleanUp() }
    let image = box.root.appendingPathComponent("image")
    try box.makeApp(at: image.appendingPathComponent("systat.app"), version: "0.2.0")

    #expect(throws: UpdateInstaller.Failure.eject) {
        try UpdateInstaller.takeApp(from: image, to: box.root.appendingPathComponent("copied.app"), detach: { _ in false })
    }
}

@Test func aSwapThatGoesInClearsTheEarlierNote() throws {
    // What it was about has just been replaced.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    try Data("failed: earlier\n".utf8).write(to: box.result)

    let helper = try UpdateInstaller.install(try box.update(exact: try box.exact(box.staged)), appPID: try deadPID(),
                                             open: box.testOpen, resultFile: box.result, alert: box.testAlert)

    #expect(box.resultText == nil)
    close(helper.pipe)
    waitFor(helper)
    #expect(box.wasOpened)
}

@Test func theHelperIsBeyondTheReachOfThisProcesssGroup() throws {
    // A terminal's Ctrl-C or hang-up, or a kill aimed at systat's process group, never reaches it.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()

    let helper = try UpdateInstaller.install(try box.update(exact: try box.exact(box.staged)), appPID: try deadPID(),
                                             open: box.testOpen, resultFile: box.result, alert: box.testAlert)

    #expect(getsid(helper.pid) == helper.pid, "it leads a session of its own")
    #expect(getpgid(helper.pid) != getpgrp())
    close(helper.pipe)
    waitFor(helper)
    #expect(box.wasOpened)
}

@Test func theHelperGetsNoOtherFileThisProcessHasOpen() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // Open without close-on-exec, as anything in the app might leave one.
    let secret = box.root.appendingPathComponent("open-in-the-app")
    try Data().write(to: secret)
    let fd = open(secret.path, O_RDONLY)
    try #require(fd >= 0)
    defer { close(fd) }

    let helper = try UpdateInstaller.install(try box.update(exact: try box.exact(box.staged)), appPID: try deadPID(),
                                             open: box.testOpen, resultFile: box.result, alert: box.testAlert)
    let lsof = Process(), out = Pipe()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-n", "-P", "-p", String(helper.pid)]
    lsof.standardOutput = out
    try lsof.run()
    let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    lsof.waitUntilExit()
    close(helper.pipe)
    waitFor(helper)

    // By its PID, whatever shell /bin/sh is on this Mac.
    #expect(listing.contains(" \(helper.pid) "), "lsof saw the helper")
    #expect(!listing.contains(secret.lastPathComponent))
}

@Test func theHelperHoldsTheUpdateLockUntilItEnds() throws {
    // systat lets go of it when it exits, but the helper still checks and opens the new version for a
    // moment after: no installer or other update may start in between.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let helper = try UpdateInstaller.install(try box.update(exact: try box.exact(box.staged)), appPID: try deadPID(),
                                             open: box.testOpen, resultFile: box.result, alert: box.testAlert)
    let lsof = Process(), out = Pipe()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-n", "-P", "-p", String(helper.pid)]
    lsof.standardOutput = out
    try lsof.run()
    let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    lsof.waitUntilExit()
    close(helper.pipe)
    waitFor(helper)

    #expect(listing.contains(box.lock.path), "the helper has the lock")
}

@Test func theHelpersAlertDoesntHoldTheUpdateLock() throws {
    // It may stay on screen for hours, and it says to run the installer, which mustn't then find the
    // lock still held.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    try box.makeApp(at: box.staged, version: "0.1.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")
    let lock = try UpdateInstaller.Lock.take(box.lock)
    // A stand-in alert that says whether descriptor 3 (the lock, as the helper gets it) is open.
    let fdState = box.root.appendingPathComponent("alert-fd3")
    let script = RelaunchScript.render(appPID: try deadPID(), target: box.target.path, workDir: box.work.path,
                                       oldApp: box.staged.path, resultFile: box.result.path, requirement: exact,
                                       open: box.testOpen,
                                       alert: ["/bin/sh", "-c", #"if (: <&3) 2>/dev/null; then echo open; else echo closed; fi > "$0""#, fdState.path])
    let helper = try UpdateInstaller.startHelper(script, holding: lock)
    #expect(write(helper.pipe, "go\n", 3) == 3)
    close(helper.pipe)
    waitFor(helper)

    #expect((try? String(contentsOf: fdState, encoding: .utf8)) == "closed\n")
}

@Test func aRunFolderWithItsImageStillMountedIsRemoved() throws {
    // An attempt that died between mounting the image and unmounting it.
    let box = try Box()
    defer { box.cleanUp() }
    let image = box.root.appendingPathComponent("t.dmg")
    let mount = box.work.appendingPathComponent("mount")
    try box.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "t", image.path])
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try #require(try box.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint",
                                                  mount.path, image.path]) == 0)
    defer { _ = try? box.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

    UpdateInstaller.removeTree(box.work)

    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

@Test func aDisabledAppInADiscardedRunIsRemovedToo() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.staged, version: "0.2.0")
    try box.disable(box.staged)

    try box.update(exact: "").discard()

    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

// MARK: - The relaunch helper

@Test func theHelperWaitsForTheAppToExitThenOpensTheNewOne() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let helper = try box.startHelper(requirement: try box.exact(box.target))

    try helper.pipe.write(contentsOf: Data("go\n".utf8))
    usleep(500_000)
    #expect(!box.wasOpened, "it waits however long the app takes to quit")
    try helper.pipe.close()
    helper.process.waitUntilExit()

    #expect(box.wasOpened)
    #expect(!FileManager.default.fileExists(atPath: box.work.path), "the old app and the work folder are gone")
}

@Test func withoutTheWordToGoTheHelperDoesNothing() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let helper = try box.startHelper(requirement: try box.exact(box.target))

    try helper.pipe.close()   // the swap failed, or the app died before it
    helper.process.waitUntilExit()

    #expect(!box.wasOpened)
    #expect(box.resultText == nil)
    #expect(FileManager.default.fileExists(atPath: box.work.path))
}

@Test func theHelperOpensOnlyTheExactBuildThatWasSwappedIn() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    try box.makeApp(at: box.staged, version: "0.1.0")   // the old app, where the swap left it
    let exact = try box.exact(box.target)
    // Something else, validly signed, in the slot by the time the app has quit.
    try box.makeApp(at: box.target, version: "0.2.1")

    try box.relaunch(requirement: exact)

    #expect(!box.wasOpened)
    // Whatever is in place now was put there by someone else (the installer, another update): it
    // is left as it is, runnable, and so is the old app, named in the note.
    #expect(box.version(at: box.target) == "0.2.1")
    let executable = box.target.appendingPathComponent("Contents/MacOS/systat").path
    #expect((try? FileManager.default.attributesOfItem(atPath: executable))?[.posixPermissions] as? Int == 0o755)
    #expect(box.version(at: box.staged) == "0.1.0")
    #expect(box.resultText?.hasPrefix("failed: ") == true)
    #expect(box.resultText?.contains(box.staged.path) == true)
}

@Test func aHelperThatWontOpenTheNewVersionSaysSoRightAway() throws {
    // The note waits for systat's next launch, which may never come: say it now too.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")

    try box.relaunch(requirement: exact)

    let alert = try #require(box.alertText)
    #expect(box.resultText == "failed: " + alert + "\n")
}

@Test func aHelperThatOpensTheNewVersionShowsNoAlert() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")

    try box.relaunch(requirement: try box.exact(box.target))

    #expect(box.wasOpened)
    #expect(box.alertText == nil)
}

@Test func theHelpersNoteKeepsAPathAsItIs() throws {
    // sh's echo turns \c and \n in a path into a cut or a new line.
    let box = try Box(name: #"systat-swap-a\cb\n-\#(UUID().uuidString)"#)
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    try box.makeApp(at: box.staged, version: "0.1.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")

    try box.relaunch(requirement: exact)

    #expect(box.resultText?.contains(box.staged.path) == true, "\(box.resultText ?? "nil")")
}

@Test func anOpenThatFailsIsReported() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")

    try box.relaunch(requirement: try box.exact(box.target), open: ["/usr/bin/false"])

    #expect(box.resultText?.hasPrefix("failed: ") == true)
    #expect(box.resultText?.contains("couldn't be opened") == true)
}

@Test func theHelperNeverOpensATamperedApp() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let exact = try box.exact(box.target)
    try Data("x".utf8).write(to: box.target.appendingPathComponent("Contents/MacOS/extra"))

    try box.relaunch(requirement: exact)

    #expect(!box.wasOpened)
}

@Test func anAppPIDThatOutlivesThePipeHoldsTheHelperOnlyBriefly() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    // A zombie, or the PID already reused: either way still "running" by its PID.
    let other = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    defer { other.terminate() }

    let started = Date()
    try box.relaunch(requirement: try box.exact(box.target), appPID: other.processIdentifier)

    let waited = Date().timeIntervalSince(started)
    #expect(waited > 1.5 && waited < 5)
    #expect(box.wasOpened)
}

@Test func withNothingToReopenTheHelperOnlyCleansUp() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    try box.makeApp(at: box.staged, version: "0.1.0")

    try box.relaunch(requirement: try box.exact(box.target), open: [])

    #expect(!box.wasOpened)
    #expect(box.resultText == nil)
    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

@Test func withNothingToReopenTheHelperKeepsTheOldAppIfTheNewOneIsntInPlace() throws {
    // Something replaced the build it swapped in before it ran: the old app may be the only working
    // copy left, so it stays, and the note says where.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    try box.makeApp(at: box.staged, version: "0.1.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")

    try box.relaunch(requirement: exact, open: [])

    #expect(!box.wasOpened)
    #expect(box.version(at: box.staged) == "0.1.0")
    #expect(box.resultText?.contains(box.staged.path) == true)
    #expect(box.resultText?.contains("didn't open") == false, "nothing was to be opened")
    #expect(box.alertText?.contains(box.staged.path) == true, "said straight away too")
}

@Test func theHelperRemovesADisabledAppFromTheWorkFolder() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    try box.makeApp(at: box.staged, version: "0.1.0")
    try box.disable(box.staged)

    try box.relaunch(requirement: try box.exact(box.target))

    #expect(box.wasOpened)
    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

@Test func theHelperIgnoresTheInheritedPath() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    // A PATH whose tools all fail: the helper must use the system's own.
    let bin = box.root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for tool in ["rm", "sleep", "codesign", "cat", "chmod"] {
        let url = bin.appendingPathComponent(tool)
        try "#!/bin/sh\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    try box.relaunch(requirement: try box.exact(box.target), environment: ["PATH": bin.path])

    #expect(box.wasOpened)
    #expect(!FileManager.default.fileExists(atPath: box.work.path))
}

@Test func theOpenCommandIsQuotedWordByWord() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let odd = box.root.appendingPathComponent("it's $(here) `x`")

    try box.relaunch(requirement: try box.exact(box.target), open: ["/usr/bin/touch", odd.path])

    #expect(FileManager.default.fileExists(atPath: odd.path))
}

@Test func quotingSurvivesQuotesAndSpaces() {
    #expect(RelaunchScript.quote("/a b/it's") == #"'/a b/it'\''s'"#)
}

@Test func theRunIsMarkedBeforeAnythingIsExchanged() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    var marked = false

    try box.swapIn(verify: { _ in true }, exchange: { a, b in
        marked = FileManager.default.fileExists(atPath: box.work.appendingPathComponent(UpdateInstaller.swapMark).path)
        return UpdateInstaller.exchange(a, b)
    })

    #expect(marked, "pruning must never take a run whose swap started")
}

@Test func aRunThatCantBeMarkedChangesNothing() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    // A folder where the mark goes: it can't be written, and the swap itself would still work.
    try FileManager.default.createDirectory(at: box.work.appendingPathComponent(UpdateInstaller.swapMark),
                                            withIntermediateDirectories: false)

    #expect(throws: UpdateInstaller.Failure.swap) { try box.swapIn(verify: { _ in true }) }
    #expect(box.version(at: box.target) == "0.1.0")
    #expect(box.version(at: box.staged) == "0.2.0")
}

// MARK: - Final review fixes

@Test func theLockOutlivesTheStagedUpdateOnceTheSwapIsIn() throws {
    // Held until the process exits, not until the staged update is dropped just before it quits.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    do {
        let helper = try UpdateInstaller.install(try box.update(exact: try box.exact(box.staged)), appPID: try deadPID(),
                                                 open: box.testOpen, resultFile: box.result, alert: box.testAlert)
        close(helper.pipe)
        waitFor(helper)
    }

    #expect(throws: UpdateInstaller.Failure.busy) { _ = try UpdateInstaller.Lock.take(box.lock) }
}

@Test func disablingTheAppNeverFollowsALink() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let elsewhere = box.root.appendingPathComponent("elsewhere")
    let macOS = box.staged.appendingPathComponent("Contents/MacOS")
    try FileManager.default.moveItem(at: macOS, to: elsewhere)
    try FileManager.default.createSymbolicLink(at: macOS, withDestinationURL: elsewhere)
    var checks = 0

    #expect(throws: UpdateInstaller.Failure.stranded(previous: box.work.appendingPathComponent("previous.app").path,
                                                     disabled: false, target: box.target.path)) {
        try box.swapIn(verify: { _ in checks += 1; return checks == 1 }, exchange: swapsOnlyOnce())
    }
    let file = elsewhere.appendingPathComponent("systat").path
    #expect((try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? Int == 0o755)
}

@Test func aStrandedSwapWithTheOldAppGoneNamesNoPath() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    var checks = 0, exchanges = 0

    #expect(throws: UpdateInstaller.Failure.stranded(previous: nil, disabled: true, target: box.target.path)) {
        try box.swapIn(verify: { _ in checks += 1; return checks == 1 }, exchange: { a, b in
            exchanges += 1
            if exchanges == 1 { return UpdateInstaller.exchange(a, b) }
            try? FileManager.default.removeItem(at: a)
            return EIO
        })
    }
}

@Test func theHelperNamesNoPreviousVersionThatIsGone() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let exact = try box.exact(box.target)
    try box.makeApp(at: box.target, version: "0.2.1")   // changed, and no old app where the swap left it

    try box.relaunch(requirement: exact)

    #expect(box.resultText?.hasPrefix("failed: ") == true)
    #expect(box.resultText?.contains(box.staged.path) == false)
    #expect(box.resultText?.contains("previous version is gone") == true)
}

@Test func anAppOthersCanWriteIntoIsNotSwappedOut() throws {
    // They could plant a folder of their own in it, which this user could then never remove.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: box.target.appendingPathComponent("Contents").path)

    #expect(throws: UpdateInstaller.Failure.openInside) { try box.swapIn(verify: { _ in true }) }
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func theMarkNamesTheSlotAndTheBuild() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeOldAndNew()
    let exact = try box.exact(box.staged)

    try UpdateInstaller.swapIn(box.staged, at: box.target, work: box.work, exact: exact, base: box.base, verify: { _ in true })

    let mark = try String(contentsOf: box.work.appendingPathComponent(UpdateInstaller.swapMark), encoding: .utf8)
    #expect(mark == box.target.path + "\n" + exact + "\n" + box.base)
}

/// A run folder as a swap leaves it, aged past pruning, in `box.root/runs`; the old app is `kept`
/// (systat.app, or previous.app when the swap renamed it).
private func markedRun(_ box: Box, app version: String?, target: URL, exact: String,
                       kept: String = "systat.app") throws -> URL {
    let run = box.root.appendingPathComponent("runs/run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    if let version { try box.makeApp(at: run.appendingPathComponent(kept), version: version) }
    try [target.path, exact, box.base].joined(separator: "\n")
        .write(to: run.appendingPathComponent(UpdateInstaller.swapMark), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: run.path)
    return run
}

private func prune(_ box: Box) {
    UpdateInstaller.pruneStaleRuns(in: box.root.appendingPathComponent("runs"), olderThan: Date().addingTimeInterval(-86_400))
}

@Test func pruningRemovesAMarkedRunWhoseSwapFinished() throws {
    // The pinned build is in place, so the old app in the run is a leftover, not the only copy.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let run = try markedRun(box, app: "0.1.0", target: box.target, exact: try box.exact(box.target))

    prune(box)

    #expect(!FileManager.default.fileExists(atPath: run.path))
}

@Test func pruningRemovesAMarkedRunThatNeverSwapped() throws {
    // It died between the mark and the exchange: the run holds only the new build. The slot holds
    // one that can't start, so that alone isn't why it goes.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                          ofItemAtPath: box.target.appendingPathComponent("Contents/MacOS/systat").path)
    let marked = try markedRun(box, app: "0.2.0", target: box.target, exact: "")
    try [box.target.path, try box.exact(marked.appendingPathComponent("systat.app")), box.base].joined(separator: "\n")
        .write(to: marked.appendingPathComponent(UpdateInstaller.swapMark), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: marked.path)

    prune(box)

    #expect(!FileManager.default.fileExists(atPath: marked.path))
    #expect(box.version(at: box.target) == "0.1.0")
}

@Test func pruningRemovesAMarkedRunWithNoAppLeft() throws {
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.1.0")
    let run = try markedRun(box, app: nil, target: box.target, exact: "never")

    prune(box)

    #expect(!FileManager.default.fileExists(atPath: run.path))
}

@Test func pruningKeepsAMarkedRunThatMayHoldTheOnlyCopy() throws {
    // The swap couldn't be put right, and what's in place doesn't verify: the old app in the run
    // may be the only working systat.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.staged, version: "0.2.0")
    let exact = try box.exact(box.staged)
    try box.makeApp(at: box.target, version: "0.2.1")
    try Data("x".utf8).write(to: box.target.appendingPathComponent("Contents/MacOS/extra"))
    let run = try markedRun(box, app: "0.1.0", target: box.target, exact: exact)

    prune(box)

    #expect(box.version(at: run.appendingPathComponent("systat.app")) == "0.1.0")
}

@Test(arguments: [0, 0o644]) func pruningKeepsAMarkedRunWhileTheAppInPlaceCantStart(mode: Int) throws {
    // 0 is how a swap that couldn't be put right leaves it. 0o644 still verifies (permissions
    // aren't sealed), so only whether it can start tells it apart from a working copy.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.target, version: "0.2.0")
    let exact = try box.exact(box.target)
    try FileManager.default.setAttributes([.posixPermissions: mode],
                                          ofItemAtPath: box.target.appendingPathComponent("Contents/MacOS/systat").path)
    let run = try markedRun(box, app: "0.1.0", target: box.target, exact: exact, kept: "previous.app")

    prune(box)

    #expect(box.version(at: run.appendingPathComponent("previous.app")) == "0.1.0")
}

@Test func pruningRemovesAMarkedRunOnceAWorkingSystatIsInPlace() throws {
    // The helper wouldn't open the new version, then the installer (or a later update) put a good
    // one in: the old app kept back then is no longer needed.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.staged, version: "0.2.0")
    let exact = try box.exact(box.staged)
    try box.makeApp(at: box.target, version: "0.2.1")
    let run = try markedRun(box, app: "0.1.0", target: box.target, exact: exact)
    let previous = try markedRun(box, app: "0.1.0", target: box.target, exact: exact, kept: "previous.app")

    prune(box)

    #expect(!FileManager.default.fileExists(atPath: run.path))
    #expect(!FileManager.default.fileExists(atPath: previous.path))
}

@Test func pruningKeepsARunWhoseMarkCantBeOpened() throws {
    // The same run with its mark readable would go: a working systat is in place.
    let box = try Box()
    defer { box.cleanUp() }
    try box.makeApp(at: box.staged, version: "0.2.0")
    let exact = try box.exact(box.staged)
    try box.makeApp(at: box.target, version: "0.2.1")
    let run = try markedRun(box, app: "0.1.0", target: box.target, exact: exact)
    let mark = run.appendingPathComponent(UpdateInstaller.swapMark)
    try #require(FileManager.default.fileExists(atPath: mark.path))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: mark.path)

    prune(box)

    #expect(FileManager.default.fileExists(atPath: run.path))
}

@Test func pruningNeverFollowsARunThatIsALink() throws {
    // Removing it would unmount whatever is mounted at <where it points>/mount.
    let box = try Box()
    defer { box.cleanUp() }
    let elsewhere = box.root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("update"), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: elsewhere.path)
    try FileManager.default.createDirectory(at: box.root.appendingPathComponent("runs"), withIntermediateDirectories: true)
    let link = box.root.appendingPathComponent("runs/run-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
    // The link itself old too, so age alone doesn't keep it.
    var old = [timeval(tv_sec: time(nil) - 3 * 86_400, tv_usec: 0), timeval(tv_sec: time(nil) - 3 * 86_400, tv_usec: 0)]
    try #require(lutimes(link.path, &old) == 0)

    prune(box)

    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "left alone, not followed")
    #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("update").path))
}

@Test func aToolThisProcessStartsGetsNoStrayFile() throws {
    // Why the helper's pipe can be made close-on-exec after it's created: nothing else this process
    // starts would inherit it in between (Foundation's Process closes every other file).
    var ends: [Int32] = [0, 0]
    try #require(pipe(&ends) == 0)
    defer { close(ends[0]); close(ends[1]) }

    // lsof exits 0 either way: whether the child has it open is in what it prints.
    let check = "[ -z \"$(/usr/sbin/lsof -p $$ -a -d \(ends[1]) -F f | /usr/bin/grep -x f\(ends[1]))\" ]"
    #expect(UpdateInstaller.run("/bin/sh", ["-c", check]))
    // And the check itself sees a file the child does have: its stdin.
    #expect(!UpdateInstaller.run("/bin/sh", ["-c", "[ -z \"$(/usr/sbin/lsof -p $$ -a -d 0 -F f | /usr/bin/grep -x f0)\" ]"]))
}

@Test(.timeLimit(.minutes(1))) func aToolThatHangsIsStopped() {
    let start = Date()

    #expect(!UpdateInstaller.run("/bin/sleep", ["30"], timeout: 0.5))
    #expect(Date().timeIntervalSince(start) < 10)
}
