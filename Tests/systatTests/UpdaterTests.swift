import Foundation
import Testing
@testable import systat
@testable import SystatCore

/// Installable, so Update stages it (through the stub) rather than opening the release page.
private let offer = AvailableUpdate(
    version: "0.2.0", releasePage: UpdateCheck.releasesPage,
    dmg: URL(string: "https://github.com/webteractive/systat/releases/download/v0.2.0/systat-0.2.0.dmg"),
    checksum: URL(string: "https://github.com/webteractive/systat/releases/download/v0.2.0/systat-0.2.0.dmg.sha256"))

/// The helper reports a failure after systat has quit, and the next launch is often the new
/// version, which is up to date: the failure must show at launch, whatever the state.
@MainActor @Test func aFailureTheHelperLeftIsShownAtLaunch() async {
    let updater = Updater(currentVersion: "0.1.2", latest: { _ in nil })

    updater.show(lastResult: "failed: The new version had changed.")
    await updater.check()

    #expect(updater.lastUpdateProblem == "The new version had changed.")
    #expect(updater.state == .upToDate)
}

@MainActor @Test func aLaterOfferIsntBlamedForTheLastUpdatesFailure() async {
    // The failure was the version installed then; the one offered now was never tried.
    let updater = Updater(currentVersion: "0.1.2", latest: { _ in offer })

    updater.show(lastResult: "failed: The new version had changed.")
    await updater.check()

    #expect(updater.state == .available(offer))
    #expect(updater.lastUpdateProblem == "The new version had changed.")
}

@MainActor @Test func aResultThatIsntAFailureShowsNothing() {
    let updater = Updater(currentVersion: "0.1.2")

    updater.show(lastResult: "installed 0.1.2")
    updater.show(lastResult: nil)

    #expect(updater.lastUpdateProblem == nil)
    #expect(updater.state == .idle)
}

/// Opened once, from any task; waiting after that returns at once.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume() } else { waiting.append(continuation); lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

@MainActor @Test func aCheckThatReturnsDuringAnInstallLeavesItAlone() async throws {
    // The daily check was waiting on GitHub when Update was clicked: it got past the guard at its
    // start, and returns only once the install has begun.
    let asked = Gate(), answer = Gate(), installed = Gate()
    let updater = Updater(currentVersion: "0.1.2", state: .available(offer),
                          latest: { _ in
                              asked.open()
                              await answer.wait()
                              return offer
                          },
                          perform: { _ throws(UpdateInstaller.Failure) in
                              await installed.wait()
                              throw .download
                          })
    #expect(offer.isInstallable)

    let checking = Task { await updater.check(quietly: true) }
    await asked.wait()
    updater.install()
    answer.open()
    await checking.value

    #expect(updater.state == .installing(offer), "the panel doesn't offer the update again mid-install")
    installed.open()
}

/// Counts calls, from any task.
private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor @Test func aSecondUpdateClickWhileOneIsUnderWayDoesNothing() async throws {
    // It would hit the lock and say the update failed while the first one runs on.
    let installed = Gate(), calls = Count()
    let updater = Updater(currentVersion: "0.1.2", state: .available(offer), latest: { _ in nil },
                          perform: { _ throws(UpdateInstaller.Failure) in
                              if calls.next() > 1 { throw .busy }
                              await installed.wait()
                              throw .download
                          })
    updater.install()
    updater.install()
    // Until the first has started (up to 10 s: a busy machine can be slow to run it). The second
    // click returned at once, as it found one under way: had it started another, that would have
    // been asked for before it returned.
    for _ in 0..<1000 where calls.value < 1 { try await Task.sleep(for: .milliseconds(10)) }

    #expect(updater.state == .installing(offer))
    #expect(calls.value == 1)
    installed.open()
}

@MainActor @Test(arguments: [false, true])
func aCheckThatReturnsAfterAFailedInstallLeavesTheFailureShown(checkFails: Bool) async throws {
    // The daily check was waiting on GitHub when Update was clicked and failed at once.
    let asked = Gate(), answer = Gate()
    let updater = Updater(currentVersion: "0.1.2", state: .available(offer),
                          latest: { _ throws(UpdateInstaller.Failure) in
                              asked.open()
                              await answer.wait()
                              if checkFails { throw .check }
                              return offer
                          },
                          perform: { _ throws(UpdateInstaller.Failure) in throw .busy })

    let checking = Task { await updater.check(quietly: true) }
    await asked.wait()
    updater.install()
    // Up to 10 s: a loaded machine can be slow to get there; it breaks out as soon as it is.
    for _ in 0..<1000 {
        if case .installFailed = updater.state { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    answer.open()
    await checking.value

    #expect(updater.state == .installFailed(offer, UpdateInstaller.Failure.busy.description))
}

@MainActor @Test func aStrandedUpdateIsKeptAsANote() async throws {
    // Where the previous version is must outlast the next check. Update comes back with that check:
    // another update can replace the disabled copy.
    let stranded = UpdateInstaller.Failure.stranded(previous: "/x/previous.app", disabled: true,
                                                    target: "/Applications/systat.app")
    let updater = Updater(currentVersion: "0.1.2", state: .available(offer),
                          latest: { _ in offer },
                          perform: { _ throws(UpdateInstaller.Failure) in throw stranded })

    updater.install()
    for _ in 0..<1000 {
        if case .installing = updater.state {} else { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(updater.lastUpdateProblem == stranded.description)
    #expect(updater.offered == nil, "not offered again straight away, while the note says to use the installer")

    await updater.check()

    #expect(updater.lastUpdateProblem == stranded.description)
    #expect(updater.offered == offer)
}

@Test func aReleaseAnswerTooLargeIsABadReleaseNotTheNetwork() async {
    let large = AsyncStream<UInt8> { c in
        for _ in 0..<11 { c.yield(0x20) }
        c.finish()
    }
    await #expect(throws: UpdateInstaller.Failure.badRelease) {
        try await UpdateInstaller.readRelease(large, limit: 10)
    }
    struct Dropped: Error {}
    let dropped = AsyncThrowingStream<UInt8, Error> { $0.finish(throwing: Dropped()) }
    await #expect(throws: UpdateInstaller.Failure.check) {
        try await UpdateInstaller.readRelease(dropped, limit: 10)
    }
}

@MainActor @Test func anUpdateRefusedAtOnceKeepsTheEarlierNote() async throws {
    // Refused before it began (another update running, say): the last update's problem still stands.
    let updater = Updater(currentVersion: "0.1.2", state: .available(offer),
                          perform: { _ throws(UpdateInstaller.Failure) in throw .busy })
    updater.show(lastResult: "failed: earlier")

    updater.install()
    // Up to 10 s: a loaded machine can be slow to get there; it breaks out as soon as it is.
    for _ in 0..<1000 {
        if case .installFailed = updater.state { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(updater.state == .installFailed(offer, UpdateInstaller.Failure.busy.description))
    #expect(updater.lastUpdateProblem == "earlier")
}

@MainActor @Test func aNoteIsDismissedForGood() {
    var forgotten = 0
    let updater = Updater(currentVersion: "0.1.2", forget: { forgotten += 1 })
    updater.show(lastResult: "failed: why")

    updater.dismissProblem()

    #expect(updater.lastUpdateProblem == nil)
    #expect(forgotten == 1, "the note's file goes too, or the next launch shows it again")
}

@Test func gitHubsAnswerIsNamedForWhatWentWrong() {
    #expect(throws: UpdateInstaller.Failure.rateLimited) {
        try UpdateInstaller.release(status: 403, body: Data(), currentVersion: "0.1.0")
    }
    #expect(throws: UpdateInstaller.Failure.rateLimited) {
        try UpdateInstaller.release(status: 429, body: Data(), currentVersion: "0.1.0")
    }
    #expect(throws: UpdateInstaller.Failure.badRelease) {
        try UpdateInstaller.release(status: 200, body: Data("not json".utf8), currentVersion: "0.1.0")
    }
    #expect(throws: UpdateInstaller.Failure.check) {
        try UpdateInstaller.release(status: 502, body: Data(), currentVersion: "0.1.0")
    }
    // GitHub was reached: it has no release to give.
    #expect(throws: UpdateInstaller.Failure.noRelease) {
        try UpdateInstaller.release(status: 404, body: Data(), currentVersion: "0.1.0")
    }
}

@MainActor @Test func systatUpdateSaysWhetherSystatWillOpen() {
    #expect(UpdateCommand.installedLine("0.2.0", at: "/A/systat.app", reopening: false, told: true)
        == "Installed systat 0.2.0 to /A/systat.app")
    #expect(UpdateCommand.installedLine("0.2.0", at: "/A/systat.app", reopening: true, told: true)
        == "Installed systat 0.2.0 to /A/systat.app; it opens in a moment")
    // The helper was gone before it could be told: nothing will open it.
    #expect(UpdateCommand.installedLine("0.2.0", at: "/A/systat.app", reopening: true, told: false)
        == "Installed systat 0.2.0 to /A/systat.app; open it yourself, as nothing will reopen it")
}

@MainActor @Test func theStillRunningMessageMentionsCopiesQuitOnlyIfAnyDid() {
    #expect(!UpdateCommand.stillRunningMessage(quitAny: false).contains("quit meanwhile"))
    #expect(UpdateCommand.stillRunningMessage(quitAny: true).contains("weren't opened again"))
}

@Test(.timeLimit(.minutes(1))) func aStoppedUpdateEndsAToolThatIsStillChecking() async {
    // Ctrl-C while spctl or codesign checks the update (spctl can take up to two minutes): the tool is
    // ended rather than waited for, so the stop takes effect at once.
    // Timed from the call, not from asking for the task: a busy machine may be slow to start it.
    let task = Task.detached { () -> (Bool, Duration) in
        withUnsafeCurrentTask { $0?.cancel() }
        let started = ContinuousClock.now
        let succeeded = UpdateInstaller.run("/bin/sleep", ["30"], stopsWhenCancelled: true)
        return (succeeded, ContinuousClock.now - started)
    }
    let (succeeded, took) = await task.value
    #expect(!succeeded)
    #expect(took < .seconds(5))
}

@Test func aStoppedUpdateGoesNoFurtherThanTheStepItIsOn() async {
    let task = Task.detached { () -> UpdateInstaller.Failure? in
        withUnsafeCurrentTask { $0?.cancel() }
        do throws(UpdateInstaller.Failure) {
            try UpdateInstaller.stopIfCancelled()
            return nil
        } catch { return error }
    }
    #expect(await task.value == .interrupted)
    // Not stopped: it carries on.
    #expect(throws: Never.self) { try UpdateInstaller.stopIfCancelled() }
}

/// A signal's handler, read without changing it (setting one to read it back would briefly let it
/// through for the whole test process).
private func handler(_ sig: Int32) -> Int {
    var current = sigaction()
    sigaction(sig, nil, &current)
    return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
}

// These change and read the process-wide signal handlers, and one signals the whole process: one
// at a time, never alongside each other.
@MainActor @Suite(.serialized) struct SignalHandling {
    @Test func ctrlCDuringTheDownloadStopsItAndLeavesNothing() async throws {
        // systat --update before it quits anything: Ctrl-C cancels the download, and whatever was staged
        // anyway is thrown away (stage removes its run folder when it fails), so nothing is left behind.
        let signals = [SIGINT, SIGQUIT, SIGHUP, SIGTERM]
        let before = signals.map { signal($0, SIG_DFL) }
        defer { for (sig, old) in zip(signals, before) { signal(sig, old) } }
        let started = Gate(), discarded = Count()
        // A second Ctrl-C while what was staged is removed mustn't end it halfway.
        var ignoredWhileDiscarding = false
        let stopped = Task { @MainActor () -> UpdateInstaller.Failure? in
            do throws(UpdateInstaller.Failure) {
                _ = try await UpdateCommand.untilInterrupted(discard: { (_: Int) in
                    _ = discarded.next()
                    ignoredWhileDiscarding = handler(SIGINT) == unsafeBitCast(SIG_IGN, to: Int.self)
                }) {
                    () async throws(UpdateInstaller.Failure) -> Int in
                    started.open()
                    // Bounded: a Ctrl-C it missed then fails the test (it returns, not stopped)
                    // rather than hanging the run, which a time limit couldn't end.
                    for _ in 0..<500 where !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    return 1
                }
                return nil
            } catch {
                return error
            }
        }
        await started.wait()
        // To the process, as a terminal's Ctrl-C is (raise would aim it at this thread, which may block it).
        kill(getpid(), SIGINT)
        #expect(await stopped.value == .interrupted)
        #expect(discarded.value == 1)
        #expect(ignoredWhileDiscarding)
        // Put back once stopped: a caller that runs on gets Ctrl-C as before.
        let byDefault: Int = unsafeBitCast(SIG_DFL, to: Int.self)
        for sig in signals { #expect(handler(sig) == byDefault) }
    }

    @Test func aFinishedDownloadLeavesCtrlCIgnoredForWhatFollows() async throws {
        // Once staged, systat --update goes on to quit the running copy: a Ctrl-C there (before it ignores
        // the rest) mustn't kill it with the staged run folder left behind.
        let signals = [SIGINT, SIGQUIT, SIGHUP, SIGTERM]
        let before = signals.map { signal($0, SIG_DFL) }
        defer { for (sig, old) in zip(signals, before) { signal(sig, old) } }
        let value = try await UpdateCommand.untilInterrupted(discard: { (_: Int) in }) {
            () async throws(UpdateInstaller.Failure) -> Int in 7
        }
        #expect(value == 7)
        let ignored: Int = unsafeBitCast(SIG_IGN, to: Int.self)
        for sig in signals { #expect(handler(sig) == ignored) }
    }

    @Test func aFailedDownloadPutsCtrlCBack() async {
        let signals = [SIGINT, SIGQUIT, SIGHUP, SIGTERM]
        let before = signals.map { signal($0, SIG_DFL) }
        defer { for (sig, old) in zip(signals, before) { signal(sig, old) } }
        await #expect(throws: UpdateInstaller.Failure.download) {
            _ = try await UpdateCommand.untilInterrupted(discard: { (_: Int) in }) {
                () async throws(UpdateInstaller.Failure) -> Int in throw .download
            }
        }
        let byDefault: Int = unsafeBitCast(SIG_DFL, to: Int.self)
        for sig in signals { #expect(handler(sig) == byDefault) }
    }

    @Test func ctrlCAndTheRestAreIgnoredOnceTheUpdateCantBeStopped() {
        // systat --update: from quitting the running copy on, Ctrl-C, Ctrl-\, closing the terminal, a kill
        // or a broken pipe would leave systat quit and not reopened. (The app never puts them back, as it
        // exits; the test does, to leave the test process as it found it.)
        let (int, hup, quit, term, stop) = (handler(SIGINT), handler(SIGHUP), handler(SIGQUIT), handler(SIGTERM), handler(SIGTSTP))
        let (ttou, ttin, pipe) = (handler(SIGTTOU), handler(SIGTTIN), handler(SIGPIPE))

        let restore = UpdateCommand.ignoreInterruptions()
        let ignored: Int = unsafeBitCast(SIG_IGN, to: Int.self)
        #expect(handler(SIGINT) == ignored)
        #expect(handler(SIGHUP) == ignored)
        #expect(handler(SIGQUIT) == ignored)
        #expect(handler(SIGTERM) == ignored)
        #expect(handler(SIGTSTP) == ignored, "Ctrl-Z would hold systat quit until it was resumed")
        #expect(handler(SIGTTOU) == ignored, "a background job writing to the terminal would be stopped")
        #expect(handler(SIGTTIN) == ignored)
        #expect(handler(SIGPIPE) == ignored, "output piped to a reader that went away")
        restore()

        #expect(handler(SIGINT) == int, "put back by the function returned")
        #expect(handler(SIGHUP) == hup)
        #expect(handler(SIGQUIT) == quit)
        #expect(handler(SIGTERM) == term)
        #expect(handler(SIGTSTP) == stop)
        #expect(handler(SIGTTOU) == ttou)
        #expect(handler(SIGTTIN) == ttin)
        #expect(handler(SIGPIPE) == pipe)
    }
}

@Test func theUpdaterKeepsItsStateInTheAccountsHomeFolderAsTheInstallerLooksForIt() throws {
    // From the account (getpwuid), as install.sh's account_home takes it: not a CFFIXED_USER_HOME a
    // shell exports (which Foundation's homeDirectoryForCurrentUser would follow, and the installer
    // doesn't), so a terminal's systat --update and the installer find each other's locks.
    let entry = try #require(getpwuid(getuid()))
    let home = String(cString: entry.pointee.pw_dir)
    #expect(UpdateInstaller.accountHome.path == home)
    #expect(UpdateInstaller.stateDirectory.path == home + "/Library/Application Support/systat-update")
}
