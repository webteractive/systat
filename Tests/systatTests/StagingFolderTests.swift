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
