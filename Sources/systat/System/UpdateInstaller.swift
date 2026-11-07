import Foundation
import Security
import SystatCore

/// Fetches the latest release, and installs one in place: download, checksum, mount, copy out,
/// signature and Gatekeeper checks, then a detached helper (`SwapScript`) swaps the bundle once the app quits.
enum UpdateInstaller {
    enum Failure: Error, CustomStringConvertible {
        case check, notInstallable, notSigned, notAnApp, mustMove, notWritable, download, tooLarge, checksum, mount,
             imageSignature, signature, gatekeeper, wrongVersion, helper

        var description: String {
            switch self {
            case .check: "Couldn't reach GitHub to check for updates."
            case .notInstallable: "This release has no installable image."
            case .notSigned: "This build isn't Developer ID signed, so it can't update itself."
            case .notAnApp: "systat isn't running from an app bundle."
            case .mustMove: "Move systat into Applications, open it from there, then update."
            case .notWritable: "systat can't replace itself where it's installed. Use the installer, or move it to a folder you own."
            case .download: "The download failed."
            case .tooLarge: "The download is far larger than systat, so it was refused."
            case .checksum: "The download doesn't match the release checksum."
            case .mount: "The disk image couldn't be opened."
            case .imageSignature: "The disk image isn't signed by the same developer."
            case .signature: "The new version isn't systat signed by the same developer."
            case .gatekeeper: "Gatekeeper rejects the new version."
            case .wrongVersion: "The downloaded app isn't the version the release names."
            case .helper: "The installer couldn't start."
            }
        }
    }

    /// Lock, result file and (on the same volume) the staging folders live here.
    private static let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/systat-update")
    private static var resultFile: URL { stateDirectory.appendingPathComponent("result") }
    private static var lockFile: URL { stateDirectory.appendingPathComponent("lock") }
    /// systat's DMG is about 1 MB; anything near this is not it.
    private static let maxImageBytes = 200 << 20
    private static let maxChecksumBytes = 1024
    private static let staleRunAge: TimeInterval = 24 * 60 * 60

    private static let session = URLSession(configuration: .ephemeral)

    @concurrent static func latest(currentVersion: String) async throws(Failure) -> AvailableUpdate? {
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.check }
            return try UpdateCheck.evaluate(data, currentVersion: currentVersion)
        } catch {
            throw .check
        }
    }

    /// The line the last helper left ("installed X" or "failed: why"), removed once read.
    static func takeLastResult() -> String? {
        defer { try? FileManager.default.removeItem(at: resultFile) }
        return (try? String(contentsOf: resultFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A verified new bundle, ready for the helper.
    struct Staged: Sendable {
        let work: URL, app: URL, target: URL, requirement: String

        func discard() { try? FileManager.default.removeItem(at: work) }
    }

    /// Downloads and verifies the update, and copies the new bundle out of its image.
    /// Nothing installed is touched; `handOff` does that once the app is about to quit.
    @concurrent static func stage(_ update: AvailableUpdate) async throws(Failure) -> Staged {
        guard let dmgURL = update.dmg, let checksumURL = update.checksum else { throw .notInstallable }
        // The new bundle must be this app, from the developer who signed this one. Both are read
        // from our own signature, so the source never names the team.
        guard let own = CodeSigning.ownSigning(),
              let requirement = CodeSigning.requirement(identifier: own.identifier, team: own.team),
              let imageRequirement = CodeSigning.imageRequirement(team: own.team) else {
            throw .notSigned
        }
        let target = Bundle.main.bundleURL
        try checkReplaceable(target)
        let work = try makeRunDirectory(for: target)
        var staged = false
        defer { if !staged { try? FileManager.default.removeItem(at: work) } }

        let dmg = work.appendingPathComponent("update.dmg")
        do {
            let (downloaded, response) = try await session.download(from: dmgURL)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            guard size <= maxImageBytes else { throw Failure.tooLarge }
            try FileManager.default.moveItem(at: downloaded, to: dmg)
        } catch let failure as Failure {
            throw failure
        } catch { throw .download }

        do {
            let (bytes, response) = try await session.bytes(from: checksumURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.checksum }
            var published = Data()
            for try await byte in bytes {
                published.append(byte)
                guard published.count <= maxChecksumBytes else { throw Failure.checksum }
            }
            guard UpdateChecksum.matches(digest: try UpdateChecksum.sha256Hex(fileAt: dmg),
                                         published: String(decoding: published, as: UTF8.self))
            else { throw Failure.checksum }
        } catch { throw .checksum }

        let app = work.appendingPathComponent("systat.app")
        let mount = work.appendingPathComponent("mount")
        // The checksum comes from the same release, so it can't vouch for the image. Its own
        // signature can: an image from anyone else is never mounted.
        guard run("/usr/bin/codesign", ["--verify", "-R=" + imageRequirement, dmg.path]) else { throw .imageSignature }
        guard run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        else { throw .mount }
        // A real folder only: a symlink named systat.app could point at any app on this Mac.
        let source = mount.appendingPathComponent("systat.app")
        let copied = isRealFolder(source) && run("/usr/bin/ditto", [source.path, app.path])
        run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
        try? FileManager.default.removeItem(at: dmg)
        guard copied, isRealFolder(app) else { throw .mount }

        // Checked here too, while the app is alive to report it; the helper checks again before the swap.
        guard CodeSigning.satisfies(app, requirement: requirement) else { throw .signature }
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard update.isRelease(of: plist?["CFBundleShortVersionString"] as? String) else { throw .wrongVersion }
        // Gatekeeper's own assessment, which also checks the certificate hasn't been revoked. The
        // swapped-in app carries no quarantine flag, so Gatekeeper would not look at it on launch.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) else { throw .gatekeeper }
        staged = true
        return Staged(work: work, app: app, target: target, requirement: requirement)
    }

    /// Starts the helper that swaps the bundle in once `appPID` quits. The caller quits next.
    static func handOff(_ staged: Staged, appPID: Int32) throws(Failure) {
        let script = staged.work.appendingPathComponent("swap.sh")
        do {
            guard let start = SwapScript.startTime(of: appPID) else { throw Failure.helper }
            try SwapScript.render(appPID: appPID, appStart: start, target: staged.target.path, staged: staged.app.path,
                                  workDir: staged.work.path, lockFile: lockFile.path, resultFile: resultFile.path,
                                  requirement: staged.requirement)
                .write(to: script, atomically: true, encoding: .utf8)
            try silentProcess("/bin/sh", [script.path]).run()
        } catch {
            staged.discard()
            throw .helper
        }
    }

    /// The helper renames the installed app aside and the new one in, which needs write access to
    /// the folder it's in and to the app itself (moving a folder to a new parent updates its "..").
    private static func checkReplaceable(_ target: URL) throws(Failure) {
        guard target.pathExtension == "app" else { throw .notAnApp }
        let values = try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        // Run from the DMG, or from a randomized read-only copy (App Translocation) of a downloaded app.
        if values?.volumeIsReadOnly == true || target.path.contains("/AppTranslocation/") { throw .mustMove }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path)
        else { throw .notWritable }
    }

    /// A fresh folder for this attempt, on the target's volume so the helper's moves are renames:
    /// the caches folder in a standard setup, otherwise a hidden folder beside the app. Folders
    /// left by attempts that died more than a day ago are removed.
    private static func makeRunDirectory(for target: URL) throws(Failure) -> URL {
        let fm = FileManager.default
        do { try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true) } catch { throw .download }
        let parent = target.deletingLastPathComponent()
        let root = sameVolume(stateDirectory, parent) ? stateDirectory : parent.appendingPathComponent(".systat-update")
        let cutoff = Date().addingTimeInterval(-staleRunAge)
        for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("run-") {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < cutoff {
                try? fm.removeItem(at: old)
            }
        }
        let run = root.appendingPathComponent("run-\(UUID().uuidString)")
        do { try fm.createDirectory(at: run, withIntermediateDirectories: true) } catch { throw .notWritable }
        return run
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va.isEqual(vb)
    }

    private static func isRealFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink == false
    }

    @discardableResult private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = silentProcess(tool, arguments)
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func silentProcess(_ tool: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
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
        return #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)" and notarized"#
    }

    static func satisfies(_ bundle: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
