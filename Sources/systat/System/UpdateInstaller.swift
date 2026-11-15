import Foundation
import Security
import SystatCore

/// Fetches the latest release, and installs one in place: download, checksum, mount, copy out,
/// signature and Gatekeeper checks, then the app swaps the new bundle in with one rename and quits,
/// and a helper (`RelaunchScript`) opens it once the app has exited.
enum UpdateInstaller {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case check, rateLimited, badRelease, noRelease, notInstallable, notSigned, notAnApp, mustMove, locked, notWritable, cantSwap,
             sharedFolder, sharedLibrary, stateFolder, asRoot, notYours, openInside, unreadable,
             download, tooLarge, checksum, mount, badImage, eject, imageSignature, signature, gatekeeper, wrongVersion, helper, lock, busy, installing, newerInPlace, interrupted,
             moved, changed, blocked, swap, notInPlace, stranded(previous: String?, disabled: Bool, target: String)

        var description: String {
            switch self {
            case .check: "Couldn't reach GitHub to check for updates."
            case .rateLimited: "GitHub is limiting requests from this network; try again later."
            case .badRelease: "GitHub's answer about the latest release couldn't be read."
            case .noRelease: "GitHub has no release of systat to update to."
            case .notInstallable: "This release has no installable image."
            case .notSigned: "This build isn't Developer ID signed, so it can't update itself."
            case .notAnApp: "systat isn't running from an app bundle."
            case .mustMove: "Move systat into Applications, open it from there, then update."
            case .locked: "systat's app, or something in it, is locked (Get Info > Locked, or a flag set with chflags), so it can't be replaced. Clear its flags (chflags -R nouchg,nouappnd on the app, and sudo chflags -R noschg,nosappnd for the system ones), then update."
            case .installing: "The installer is running; wait for it to finish, then update."
            case .notWritable: "systat can't replace itself where it's installed. Use the installer, or move it to a folder you own."
            case .cantSwap: "The disk systat is on can't swap an app in one step, so it won't update itself there. Use the installer, or move it to Applications."
            case .sharedFolder: "Other users can change the folder systat is in, so it won't update itself there. Use the installer, or move it to a folder you own."
            case .sharedLibrary:
                "Your Library folder is on a network volume, or other users can change it, so systat won't update itself. Use the installer."
            case .stateFolder: "systat couldn't set up its update folder in ~/Library/Application Support; nothing was changed."
            case .asRoot: "systat won't update itself as root. Run the update as yourself."
            case .download: "The download failed."
            case .tooLarge: "The download is far larger than systat, so it was refused."
            case .checksum: "The download doesn't match the release checksum."
            case .mount: "The disk image couldn't be opened."
            case .badImage: "The disk image holds no systat app that could be copied out."
            case .eject: "The disk image couldn't be ejected, so the update stopped; nothing was changed."
            case .imageSignature: "The disk image isn't signed by the same developer."
            case .signature: "The new version isn't systat signed by the same developer, or its certificate couldn't be checked."
            case .gatekeeper: "Gatekeeper rejects the new version."
            case .wrongVersion: "The downloaded app isn't the version the release names."
            case .helper: "systat couldn't start the helper that reopens it."
            case .lock: "systat couldn't take its update lock; nothing was changed."
            case .busy: "Another update is in progress."
            case .interrupted: "Stopped; nothing was changed."
            case .newerInPlace: "A newer systat is already in this one's place; quit this one and open that."
            case .moved: "systat was moved, replaced or deleted while the update was being prepared; nothing was changed."
            case .changed: "The downloaded update changed after it was checked, so it wasn't installed; nothing was changed."
            case .blocked:
                "macOS didn't let systat replace itself; nothing was changed. If you ran systat --update in a terminal, allow that terminal in System Settings > Privacy & Security > App Management, or update from the panel."
            case .notYours:
                "Another user owns this copy of systat, or something in it, so it won't update itself: it couldn't remove the old version afterwards. Update it from their account, or delete it and use the installer."
            case .openInside:
                "Other users can change a folder inside systat's app, so it won't update itself. Use the installer, which replaces it with a clean copy."
            case .unreadable:
                "Part of systat's app can't be read, so it can't be checked and won't update itself. Use the installer, which replaces it with a clean copy."
            case .swap: "systat couldn't swap the new version into place; nothing was changed."
            case .notInPlace: "The new version didn't verify once in place, so the old one was put back."
            case .stranded(let previous, let disabled, let target):
                (disabled ? "The update couldn't finish. The new version at \(target) was disabled, and "
                          : "The update couldn't finish; the new version at \(target) may not work, and ")
                    + (previous.map { "the previous one is at \($0)" } ?? "the previous one couldn't be kept")
                    + "; use the installer"
                    + (target == "/Applications/systat.app" ? "." : ", which installs to /Applications, then delete that copy.")
            }
        }

        /// Whether the app that was installed is still there and runnable: true for every failure
        /// but a swap that couldn't be put right, and an app that was moved (whatever is at its path
        /// now isn't what was quit).
        var keptInstalledApp: Bool {
            switch self {
            case .stranded, .moved: false
            default: true
            }
        }

        /// Whether `systat --update` opens again the copy it quit (`quit`, what was at the path then;
        /// `now`, what is there now). An app replaced during the download (`.moved`) was what it
        /// quit, if it's still there: left quit, the user would have no systat running.
        func reopensQuitApp(quit: FileID?, now: FileID?) -> Bool {
            if self == .moved { return quit != nil && quit == now }
            return keptInstalledApp
        }
    }

    /// Lock, result file and (on the same volume as the app) the staging folders live here. Not in
    /// Caches: cleaner apps empty that, and a run folder can hold the only copy of the app.
    static let stateDirectory = accountHome
        .appendingPathComponent("Library/Application Support/systat-update")
    /// Where 0.1.1 kept them. Its helper reports the update to this version there.
    private static let legacyStateDirectory = accountHome
        .appendingPathComponent("Library/Caches/systat-update")
    /// This user's home folder, from their account, as the installer's account_home takes it: not a
    /// CFFIXED_USER_HOME a shell exports, which homeDirectoryForCurrentUser would follow (and the app
    /// started from the Dock never has), or a terminal's systat --update and the installer would look
    /// for each other's locks in different places.
    static let accountHome: URL = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }()
    private static var resultFile: URL { stateDirectory.appendingPathComponent("result") }
    private static var lockFile: URL { stateDirectory.appendingPathComponent("lock") }
    /// The installer's lock, beside the state folder: a flock it holds while it runs.
    private static var installerLock: URL {
        stateDirectory.deletingLastPathComponent().appendingPathComponent("systat-install.lock")
    }
    /// systat's DMG is about 1 MB; anything near this is not it.
    private static let maxImageBytes = 200 << 20
    private static let maxChecksumBytes = 1024
    /// GitHub's answer for one release is a few KB.
    private static let maxReleaseBytes = 1 << 20
    private static let staleRunAge: TimeInterval = 24 * 60 * 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 5 * 60
        return URLSession(configuration: configuration)
    }()

    @concurrent static func latest(currentVersion: String) async throws(Failure) -> AvailableUpdate? {
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let status: Int, bytes: URLSession.AsyncBytes
        do {
            let (answer, response) = try await session.bytes(for: request)
            (status, bytes) = ((response as? HTTPURLResponse)?.statusCode ?? 0, answer)
        } catch {
            throw .check
        }
        let body = status == 200 ? try await readRelease(bytes, limit: maxReleaseBytes) : Data()
        return try release(status: status, body: body, currentVersion: currentVersion)
    }

    /// A body over the limit is no release of systat's, not the network failing.
    static func readRelease<S: AsyncSequence>(_ bytes: S, limit: Int) async throws(Failure) -> Data where S.Element == UInt8 {
        do { return try await CappedRead.data(bytes, limit: limit) } catch is CappedRead.TooLarge {
            throw .badRelease
        } catch {
            throw .check
        }
    }

    /// GitHub's answer, named for what went wrong: its rate limit is not the network being down.
    static func release(status: Int, body: Data, currentVersion: String) throws(Failure) -> AvailableUpdate? {
        switch status {
        case 200: break
        case 403, 429: throw .rateLimited
        case 404: throw .noRelease
        default: throw .check
        }
        do { return try UpdateCheck.evaluate(body, currentVersion: currentVersion) } catch { throw .badRelease }
    }

    /// Written in a run folder before the swap exchanges anything: pruning never removes it after that.
    static let swapMark = "swapped"

    /// Whether what is in the slot stops this update: a systat newer than the one offered, put there by
    /// hand, would be swapped out and then deleted. Compared with the update, not the running copy: a
    /// copy of the update's own version, the one a stranded swap left there disabled, is replaced.
    static func inPlaceBlocks(_ target: URL, update: AvailableUpdate) -> Bool {
        newerInPlace(target, than: update.version)
    }

    /// Whether the app at `target` names a version newer than `running` (one that can't be read isn't).
    static func newerInPlace(_ target: URL, than running: String) -> Bool {
        let plist = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        guard let there = (plist?["CFBundleShortVersionString"] as? String).flatMap(SemVer.init),
              let mine = SemVer(running) else { return false }
        return there > mine
    }

    /// Whether the installer holds its lock: a flock on its lock file, as this updater's is, held while
    /// it runs and gone when it ends, so a file left behind means nothing. Probed with a shared lock,
    /// let go at once; a file that isn't there, or can't be opened, means no installer.
    static func installerIsRunning(_ lock: URL) -> Bool {
        let fd = open(lock.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Held for a moment (the installer probing it, say, or a child it is starting) isn't an
        // install: held still a moment later is.
        for attempt in 0..<2 {
            if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
            guard errno == EWOULDBLOCK else { return false }
            if attempt == 0 { usleep(150_000) }
        }
        return true
    }

    /// Where the last helper leaves its line ("failed: why"; it writes nothing when all went well):
    /// here, or where 0.1.1 kept it. Kept until dismissed, or until the next update swaps in.
    private static var resultFiles: [URL] { [resultFile, legacyStateDirectory.appendingPathComponent("result")] }

    static func lastResult() -> String? { lastResult(from: resultFiles) }
    static func clearLastResult() { clearLastResult(resultFiles) }

    /// The first of `files` that holds a line, as plain text.
    static func lastResult(from files: [URL]) -> String? {
        files.lazy.compactMap { readSmallFile($0).map(plainText)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// A path in a note can hold anything a file name can: control characters (C0 and C1) and
    /// format ones (which reverse how the rest of the line reads, or hide) go; a tab, line break or
    /// line or paragraph separator becomes a space. What wasn't UTF-8 (a note cut short
    /// mid-character, say) goes too, as the installer leaves it out.
    private static func plainText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control: if scalar == "\t" || scalar == "\n" || scalar == "\r" { scalars.append(" ") }
            case .lineSeparator, .paragraphSeparator: scalars.append(" ")
            case .format: break
            default: if scalar != "\u{FFFD}" { scalars.append(scalar) }
            }
        }
        return String(scalars)
    }

    static func clearLastResult(_ files: [URL]) { files.forEach { unlink($0.path) } }

    /// A helper that wasn't told the swap is in reopens nothing: worth a note only if it was to.
    static func noteIfUnopened(told: Bool, reopening: Bool, target: URL, in resultFile: URL) {
        if !told, reopening { try? noteUnopened(target, in: resultFile) }
    }

    /// For a helper that was gone by the time the swap went in: nothing will reopen the new version.
    static func noteUnopened(_ target: URL, in resultFile: URL) throws {
        try note("The new version is installed, but systat couldn't reopen it. Open \(target.path).", in: resultFile)
    }

    /// Written in place of whatever is there, never through a link left at that path.
    private static func note(_ problem: String, in resultFile: URL) throws {
        unlink(resultFile.path)
        let fd = open(resultFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let line = Data("failed: \(problem)\n".utf8)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Up to 4 KB of a regular file this user owns, read without following a link or waiting on a
    /// pipe: it is read at launch, on the main thread.
    private static func readSmallFile(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        guard count >= 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }

    /// Clears out a state folder no longer used: its stale runs (a kept app stays) and lock, and the
    /// folder itself once nothing is left in it (its result goes when the note is dismissed or the next
    /// update goes in). Only a real folder of this user's
    /// that no one else can change: anything else isn't one systat made.
    static func retire(_ folder: URL) {
        guard isOwnFolder(folder, closedTo: 0), FolderTrust.onlyTrustedCanChange(folder) else { return }
        pruneStaleRuns(in: folder, olderThan: Date().addingTimeInterval(-staleRunAge))
        // Its result stays until the note is dismissed: an update starting doesn't mean it was read.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("lock"))
        rmdir(folder.path)
    }

    /// One update at a time for this user, from the start of staging until the process drops its
    /// staged update, or, once its swap is in, until both it has exited and the relaunch helper (which
    /// inherits it as descriptor 3) has checked and opened the new version: a `flock` on the lock file,
    /// which the kernel drops once no holder is left.
    final class Lock: Sendable {
        private let fd: Int32

        static func take(_ file: URL) throws(Failure) -> Lock {
            let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw .lock }
            // Private: another user who could open it could hold it, and stop every update. Its mode
            // and any ACL it carried or inherited, whatever an earlier run left.
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o600) == 0,
                  let empty = acl_init(0) else {
                close(fd)
                throw .lock
            }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            guard acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0 else {
                close(fd)
                throw .lock
            }
            // Only a lock another holds means another update; any other failure is the lock's. Held
            // for a moment (the installer probing it, say) isn't: tried again for half a second.
            for attempt in 0..<6 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return Lock(fd) }
                let busy = errno == EWOULDBLOCK
                guard busy, attempt < 5 else {
                    close(fd)
                    throw busy ? .busy : .lock
                }
                usleep(100_000)
            }
            close(fd)
            throw .busy
        }

        private init(_ fd: Int32) { self.fd = fd }
        /// The open lock file, for the relaunch helper to inherit: the lock lasts while any copy of it is open.
        var descriptor: Int32 { fd }
        deinit { close(fd) }

        /// Never released: the kernel drops it when the process exits.
        func keepUntilExit() { _ = Unmanaged.passRetained(self) }
    }

    /// Which file a path names (lstat, so a link is itself): another folder put at the same path
    /// is a different one.
    struct FileID: Equatable, Sendable {
        let device: dev_t, inode: ino_t

        init?(of url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            (device, inode) = (info.st_dev, info.st_ino)
        }
    }

    /// A verified new bundle, ready to swap in.
    struct Staged: Sendable {
        /// `targetID` is the installed app the checks were made on: one put in its place meanwhile
        /// isn't swapped out.
        let work: URL, app: URL, target: URL, targetID: FileID?
        /// Any build of this app from this developer; a working copy in place must meet it.
        var requirement = ""
        /// The requirement it was checked against, plus its code directory hash: this build and no other.
        let exact: String
        /// Held while this staged update exists.
        let lock: Lock

        func discard() { removeTree(work) }
    }

    /// Downloads and verifies the update, and copies the new bundle out of its image.
    /// Nothing installed is touched; `install` does that once the app is about to quit.
    @concurrent static func stage(_ update: AvailableUpdate) async throws(Failure) -> Staged {
        // As root the checks below read the wrong owner, and the helper would open the app as root.
        guard geteuid() != 0 else { throw .asRoot }
        guard let dmgURL = update.dmg, let checksumURL = update.checksum else { throw .notInstallable }
        // The new bundle must be this app, from the developer who signed this one. Both are read
        // from our own signature, so the source never names the team.
        guard let own = CodeSigning.ownSigning(),
              let requirement = CodeSigning.requirement(identifier: own.identifier, team: own.team),
              let imageRequirement = CodeSigning.imageRequirement(team: own.team) else {
            throw .notSigned
        }
        let target = try installTarget(Bundle.main.bundleURL)
        if inPlaceBlocks(target, update: update) { throw .newerInPlace }
        // What the checks are made on: without it, an app put in its place couldn't be told apart.
        guard let targetID = FileID(of: target) else { throw .moved }
        try prepareStateDirectory(stateDirectory)
        let lock = try Lock.take(lockFile)
        // Nor while the installer runs: each would take the other's copy for one it can replace.
        // Looked for only once this holds its own lock, as the installer takes its own before looking
        // for this one: then at least one of two starting together sees the other.
        if installerIsRunning(installerLock) { throw .installing }
        // Held to the end of this scope on every path, not just until its last use.
        defer { withExtendedLifetime(lock) {} }
        retire(legacyStateDirectory)
        let work = try makeRunDirectory(for: target)
        var staged = false
        // removeTree: the image may still be mounted in it, after a detach that failed.
        defer { if !staged { removeTree(work) } }

        let dmg = work.appendingPathComponent("update.dmg")
        do {
            let (bytes, response) = try await session.bytes(from: dmgURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            guard response.expectedContentLength <= maxImageBytes else { throw Failure.tooLarge }
            try await CappedRead.write(bytes, to: dmg, limit: maxImageBytes)
        } catch let failure as Failure {
            throw failure
        } catch is CappedRead.TooLarge {
            throw .tooLarge
        } catch { throw .download }

        let published: Data
        do {
            let (bytes, response) = try await session.bytes(from: checksumURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            published = try await CappedRead.data(bytes, limit: maxChecksumBytes)
        } catch is CappedRead.TooLarge {
            throw .checksum   // no checksum is that long
        } catch { throw .download }
        guard let digest = try? UpdateChecksum.sha256Hex(fileAt: dmg) else { throw .download }   // unreadable, not a mismatch
        guard UpdateChecksum.matches(digest: digest, published: String(decoding: published, as: UTF8.self)) else { throw .checksum }
        try stopIfCancelled()

        let app = work.appendingPathComponent("systat.app")
        let mount = work.appendingPathComponent("mount")
        // The checksum comes from the same release, so it can't vouch for the image. Its own
        // signature can: an image from anyone else is never mounted.
        let imageSigned = run("/usr/bin/codesign", ["--verify", "-R=" + imageRequirement, dmg.path], stopsWhenCancelled: true)
        try stopIfCancelled()
        guard imageSigned else { throw .imageSignature }
        guard run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        else { throw .mount }
        try takeApp(from: mount, to: app)
        try? FileManager.default.removeItem(at: dmg)
        try stopIfCancelled()

        // Pinned first, and every check made on that build: nothing swapped in during the checks,
        // or after them, can pass. Revocation is checked once, here.
        guard let exact = CodeSigning.pinned(requirement, to: app),
              CodeSigning.satisfies(app, requirement: exact) else { throw .signature }
        try stopIfCancelled()
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard update.isRelease(of: plist?["CFBundleShortVersionString"] as? String) else { throw .wrongVersion }
        // Gatekeeper's own assessment, which also checks the certificate hasn't been revoked. The
        // swapped-in app carries no quarantine flag, so Gatekeeper would not look at it on launch.
        let assessed = run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], stopsWhenCancelled: true)
        try stopIfCancelled()
        guard assessed else { throw .gatekeeper }
        staged = true
        return Staged(work: work, app: app, target: target, targetID: targetID, requirement: requirement, exact: exact, lock: lock)
    }

    /// Between the steps of staging: a stopped update (Ctrl-C in `systat --update`) goes no further,
    /// and staging then removes its run folder, as on any failure.
    static func stopIfCancelled() throws(Failure) {
        if Task.isCancelled { throw .interrupted }
    }

    /// The relaunch helper, started and blocked on a pipe from this process.
    struct Helper {
        let pid: pid_t
        /// The pipe's write end. It stays open until this process exits, which is what the helper
        /// waits for, and no other process gets it.
        let pipe: Int32
        /// Whether it was told the swap is in.
        var told = false

        /// Tells it the swap is in. False if it is somehow gone: the write fails (no SIGPIPE: see
        /// `startHelper`), and the new version stays installed, just not reopened.
        func go() -> Bool { "go\n".withCString { write(pipe, $0, 3) } == 3 }

        /// End of file without "go": it exits having done nothing, and is reaped off this thread.
        func letGo() {
            close(pipe)
            let pid = pid
            Thread.detachNewThread {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
    }

    /// Swaps the staged app into place, and has the helper open it (when `reopen`) once `appPID`,
    /// this process, has exited. The caller quits next. The helper starts first, so a swap that
    /// went in is always followed up; it acts only once told the swap is in.
    /// True once the helper is told the swap is in; false if it was gone by then, and nothing will
    /// reopen the app (when `reopen`, a note says so).
    @discardableResult static func install(_ staged: Staged, appPID: Int32, reopen: Bool) throws(Failure) -> Bool {
        try install(staged, appPID: appPID, open: reopen ? ["/usr/bin/open"] : [], resultFile: resultFile).told
    }

    static func install(_ staged: Staged, appPID: Int32, open: [String], resultFile: URL,
                        alert: [String] = RelaunchScript.alert, verify: ((URL) -> Bool)? = nil,
                        exchange: (URL, URL) -> Int32 = UpdateInstaller.exchange) throws(Failure) -> Helper {
        let script = RelaunchScript.render(appPID: appPID, target: staged.target.path, workDir: staged.work.path,
                                           oldApp: staged.app.path, resultFile: resultFile.path,
                                           requirement: staged.exact, open: open, alert: alert)
        // The installed app's identity from the checks, or a replacement couldn't be told apart.
        guard staged.targetID != nil else {
            staged.discard()
            throw .moved
        }
        var helper: Helper
        do {
            helper = try startHelper(script, holding: staged.lock)
        } catch {
            staged.discard()
            throw error
        }
        do {
            try swapIn(staged.app, at: staged.target, work: staged.work, expected: staged.targetID, exact: staged.exact,
                       base: staged.requirement, verify: verify ?? { CodeSigning.isExactly($0, requirement: staged.exact) },
                       exchange: exchange)
        } catch {
            helper.letGo()
            // Where the previous version is, for the next launch: the panel's message goes when
            // systat quits, and the login item can't start the copy that was disabled.
            if case .stranded = error { try? note(error.description, in: resultFile) } else { staged.discard() }
            throw error
        }
        // A note from an earlier update is about what was just replaced. Cleared only now: a swap
        // refused changed nothing, so it still stands.
        unlink(resultFile.path)
        if resultFile == Self.resultFile { clearLastResult() }
        helper.told = helper.go()
        noteIfUnopened(told: helper.told, reopening: !open.isEmpty, target: staged.target, in: resultFile)
        // Until this process exits, which the caller is about to do: no other update starts meanwhile.
        staged.lock.keepUntilExit()
        return helper
    }

    /// Starts `sh -c script` with its stdin the read end of a new pipe, in a session of its own, so
    /// nothing aimed at this process's group (a terminal's Ctrl-C or hang-up, a group kill) reaches
    /// it. It gets that pipe, /dev/null for output, the update lock as descriptor 3 (so no installer
    /// or other update starts while it still checks and opens the new version, after this process
    /// has exited), and no other file this process has open.
    static func startHelper(_ script: String, holding lock: Lock) throws(Failure) -> Helper {
        // The lock goes to the helper as descriptor 3, from a copy numbered above it: were the lock
        // itself 3, a dup onto itself would leave it close-on-exec, and the helper without it.
        let lockCopy = fcntl(lock.descriptor, F_DUPFD_CLOEXEC, 10)
        guard lockCopy >= 0 else { throw .helper }
        defer { close(lockCopy) }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw .helper }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        // The helper has its own copy; this process keeps only the write end.
        defer { close(readEnd) }
        // Never inherited by anything else this process starts, and a write to a helper that has
        // gone fails instead of killing this process.
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
        posix_spawn_file_actions_adddup2(&actions, lockCopy, 3)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling and an empty mask, whatever this process set up.
        var defaults = sigset_t(), none = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] { strings.map { strdup($0) } + [nil] }
        let argv = cStrings(["/bin/sh", "-c", script])
        let envp = cStrings(toolEnvironment.map { "\($0.key)=\($0.value)" })
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp) == 0 else {
            close(writeEnd)
            throw .helper
        }
        return Helper(pid: pid, pipe: writeEnd)
    }

    /// Exchanges two entries in one rename: 0, or the errno it failed with.
    static func exchange(_ a: URL, _ b: URL) -> Int32 {
        renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }

    /// Exchanges `app` and the installed `target` in one rename (`RENAME_SWAP`), so the slot is never
    /// empty and the old app ends up where `app` was. Both must be real folders when asked here
    /// (not through a link, nor from cached answers), and `app` must still pass `verify`. The app now
    /// in place must pass it too, or the two are exchanged back; if even that fails, the app in place
    /// is made unopenable and the old one is kept as `work`/previous.app. The caller holds the `Lock`.
    /// `expected` is the installed app the checks were made on. `exact` (the pinned requirement) and
    /// `base` (any build of this app) are written in the run's mark for pruning.
    static func swapIn(_ app: URL, at target: URL, work: URL, expected: FileID? = nil, exact: String = "", base: String = "",
                       verify: (URL) -> Bool,
                       exchange: (URL, URL) -> Int32 = UpdateInstaller.exchange) throws(Failure) {
        guard isRealFolder(target), expected == nil || FileID(of: target) == expected else { throw .moved }
        // Asked again here: the old app is about to land in the run folder, to be removed.
        if let problem = bundleProblem(target, owner: getuid()) { throw problem }
        guard isRealFolder(app), verify(app) else { throw .changed }
        // Before anything moves: from here on the run folder may hold the only copy of the old app.
        guard mark(work, target: target, exact: exact, base: base) else { throw .swap }
        switch exchange(app, target) {
        case 0: break
        // App Management: a terminal not allowed to change apps, when run as systat --update.
        case EPERM: throw .blocked
        default: throw .swap
        }
        if verify(target) { return }
        guard exchange(app, target) == 0 else {
            let disabled = disable(target)
            // Named, so it's plain what to keep. A rename inside our own private folder fails only if
            // the app is gone, and then there's no previous version to name.
            let previous = work.appendingPathComponent("previous.app")
            let kept = rename(app.path, previous.path) == 0 ? previous.path : isRealFolder(app) ? app.path : nil
            throw .stranded(previous: kept, disabled: disabled, target: target.path)
        }
        throw .notInPlace
    }

    /// Closes the app's executable (mode 0), so neither Finder nor the login item can start it. Not
    /// the folder: an app with a closed folder can't be emptied from the Trash. Never through a link:
    /// that would close whatever it points at instead.
    private static func disable(_ app: URL) -> Bool {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        guard isRealFolder(app), isRealFolder(app.appendingPathComponent("Contents")), isRealFolder(macOS),
              let name = executableName(app) else { return false }
        let fd = open(macOS.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && fchmod(fd, 0) == 0
    }

    private static func executableName(_ app: URL) -> String? {
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let name = plist?["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    /// The copy `systat --update` is about to quit, noted first: if the update then fails, it is
    /// opened again only if it is still that very build, and can start.
    struct QuitCopy {
        let id: FileID?
        /// `requirement` pinned to the build at the path; nil if it couldn't be read.
        let exact: String?

        init(at target: URL, requirement: String) {
            id = FileID(of: target)
            exact = CodeSigning.pinned(requirement, to: target)
        }

        enum AfterFailure: Equatable {
            case reopen
            /// The error itself says what is in place.
            case leave
            /// It stays quit, for the reason given.
            case say(String)
        }

        /// What `systat --update` does with this copy once the install failed: it was quit, so
        /// the user is told whenever it isn't opened again.
        func afterFailure(_ error: Failure, at target: URL) -> AfterFailure {
            if error.reopensQuitApp(quit: id, now: FileID(of: target)), isStill(at: target) { return .reopen }
            if case .stranded = error { return .leave }
            // Nothing there now, or another file; otherwise the same one, whose build couldn't be read
            // before the quit, or which no longer verifies as that build or can't start.
            guard let now = FileID(of: target) else {
                return .say("\(target.path) is gone, so the systat that was quit wasn't opened again")
            }
            if exact != nil, let id, now != id {
                return .say("\(target.path) is no longer the copy of systat that was quit, so it wasn't opened again")
            }
            return .say("systat couldn't confirm that \(target.path) is still a working copy of the systat that was quit, so it wasn't opened again")
        }

        func isStill(at target: URL) -> Bool {
            guard let exact else { return false }
            return works(target, requirement: exact)
        }
    }

    /// Whether `app` is a working copy: a build meeting `requirement` whose executable can start
    /// (permissions aren't sealed, so one that only lost its execute bits still verifies; one the
    /// swap disabled, at mode 0, can't be read, so it fails either way).
    private static func works(_ app: URL, requirement: String) -> Bool {
        guard isRealFolder(app), let name = executableName(app) else { return false }
        let executable = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        var info = stat()
        return lstat(executable.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(executable.path, X_OK) == 0
            && CodeSigning.isExactly(app, requirement: requirement)
    }

    /// Marks `work` as a run whose swap started, naming the slot, the pinned build and the
    /// requirement any build meets, so pruning can tell later whether the app in it is still needed.
    private static func mark(_ work: URL, target: URL, exact: String, base: String) -> Bool {
        let fd = open(work.appendingPathComponent(swapMark).path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let note = Array([target.path, exact, base].joined(separator: "\n").utf8)
        return write(fd, note, note.count) == note.count
    }

    /// A marked run's old app (systat.app, or previous.app once renamed) is a leftover, not the only
    /// copy, when there's none left, when the run holds the pinned build (it never went in), or when
    /// a working systat is in the slot: the one swapped in, or one the installer or a later update
    /// put there.
    private static func holdsNothingNeeded(_ run: URL) -> Bool {
        let renamed = run.appendingPathComponent("previous.app")
        let app = FileID(of: renamed) != nil ? renamed : run.appendingPathComponent("systat.app")
        if FileID(of: app) == nil { return true }
        guard let note = readSmallFile(run.appendingPathComponent(swapMark)) else { return false }
        let parts = note.components(separatedBy: "\n")
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { return false }
        return CodeSigning.isExactly(app, requirement: parts[1])
            || works(URL(fileURLWithPath: parts[0]), requirement: parts[2])
    }

    /// The app's real location, once it's somewhere systat can replace itself. The checks and the
    /// helper both use this path, so a link on the way to the app can't be re-pointed between them.
    /// Everything in it must belong to `owner` (this user): swapped out, the old app is removed.
    static func installTarget(_ bundle: URL, owner: uid_t = getuid()) throws(Failure) -> URL {
        guard let real = realpath(bundle.path, nil) else { throw .notAnApp }
        let target = URL(fileURLWithPath: String(cString: real))
        free(real)
        try checkReplaceable(target)
        if let problem = bundleProblem(target, owner: owner) { throw problem }
        return target
    }

    /// Finder's Locked (`uchg`) and the append-only flags, user or system: each stops a rename or a removal.
    private static let lockFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)

    /// Why the old app, once swapped out, might not be removable, if it might not: `bundle` and
    /// everything in it must belong to `owner`, unlocked, and no one else may add to a folder in it, by
    /// mode or by ACL (they could plant a folder of their own there). Links are judged as themselves
    /// (lstat): removing one removes only the link. A folder that can't be read can't be checked.
    private static func bundleProblem(_ bundle: URL, owner: uid_t) -> Failure? {
        func problem(_ url: URL) -> Failure? {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return .unreadable }
            guard info.st_uid == owner else { return .notYours }
            // Locked, anywhere in it: the folder couldn't be renamed, or the old copy never removed.
            guard info.st_flags & lockFlags == 0 else { return .locked }
            guard info.st_mode & S_IFMT == S_IFDIR else { return nil }
            return info.st_mode & 0o022 != 0 || FolderTrust.aclLetsSomeoneChange(url.path) ? .openInside : nil
        }
        final class Errors: @unchecked Sendable { var any = false }
        let errors = Errors()
        if let found = problem(bundle) { return found }
        guard let walk = FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, _ in errors.any = true; return false }) else { return .unreadable }
        for case let url as URL in walk { if let found = problem(url) { return found } }
        return errors.any ? .unreadable : nil
    }

    /// The swap renames the installed app out and the new one in, which needs write access to the
    /// folder it's in and to the app itself (moving a folder to a new parent updates its "..").
    private static func checkReplaceable(_ target: URL) throws(Failure) {
        guard target.pathExtension == "app", isRealFolder(target) else { throw .notAnApp }
        let values = try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        // Run from the DMG, or from a randomized read-only copy (App Translocation) of a downloaded
        // app. First: neither can swap either, and moving it is what fixes both.
        if values?.volumeIsReadOnly == true || target.path.contains("/AppTranslocation/") { throw .mustMove }
        // Locked in Finder, or append-only: nothing can rename it, and the swap would fail as if App
        // Management refused.
        var info = stat()
        if lstat(target.path, &info) == 0, info.st_flags & lockFlags != 0 { throw .locked }
        // HFS+, for one: found out here, before anything is downloaded.
        guard canSwap(at: target) else { throw .cantSwap }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path)
        else { throw .notWritable }
        guard FolderTrust.onlyTrustedCanChange(target.deletingLastPathComponent()) else { throw .sharedFolder }
    }

    /// Whether the volume holding `url` can exchange two entries in one rename (`RENAME_SWAP`).
    static func canSwap(at url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        // Volume attributes are read from the volume's root.
        let root = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        struct Reply { var length: UInt32 = 0; var capabilities = vol_capabilities_attr_t() }
        var reply = Reply()
        guard getattrlist(root, &request, &reply, MemoryLayout<Reply>.size, 0) == 0 else { return false }
        let bit = UInt32(VOL_CAP_INT_RENAME_SWAP)
        return reply.capabilities.valid.1 & bit != 0 && reply.capabilities.capabilities.1 & bit != 0
    }

    /// A fresh folder for this attempt, on the target's volume so the swap is a rename:
    /// the state folder in a standard setup, otherwise a private folder beside the app. Folders
    /// left by attempts that died more than a day ago are removed.
    static func makeRunDirectory(for target: URL, stateDirectory: URL = stateDirectory) throws(Failure) -> URL {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        let root = sameVolume(stateDirectory, parent) ? stateDirectory : try stagingRoot(beside: parent)
        pruneStaleRuns(in: root, olderThan: Date().addingTimeInterval(-staleRunAge))
        let run = root.appendingPathComponent("run-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            // The state folder isn't where the app is installed: that has its own message.
            throw root == stateDirectory ? .stateFolder : .notWritable
        }
        // Checked as created: an ACL it inherited would open it to others.
        guard FolderTrust.onlyTrustedCanChange(run) else {
            try? fm.removeItem(at: run)
            throw .sharedFolder
        }
        return run
    }

    /// The folder for the lock, the result file and (on the app's volume) the staged app: private,
    /// and where no other user can rename it or anything above it and swap what's staged.
    static func prepareStateDirectory(_ url: URL) throws(Failure) {
        // The folders above it first, and their trust: what's below can't be trusted if they aren't.
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch { throw .stateFolder }
        guard FolderTrust.onlyTrustedCanChange(parent) else { throw .sharedLibrary }
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw .stateFolder }
        // Opened without following a link, so the checks and the chmod are on this very folder.
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .stateFolder }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw .stateFolder }
        guard FolderTrust.onlyTrustedCanChange(url) else { throw .sharedLibrary }
    }

    /// Copies the app out of the image without ACLs, with no group or other write, and with no setuid
    /// or setgid bit (ditto drops those itself when not run as root; this makes sure). The code seal
    /// doesn't cover permissions, so any of them would open the app to other users after it verifies.
    static func copyOut(_ source: URL, to app: URL) -> Bool {
        run("/usr/bin/ditto", ["--noacl", source.path, app.path]) && run("/bin/chmod", ["-R", "-P", "go-w,ug-s", app.path])
    }

    /// Removes a run folder, even one holding an app the swap disabled (its executable mode 0, or its
    /// `Contents/MacOS` folder closed by an earlier development build), or
    /// the image still mounted in it (an attempt that died while it was).
    static func removeTree(_ url: URL) {
        let fm = FileManager.default
        detach(url.appendingPathComponent("mount"))
        if (try? fm.removeItem(at: url)) != nil { return }
        // -P: links inside are left alone, not followed.
        run("/bin/chmod", ["-R", "-P", "u+rwx", url.path])
        try? fm.removeItem(at: url)
    }

    /// Removes run folders older than `cutoff`, except one whose app may be the only working copy of
    /// systat: one whose swap started (marked) until `holdsNothingNeeded` says otherwise, and one
    /// 0.1.1 left previous.app in (it marked nothing, so which slot it came from isn't known). The
    /// user was told where that app is. Only real folders: a link is never followed.
    static func pruneStaleRuns(in root: URL, olderThan cutoff: Date) {
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("run-") {
            var info = stat()
            guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff else { continue }
            let marked = FileID(of: old.appendingPathComponent(swapMark)) != nil
            guard marked ? holdsNothingNeeded(old) : FileID(of: old.appendingPathComponent("previous.app")) == nil else { continue }
            removeTree(old)
        }
    }

    /// The staging folder beside an app on another volume. Only in a folder this user owns and no one
    /// else can write to: anyone who can rename entries there could swap the staging folder, and the
    /// app in it, between the checks and the swap. The folder itself must be ours, not a link, hold
    /// nothing anyone else owns, carry no ACL that opens it, and is closed to 0700 however it was left.
    static func stagingRoot(beside parent: URL) throws(Failure) -> URL {
        // The parent's ACLs, and the folders above it, were checked by `checkReplaceable`, which
        // `installTarget` runs on this same path first; this only adds that the parent is this user's.
        guard isOwnFolder(parent, closedTo: 0o022) else { throw .notWritable }
        let root = parent.appendingPathComponent(".systat-update")
        guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else { throw .notWritable }
        // Opened without following a link, so the owner check and the chmod are on this very folder.
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .notWritable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw .notWritable }
        // Left open before, it may hold entries someone else planted, which pruning would delete into.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path),
              entries.allSatisfy({ isOwned(root.appendingPathComponent($0)) }),
              FolderTrust.onlyTrustedCanChange(root) else { throw .sharedFolder }
        return root
    }

    /// Copies systat out of the image mounted at `mount`, then unmounts it. The image did open, so
    /// what goes wrong here has messages of its own.
    static func takeApp(from mount: URL, to app: URL, detach: (URL) -> Bool = detach) throws(Failure) {
        // A real folder only: a symlink named systat.app could point at any app on this Mac.
        let source = mount.appendingPathComponent("systat.app")
        let copied = isRealFolder(source) && copyOut(source, to: app)
        // Still mounted, the run folder could never be removed.
        guard detach(mount) else { throw .eject }
        guard copied, isRealFolder(app) else { throw .badImage }
    }

    /// Unmounts the image at `mount`, if one is: a few tries, since a volume something is still
    /// reading refuses for a moment even forced. False if it's still mounted.
    @discardableResult static func detach(_ mount: URL) -> Bool {
        for _ in 0..<3 where isMountPoint(mount) {
            if run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) { return true }
            usleep(500_000)
        }
        return !isMountPoint(mount)
    }

    private static func isMountPoint(_ url: URL) -> Bool {
        var info = stat(), parent = stat()
        return lstat(url.path, &info) == 0 && lstat(url.deletingLastPathComponent().path, &parent) == 0
            && info.st_dev != parent.st_dev
    }

    private static func isOwned(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid()
    }

    /// A real folder (lstat, so never a symlink) owned by this user, with none of `mask`'s permission bits set.
    private static func isOwnFolder(_ url: URL, closedTo mask: mode_t) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & mask == 0
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va.isEqual(vb)
    }

    /// Asked of the path each time (lstat, so never through a link): a URL's resource values are
    /// cached on it, and would answer for whatever was there when it was first asked.
    private static func isRealFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Runs a tool and says whether it succeeded. One that hangs (a revocation check on a bad
    /// network, a stuck unmount) is stopped after `timeout` and counts as failed; with
    /// `stopsWhenCancelled`, so is one still running when the task it runs in is cancelled (a check
    /// of an update that was stopped). Cleanup (a detach) runs to the end even then.
    @discardableResult static func run(
        _ tool: String, _ arguments: [String], timeout: TimeInterval = 120, stopsWhenCancelled: Bool = false
    ) -> Bool {
        let process = silentProcess(tool, arguments)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return false }
        let deadline = DispatchTime.now() + timeout
        var finished = false
        repeat {
            finished = exited.wait(timeout: min(deadline, .now() + 0.1)) == .success
        } while !finished && DispatchTime.now() < deadline && !(stopsWhenCancelled && Task.isCancelled)
        guard finished else {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            return false
        }
        return process.terminationStatus == 0
    }

    private static func silentProcess(_ tool: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = toolEnvironment
        return process
    }

    /// The tools and the helper get the system's PATH, and nothing else this process inherited
    /// (an exported shell function, a DYLD variable) reaches them.
    private static var toolEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(
            ["HOME", "USER", "LOGNAME", "TMPDIR"].compactMap { key in inherited[key].map { (key, $0) } },
            uniquingKeysWith: { first, _ in first })
    }
}

enum CodeSigning {
    /// The signing identifier and Team ID in the running app's signature; nil for an ad-hoc or unsigned build.
    static func ownSigning() -> (identifier: String, team: String)? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        let dict = info as? [String: Any]
        guard let identifier = dict?[kSecCodeInfoIdentifier as String] as? String,
              let team = dict?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return (identifier, team)
    }

    /// Apple's markers for a Developer ID certificate: the Developer ID intermediate, and a Developer
    /// ID Application leaf. Without them a team's development or distribution certificates also match.
    private static let developerID =
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// This app (by signing identifier), signed with a Developer ID from this team, and notarized.
    static func requirement(identifier: String, team: String) -> String? {
        guard !identifier.isEmpty, identifier.count <= 255,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              let image = imageRequirement(team: team)
        else { return nil }
        return #"identifier "\#(identifier)" and "# + image
    }

    /// Signed with a Developer ID from this team, and notarized. For the disk image, whose signing
    /// identifier codesign takes from its file name, so it can't be pinned.
    static func imageRequirement(team: String) -> String? {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return #"anchor apple generic and \#(developerID) and certificate leaf[subject.OU] = "\#(team)" and notarized"#
    }

    /// kSecCSEnforceRevocationChecks in CSCommon.h, which Swift doesn't import.
    private static let enforceRevocationChecks: UInt32 = 1 << 30

    /// `requirement`, narrowed to this very build: one of the code directory hashes (cdhashes) of its
    /// executable's architectures, each of which is checked on its own and matches its own hash.
    static func pinned(_ requirement: String, to bundle: URL) -> String? {
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let name = plist?["CFBundleExecutable"] as? String, !name.contains("/") else { return nil }
        let executable = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        let slices: [UInt64?] = sliceOffsets(executable)?.map(Optional.some) ?? [nil]
        var hashes: [String] = []
        for offset in slices {
            var code: SecStaticCode?
            var info: CFDictionary?
            let attributes = offset.map { [kSecCodeAttributeUniversalFileOffset as String: NSNumber(value: $0)] } ?? [:]
            guard SecStaticCodeCreateWithPathAndAttributes(bundle as CFURL, [], attributes as CFDictionary, &code) == errSecSuccess,
                  let code, SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
                  let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
            hashes.append(#"cdhash H""# + hash.map { String(format: "%02x", $0) }.joined() + #"""#)
        }
        return hashes.isEmpty ? nil : requirement + " and (" + hashes.joined(separator: " or ") + ")"
    }

    /// Where each architecture starts in a universal executable; nil for a single-architecture one.
    static func sliceOffsets(_ executable: URL) -> [UInt64]? {
        guard let file = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 8 + 16 * 32), header.count >= 8 else { return nil }
        func word(_ at: Int) -> UInt64 { header[at..<at + 4].reduce(0) { $0 << 8 | UInt64($1) } }
        let wide: Bool
        switch word(0) {
        case 0xcafebabe: wide = false   // FAT_MAGIC: cputype, cpusubtype, offset, size, align (32-bit each)
        case 0xcafebabf: wide = true    // FAT_MAGIC_64: offset and size are 64-bit, then align and reserved
        default: return nil
        }
        let count = Int(word(4)), stride = wide ? 32 : 20
        guard (1...16).contains(count), header.count >= 8 + count * stride,
              let size = try? file.seekToEnd() else { return nil }
        let offsets = (0..<count).map { i in
            let at = 8 + i * stride + 8
            return wide ? word(at) << 32 | word(at + 4) : word(at)
        }
        return offsets.allSatisfy { $0 < size } ? offsets : nil
    }

    /// For a requirement from `pinned`: every architecture, without the revocation check
    /// `satisfies` already made.
    static func isExactly(_ bundle: URL, requirement: String) -> Bool {
        check(bundle, requirement: requirement,
              flags: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    }

    static func satisfies(_ bundle: URL, requirement: String) -> Bool {
        // Revocation is enforced here too, not left to spctl, which says yes to everything when
        // Gatekeeper is turned off.
        check(bundle, requirement: requirement,
              flags: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode | enforceRevocationChecks)
    }

    private static func check(_ bundle: URL, requirement: String, flags: UInt32) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), req) == errSecSuccess
    }
}

