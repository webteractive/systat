import Foundation
import Testing
@testable import systat

/// Staging beside the app (when it's on another volume than the caches folder) must happen where
/// no other user can plant, swap or rename anything between the checks and the swap.
private struct Folder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("systat-staging-\(UUID().uuidString)")

    init(mode: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try chmod(url, mode)
    }

    var staging: URL { url.appendingPathComponent(".systat-update") }

    func chmod(_ target: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
    }

    func mode(of target: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

@Test func stagingBesideTheAppUsesAPrivateFolder() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }

    let root = try UpdateInstaller.stagingRoot(beside: folder.url)

    #expect(root.path == folder.staging.path)
    #expect(folder.mode(of: root) == 0o700)
}

@Test func anOpenStagingFolderOfOursIsClosed() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    try FileManager.default.createDirectory(at: folder.staging, withIntermediateDirectories: false)
    try folder.chmod(folder.staging, 0o777)

    let root = try UpdateInstaller.stagingRoot(beside: folder.url)

    #expect(folder.mode(of: root) == 0o700)
}

@Test func noStagingInAFolderOthersCanWriteTo() throws {
    for mode in [0o775, 0o757, 0o777, 0o1777] {
        let folder = try Folder(mode: mode)
        defer { folder.cleanUp() }
        #expect(throws: UpdateInstaller.Failure.self, "mode \(String(mode, radix: 8))") {
            try UpdateInstaller.stagingRoot(beside: folder.url)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.staging.path), "nothing is created there")
    }
}

@Test func noStagingInAFolderOwnedBySomeoneElse() {
    // Root owns /Applications and /tmp; neither is ours to stage in.
    for parent in ["/Applications", "/private/tmp"] {
        #expect(throws: UpdateInstaller.Failure.self, "\(parent)") {
            try UpdateInstaller.stagingRoot(beside: URL(fileURLWithPath: parent))
        }
    }
}

@Test func aPlantedSymlinkIsNeverStagedThrough() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let elsewhere = folder.url.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: folder.staging, withDestinationURL: elsewhere)

    #expect(throws: UpdateInstaller.Failure.self) { try UpdateInstaller.stagingRoot(beside: folder.url) }
    #expect(folder.mode(of: elsewhere) == 0o755, "the link's target is left as it was")
}

@Test func aStagingFolderOfOursWithAnACLIsRefused() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    try FileManager.default.createDirectory(at: folder.staging, withIntermediateDirectories: false)
    let acl = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["+a", "everyone allow add_file", folder.staging.path])
    acl.waitUntilExit()

    #expect(throws: UpdateInstaller.Failure.sharedFolder) { try UpdateInstaller.stagingRoot(beside: folder.url) }
}

@Test func aPlantedFileIsNeverStagedThrough() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    try Data().write(to: folder.staging)

    #expect(throws: UpdateInstaller.Failure.self) { try UpdateInstaller.stagingRoot(beside: folder.url) }
}

@Test func pruningKeepsARunThatHoldsTheOnlyCopyOfTheApp() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let fm = FileManager.default
    func runFolder(_ name: String, age: TimeInterval, backup: Bool = false) throws -> URL {
        let url = folder.url.appendingPathComponent(name)
        try fm.createDirectory(at: url.appendingPathComponent(backup ? "previous.app" : "update"), withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
    let stale = try runFolder("run-stale", age: 3 * 86_400)
    let rescued = try runFolder("run-rescued", age: 3 * 86_400, backup: true)
    let fresh = try runFolder("run-fresh", age: 60)
    let other = try runFolder("keep-me", age: 3 * 86_400)

    UpdateInstaller.pruneStaleRuns(in: folder.url, olderThan: Date().addingTimeInterval(-86_400))

    #expect(!fm.fileExists(atPath: stale.path))
    #expect(fm.fileExists(atPath: rescued.path), "the helper said the previous app is there")
    #expect(fm.fileExists(atPath: fresh.path))
    #expect(fm.fileExists(atPath: other.path))
}

@Test func aRunWhoseMarkMakesNoSenseIsKept() throws {
    // The swap marks the run before it exchanges anything; a mark that isn't its three lines can't
    // say the app in it is a leftover, so it is kept as if it were the only copy.
    let folder = try Folder()
    defer { folder.cleanUp() }
    let fm = FileManager.default
    let run = folder.url.appendingPathComponent("run-swapped")
    try fm.createDirectory(at: run.appendingPathComponent("systat.app"), withIntermediateDirectories: true)
    try Data().write(to: run.appendingPathComponent(UpdateInstaller.swapMark))
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: run.path)

    UpdateInstaller.pruneStaleRuns(in: folder.url, olderThan: Date().addingTimeInterval(-86_400))

    #expect(fm.fileExists(atPath: run.appendingPathComponent("systat.app").path))
}

@Test func theOldCachesFolderIsReadOnceAndRetired() throws {
    // 0.1.1 kept its lock and result in ~/Library/Caches/systat-update, and its helper reports
    // the update to this version there.
    let folder = try Folder()
    defer { folder.cleanUp() }
    let fm = FileManager.default
    let current = folder.url.appendingPathComponent("current"), legacy = folder.url.appendingPathComponent("legacy")
    try fm.createDirectory(at: current, withIntermediateDirectories: false)
    try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
    try "failed: the new version didn't verify\n".write(to: legacy.appendingPathComponent("result"), atomically: true, encoding: .utf8)
    try Data().write(to: legacy.appendingPathComponent("lock"))

    let results = [current.appendingPathComponent("result"), legacy.appendingPathComponent("result")]
    #expect(UpdateInstaller.lastResult(from: results) == "failed: the new version didn't verify")

    // Its note is kept until it is dismissed, even through an update that starts meanwhile.
    UpdateInstaller.retire(legacy)
    #expect(UpdateInstaller.lastResult(from: results) == "failed: the new version didn't verify")
    #expect(!fm.fileExists(atPath: legacy.appendingPathComponent("lock").path))

    UpdateInstaller.clearLastResult(results)
    UpdateInstaller.retire(legacy)
    #expect(!fm.fileExists(atPath: legacy.path), "nothing worth keeping, so the old folder goes")
}

@Test func theOldCachesFolderIsKeptWhileItHoldsAnApp() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let fm = FileManager.default
    let previous = folder.url.appendingPathComponent("run-old/previous.app")
    try fm.createDirectory(at: previous, withIntermediateDirectories: true)
    // Old enough to prune on age alone: only the app in it keeps it.
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)],
                         ofItemAtPath: folder.url.appendingPathComponent("run-old").path)
    try Data().write(to: folder.url.appendingPathComponent("lock"))

    UpdateInstaller.retire(folder.url)

    #expect(fm.fileExists(atPath: previous.path), "0.1.1 told the user the previous app is there")
    #expect(!fm.fileExists(atPath: folder.url.appendingPathComponent("lock").path))
}

@Test func aResultThatIsALinkIsIgnored() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let elsewhere = folder.url.appendingPathComponent("elsewhere"), result = folder.url.appendingPathComponent("result")
    try "failed: use the installer at evil.example".write(to: elsewhere, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: result, withDestinationURL: elsewhere)

    #expect(UpdateInstaller.lastResult(from: [result]) == nil)
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
}

@Test(.timeLimit(.minutes(1))) func aResultThatIsAPipeNeverHangsTheLaunch() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let result = folder.url.appendingPathComponent("result")
    try #require(mkfifo(result.path, 0o600) == 0)

    #expect(UpdateInstaller.lastResult(from: [result]) == nil)
}

@Test func aLongResultIsCut() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let result = folder.url.appendingPathComponent("result")
    try String(repeating: "x", count: 100_000).write(to: result, atomically: true, encoding: .utf8)

    #expect((UpdateInstaller.lastResult(from: [result])?.count ?? 0) <= 4096)
}

@Test func anEmptyResultHidesNoOther() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let empty = folder.url.appendingPathComponent("a"), real = folder.url.appendingPathComponent("b")
    try Data().write(to: empty)
    try "failed: why".write(to: real, atomically: true, encoding: .utf8)

    #expect(UpdateInstaller.lastResult(from: [empty, real]) == "failed: why")
}

@Test func aNoteIsShownUntilItIsDismissed() throws {
    // Quitting before reading it, or logging out, doesn't lose it.
    let folder = try Folder()
    defer { folder.cleanUp() }
    let result = folder.url.appendingPathComponent("result")
    try "failed: why".write(to: result, atomically: true, encoding: .utf8)

    #expect(UpdateInstaller.lastResult(from: [result]) == "failed: why")
    #expect(UpdateInstaller.lastResult(from: [result]) == "failed: why")
    UpdateInstaller.clearLastResult([result])
    #expect(UpdateInstaller.lastResult(from: [result]) == nil)
}

@Test func anOldFolderOthersCanChangeIsLeftAlone() throws {
    let folder = try Folder()
    defer { folder.cleanUp() }
    let open = folder.url.appendingPathComponent("open")
    try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
    try folder.chmod(open, 0o777)
    try Data().write(to: open.appendingPathComponent("lock"))
    let link = folder.url.appendingPathComponent("link"), target = folder.url.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try Data().write(to: target.appendingPathComponent("lock"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    UpdateInstaller.retire(open)
    UpdateInstaller.retire(link)

    #expect(FileManager.default.fileExists(atPath: open.appendingPathComponent("lock").path))
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("lock").path))
}

@Test func aNoteIsShownWithoutControlOrDirectionCharacters() throws {
    // A path in it can hold anything a file name can: no C0 or C1 control, nor a character that
    // reverses how the rest of the line reads.
    let folder = try Folder()
    defer { folder.cleanUp() }
    let result = folder.url.appendingPathComponent("result")
    try "failed: open /Users/a\u{9B}31mb\u{1B}[2J\u{202E}c\u{2066}d\u{07}.app\tnow\u{2028}or\u{2029}later\n".write(to: result, atomically: true, encoding: .utf8)

    #expect(UpdateInstaller.lastResult(from: [result]) == "failed: open /Users/a31mb[2Jcd.app now or later")
}

@Test func whatIsntUTF8InANoteIsLeftOut() throws {
    // As the installer prints it: a note cut short mid-character at 4 KB, say.
    let folder = try Folder()
    defer { folder.cleanUp() }
    let result = folder.url.appendingPathComponent("result")
    try Data([0x66, 0x3A, 0x20, 0x78, 0xFF, 0x79, 0x20, 0xC3]).write(to: result)

    #expect(UpdateInstaller.lastResult(from: [result]) == "f: xy")
}
