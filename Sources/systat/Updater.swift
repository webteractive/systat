import AppKit
import Observation
import SystatCore

/// Checks GitHub for a newer release once a day (unless turned off in Settings) and installs it
/// when the user clicks Update. One request a day; nothing else touches the network.
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
    /// Why the last swap failed, from the helper's result file; shown with the next offer.
    @ObservationIgnored private var lastFailure: String?

    private static let automaticKey = "checkForUpdates"
    /// Not at launch itself: login is busy enough.
    private static let firstCheckDelay: Duration = .seconds(60)
    private static let interval: Duration = .seconds(24 * 60 * 60)

    init(currentVersion: String, state: State = .idle) {
        self.currentVersion = currentVersion
        self.state = state
        checksAutomatically = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    func start() {
        if let result = UpdateInstaller.takeLastResult(), result.hasPrefix("failed: ") {
            lastFailure = String(result.dropFirst("failed: ".count))
        }
        schedule()
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
        do throws(UpdateInstaller.Failure) {
            if let update = try await UpdateInstaller.latest(currentVersion: currentVersion) {
                if let failure = lastFailure {
                    lastFailure = nil
                    state = .installFailed(update, failure)
                } else {
                    state = .available(update)
                }
            } else {
                lastFailure = nil
                state = .upToDate
            }
        } catch {
            state = quietly ? before : .checkFailed(error.description)
        }
    }

    func install() {
        guard let update = offered else { return }
        guard update.isInstallable else { return openReleasePage() }
        state = .installing(update)
        Task {
            do throws(UpdateInstaller.Failure) {
                let staged = try await UpdateInstaller.stage(update)
                try UpdateInstaller.handOff(staged, appPID: getpid())
                NSApp.terminate(nil)
            } catch {
                state = .installFailed(update, error.description)
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(offered?.releasePage ?? UpdateCheck.releasesPage)
    }
}

/// `systat --check-update` and `systat --update`: the panel's offer and Update, from a terminal.
@MainActor enum UpdateCommand {
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

    /// Stages first, so a failed download leaves the running app alone, then quits it and lets
    /// the helper swap and relaunch.
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
            let staged = try await UpdateInstaller.stage(update)
            let quit = runningCopies(of: staged.target)
            guard await quitAll(quit) else {
                staged.discard()
                fail("systat is still running and did not quit; nothing was changed")
                return 1
            }
            do {
                try UpdateInstaller.handOff(staged, appPID: getpid())
            } catch {
                // It was quit for nothing: open it again before reporting.
                if !quit.isEmpty { NSWorkspace.shared.open(staged.target) }
                throw error
            }
            print("Installing systat \(update.version) to \(staged.target.path); it opens in a moment")
            return 0
        } catch {
            fail(error.description)
            return 1
        }
    }

    /// Only the copy being replaced: another install of systat elsewhere keeps running.
    private static func runningCopies(of target: URL) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }
    }

    private static func quitAll(_ others: [NSRunningApplication]) async -> Bool {
        others.forEach { $0.terminate() }
        for _ in 0..<50 where others.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return others.allSatisfy(\.isTerminated)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("systat: \(message)\n".utf8))
    }
}
