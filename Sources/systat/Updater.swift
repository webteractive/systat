import AppKit
import Observation
import SystatCore

/// Checks GitHub for a newer release once a day (unless turned off in Settings) and installs it
/// when the user clicks Update. One request a day; only an update the user starts downloads more.
@MainActor @Observable final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case checkFailed(String)
        case available(AvailableUpdate)
        case installing(AvailableUpdate)
        case installFailed(AvailableUpdate, String)
    }

    private(set) var state: State = .idle
    /// What went wrong after systat last quit to update, from the helper's result file, or an update
    /// that left the previous version aside: shown whatever the state, until it is dismissed or the
    /// next update swaps in.
    private(set) var lastUpdateProblem: String?
    let currentVersion: String

    var checksAutomatically: Bool {
        didSet {
            UserDefaults.standard.set(checksAutomatically, forKey: Self.automaticKey)
            schedule()
        }
    }

    /// The update the panel offers, if any.
    var offered: AvailableUpdate? {
        switch state {
        case .available(let u), .installing(let u), .installFailed(let u, _): u
        default: nil
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let latest: Latest
    @ObservationIgnored private let perform: Perform
    @ObservationIgnored private let forget: @MainActor () -> Void

    /// Asks GitHub for a release newer than the given version.
    typealias Latest = @Sendable (String) async throws(UpdateInstaller.Failure) -> AvailableUpdate?
    /// Stages the update and swaps it in; systat quits once it returns.
    typealias Perform = @Sendable (AvailableUpdate) async throws(UpdateInstaller.Failure) -> Void

    private static let automaticKey = "checkForUpdates"
    /// Not at launch itself: login is busy enough.
    private static let firstCheckDelay: Duration = .seconds(60)
    private static let interval: Duration = .seconds(24 * 60 * 60)

    init(currentVersion: String, state: State = .idle,
         latest: @escaping Latest = { try await UpdateInstaller.latest(currentVersion: $0) },
         perform: @escaping Perform = { update throws(UpdateInstaller.Failure) in
             let staged = try await UpdateInstaller.stage(update)
             try UpdateInstaller.install(staged, appPID: getpid(), reopen: true)
         },
         forget: @escaping @MainActor () -> Void = { UpdateInstaller.clearLastResult() }) {
        self.currentVersion = currentVersion
        self.forget = forget
        self.state = state
        self.latest = latest
        self.perform = perform
        checksAutomatically = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    func start() {
        show(lastResult: UpdateInstaller.lastResult())
        schedule()
    }

    func show(lastResult: String?) {
        guard let result = lastResult, result.hasPrefix("failed: ") else { return }
        lastUpdateProblem = String(result.dropFirst("failed: ".count))
    }

    private func schedule() {
        loop?.cancel()
        guard checksAutomatically else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                await self?.check(quietly: true)
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// A quiet check (the daily one) leaves the state alone when GitHub can't be reached.
    func check(quietly: Bool = false) async {
        if case .installing = state { return }
        let before = state
        if !quietly { state = .checking }
        // Update was clicked while this waited on GitHub: the install, or how it failed, stands.
        let waited = state
        do throws(UpdateInstaller.Failure) {
            let update = try await latest(currentVersion)
            guard state == waited else { return }
            state = update.map { .available($0) } ?? .upToDate
        } catch {
            guard state == waited else { return }
            state = quietly ? before : .checkFailed(error.description)
        }
    }

    func install() {
        // One already under way: a second would hit the lock and say it failed while the first runs on.
        if case .installing = state { return }
        guard let update = offered else { return }
        guard update.isInstallable else { return openReleasePage() }
        // The last update's note stays: one refused at once (another update running, say) doesn't
        // put right what went wrong then. One that swaps in clears its file, and systat quits.
        state = .installing(update)
        Task {
            do throws(UpdateInstaller.Failure) {
                try await perform(update)
                NSApp.terminate(nil)
            } catch {
                if case .stranded = error {
                    // Kept like a note the helper left, so no later check replaces it. Update isn't
                    // offered straight away, while the note says to use the installer; the next
                    // check offers it again, and that update can replace the disabled copy.
                    lastUpdateProblem = error.description
                    state = .idle
                } else {
                    state = .installFailed(update, error.description)
                }
            }
        }
    }

    /// Its file goes too, or the next launch would show it again.
    func dismissProblem() {
        lastUpdateProblem = nil
        forget()
    }

    func openReleasePage() {
        NSWorkspace.shared.open(offered?.releasePage ?? UpdateCheck.releasesPage)
    }
}

/// `systat --check-update` and `systat --update`: the panel's offer and Update, from a terminal.
@MainActor enum UpdateCommand {
    /// Ctrl-C, Ctrl-\, Ctrl-Z, a closed terminal, a plain kill (TERM), a background job's terminal
    /// output or input (TTOU, TTIN) and a broken pipe (output piped to a reader that went away: a
    /// write then fails instead) are ignored, as the installer ignores them: once the running copy
    /// has been quit, stopping (or being held stopped) halfway would leave systat quit and not
    /// reopened. `systat --update` never puts them back, as it exits right after; the function
    /// returned does, for a caller (a test) that runs on.
    static func ignoreInterruptions() -> () -> Void {
        let signals = [SIGINT, SIGHUP, SIGQUIT, SIGTERM, SIGTSTP, SIGTTOU, SIGTTIN, SIGPIPE]
        let before = signals.map { signal($0, SIG_IGN) }
        return {
            for (sig, handler) in zip(signals, before) { signal(sig, handler) }
        }
    }

    /// When a running copy won't quit: whether any other did, which isn't opened again.
    static func stillRunningMessage(quitAny: Bool) -> String {
        "systat is still running and did not quit; nothing was changed"
            + (quitAny ? " (the copies that quit meanwhile weren't opened again, as one still runs)" : "")
    }

    /// Runs `work` (the download and checks) with Ctrl-C, Ctrl-\, a closed terminal and TERM turned
    /// into a stop: the work is cancelled (a download stops, and staging removes its run folder when it
    /// fails), and whatever it returned anyway is thrown away with `discard`. So a stopped update leaves
    /// nothing behind, rather than its run folder, or an image still attached, until a later update.
    /// When the work succeeds they stay ignored: the caller goes on to quit the running copy, and a
    /// Ctrl-C there would end it with the staged update left behind. Otherwise they are put back.
    static func untilInterrupted<T: Sendable>(
        discard: @escaping (T) -> Void,
        _ work: @escaping @Sendable () async throws(UpdateInstaller.Failure) -> T
    ) async throws(UpdateInstaller.Failure) -> T {
        let signals = [SIGINT, SIGQUIT, SIGHUP, SIGTERM]
        let stopped = StopFlag()
        // Watched before they are ignored, so none is lost in between; one that comes before that
        // ends the process, with nothing staged yet.
        let sources = signals.map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            // @Sendable: it runs on a dispatch queue, not the main actor this function's closures
            // would otherwise inherit (and be checked against, at run time).
            source.setEventHandler { @Sendable in stopped.raise() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }
        let before = signals.map { signal($0, SIG_IGN) }
        let task = Task { () async throws -> T in try await work() }
        // Cancelled at once if a signal was caught already.
        stopped.onRaise { task.cancel() }
        let result = await task.result
        // Read once: a signal caught after this neither leaves them ignored nor turns it into a stop.
        let interrupted = stopped.isRaised
        // Thrown away while they are still ignored: a second Ctrl-C mustn't end it halfway through.
        if interrupted, case .success(let value) = result { discard(value) }
        if interrupted || result.isFailure {
            for (sig, handler) in zip(signals, before) { signal(sig, handler) }
        }
        if interrupted { throw .interrupted }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw (error as? UpdateInstaller.Failure) ?? .download
        }
    }

    static func installedLine(_ version: String, at target: String, reopening: Bool, told: Bool) -> String {
        "Installed systat \(version) to \(target)"
            + (!reopening ? "" : told ? "; it opens in a moment" : "; open it yourself, as nothing will reopen it")
    }

    static func check() async -> Int32 {
        do throws(UpdateInstaller.Failure) {
            if let update = try await UpdateInstaller.latest(currentVersion: systatVersion) {
                print("systat \(update.version) is available (this is \(systatVersion)): \(update.releasePage.absoluteString)")
            } else {
                print("systat \(systatVersion) is up to date")
            }
            return 0
        } catch {
            fail(error.description)
            return 1
        }
    }

    /// Stages first, so a failed download leaves the running app alone, then quits it, swaps the
    /// new one in and, if it was running, lets the helper open it once this process exits.
    static func run() async -> Int32 {
        do throws(UpdateInstaller.Failure) {
            guard let update = try await UpdateInstaller.latest(currentVersion: systatVersion) else {
                print("systat \(systatVersion) is up to date")
                return 0
            }
            guard update.isInstallable else {
                fail("systat \(update.version) has no installable image; download it from \(update.releasePage.absoluteString)")
                return 1
            }
            print("Downloading systat \(update.version)")
            let staged = try await untilInterrupted(discard: { $0.discard() }) { () async throws(UpdateInstaller.Failure) in
                try await UpdateInstaller.stage(update)
            }
            // Looked for again once those have quit: a copy opened meanwhile (its login item, another
            // update's helper) would have its bundle swapped out from under it.
            var quit: [NSRunningApplication] = []
            var found = runningCopies(of: staged.target)
            // What it is about to quit: if the swap then refuses it, that copy is opened again.
            let quitCopy = UpdateInstaller.QuitCopy(at: staged.target, requirement: staged.requirement)
            // Never put back: the process exits right after, and its last message and output (written
            // out at exit) mustn't meet a Ctrl-C or a broken pipe once the update is done or refused.
            _ = ignoreInterruptions()
            for _ in 0..<3 where !found.isEmpty {
                quit += found
                guard await quitAll(found) else { break }
                found = runningCopies(of: staged.target)
            }
            guard found.isEmpty else {
                staged.discard()
                // Copies it did quit aren't opened again: one of the same app runs on.
                fail(stillRunningMessage(quitAny: quit.contains(where: \.isTerminated)))
                return 1
            }
            let told: Bool
            do {
                told = try UpdateInstaller.install(staged, appPID: getpid(), reopen: !quit.isEmpty)
            } catch {
                // It was quit for nothing: open it again before reporting, unless what's in place
                // now is a new version that failed its check, or isn't the app that was quit, or is
                // no longer the build that was quit; then say so.
                if !quit.isEmpty {
                    switch quitCopy.afterFailure(error, at: staged.target) {
                    case .reopen: NSWorkspace.shared.open(staged.target)
                    case .leave: break
                    case .say(let why): fail(why)
                    }
                }
                throw error
            }
            print(installedLine(update.version, at: staged.target.path, reopening: !quit.isEmpty, told: told))
            return 0
        } catch {
            fail(error.description)
            return 1
        }
    }

    /// Only the copy being replaced, however it was opened (`target` is its real path): another
    /// install of systat elsewhere keeps running.
    private static func runningCopies(of target: URL) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && $0.bundleURL.map(realPath) == target.path }
    }

    private static func realPath(_ url: URL) -> String? {
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    private static func quitAll(_ others: [NSRunningApplication]) async -> Bool {
        others.forEach { $0.terminate() }
        for _ in 0..<50 where others.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return others.allSatisfy(\.isTerminated)
    }

    /// Never raises: with the terminal closed (its hang-up ignored) the write fails, and that mustn't
    /// crash systat after an update has failed.
    private static func fail(_ message: String) {
        fputs("systat: \(message)\n", stderr)
    }
}

/// Raised from a signal handler's queue, read once the work is done.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    private var action: (@Sendable () -> Void)?
    func raise() {
        lock.lock(); raised = true; let run = action; lock.unlock()
        run?()
    }
    /// Run on the next raise, or now if it was raised already.
    func onRaise(_ run: @escaping @Sendable () -> Void) {
        lock.lock(); action = run; let now = raised; lock.unlock()
        if now { run() }
    }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
