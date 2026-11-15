import Foundation
import Testing
@testable import systat

/// Where the update goes, the state folder beside it, and the copy taken out of the disk image.
private struct Tree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("systat-target-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try chmod(root, 0o755)
    }

    /// The real path, as realpath gives it (the temp folder is under the /var link to /private/var).
    var real: URL {
        let path = realpath(root.path, nil)!
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func mode(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    func app(in folder: String, mode: Int = 0o755) throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("systat.app"), withIntermediateDirectories: true)
        try chmod(dir, mode)
        return dir.appendingPathComponent("systat.app")
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func anAppOpenedThroughALinkIsUpdatedWhereItReallyIs() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    _ = try tree.app(in: "Real")
    let link = tree.root.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.root.appendingPathComponent("Real"))

    // The helper gets the real path, so re-pointing the link mid-swap moves nothing.
    let target = try UpdateInstaller.installTarget(link.appendingPathComponent("systat.app"))

    #expect(target.path == tree.real.appendingPathComponent("Real/systat.app").path)
}

@Test func aLinkIntoAFolderOthersCanChangeIsRefused() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    _ = try tree.app(in: "Open", mode: 0o777)
    let link = tree.root.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.root.appendingPathComponent("Open"))

    #expect(throws: UpdateInstaller.Failure.sharedFolder) {
        try UpdateInstaller.installTarget(link.appendingPathComponent("systat.app"))
    }
}

@Test func theUpdateFolderIsNotInCaches() {
    // Cleaner apps empty ~/Library/Caches, and the update folder can hold the only copy of the app.
    #expect(UpdateInstaller.stateDirectory.path.hasSuffix("/Library/Application Support/systat-update"))
}

@Test func anAppWithAnythingAnotherUserOwnsIsRefused() throws {
    // Swapped out, it would sit in the run folder for good: this user can't remove another's files.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Theirs")

    #expect(throws: UpdateInstaller.Failure.notYours) { try UpdateInstaller.installTarget(app, owner: getuid() + 1) }
    _ = try UpdateInstaller.installTarget(app)
}

@Test func aFolderInsideTheAppOthersCanWriteToIsRefused() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Open")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
    try tree.chmod(contents, 0o777)

    #expect(throws: UpdateInstaller.Failure.openInside) { try UpdateInstaller.installTarget(app) }
}

@Test func aFolderInsideTheAppWithAnACLOpenToOthersIsRefused() throws {
    // Mode bits closed, but an ACL entry lets everyone add to it all the same.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Acl")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let acl = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["+a", "everyone allow add_subdirectory", resources.path])
    acl.waitUntilExit()

    #expect(throws: UpdateInstaller.Failure.openInside) { try UpdateInstaller.installTarget(app) }
}

@Test func aNewerSystatPutInPlaceIsntSwappedOutForAnOlderUpdate() throws {
    // A newer systat put at the running one's path by hand: Update would swap it out, and the helper
    // would delete it.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Newer")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.3.0"], format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))

    #expect(UpdateInstaller.newerInPlace(app, than: "0.2.0"))
    #expect(!UpdateInstaller.newerInPlace(app, than: "0.3.0"))
    #expect(!UpdateInstaller.newerInPlace(app, than: "0.4.0"))
}

@Test(arguments: [UF_IMMUTABLE, UF_APPEND])
func aLockedFileInsideTheAppSaysToUnlockIt(flag: Int32) throws {
    // The swap would go in (renaming the folder doesn't mind), but the old copy could then never be
    // removed: refused before anything is downloaded, as the installer refuses it.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "LockedInside")
    let file = app.appendingPathComponent("Info.plist")
    try Data("x".utf8).write(to: file)
    try #require(chflags(file.path, UInt32(flag)) == 0)
    defer { chflags(file.path, 0) }

    #expect(throws: UpdateInstaller.Failure.locked) { try UpdateInstaller.installTarget(app) }
}

@Test(arguments: [UF_IMMUTABLE, UF_APPEND])
func aLockedAppSaysToUnlockIt(flag: Int32) throws {
    // Locked in Finder (the uchg flag), or append-only: nothing can rename it, and it isn't App
    // Management's doing.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Locked")
    try #require(chflags(app.path, UInt32(flag)) == 0)
    defer { chflags(app.path, 0) }

    #expect(throws: UpdateInstaller.Failure.locked) { try UpdateInstaller.installTarget(app) }
}

@Test func aFolderInsideTheAppThatCantBeReadIsRefused() throws {
    // What's in it can't be checked.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Closed")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
    try tree.chmod(contents, 0)
    defer { try? tree.chmod(contents, 0o755) }

    #expect(throws: UpdateInstaller.Failure.unreadable) { try UpdateInstaller.installTarget(app) }
}

@Test func aLinkInsideTheAppIsJudgedByItsOwnOwner() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    let app = try tree.app(in: "Mine")
    // Points at root's /bin; removing the link removes only the link.
    try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("bin"), withDestinationURL: URL(fileURLWithPath: "/bin"))

    _ = try UpdateInstaller.installTarget(app)
}

@Test func theStateFolderIsPrivate() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    let state = tree.root.appendingPathComponent("Caches/systat-update")

    try UpdateInstaller.prepareStateDirectory(state)

    #expect(tree.mode(of: state) == 0o700)
}

@Test func anExistingStateFolderIsClosed() throws {
    // Left open by hand, or by a restore from a backup.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let state = tree.root.appendingPathComponent("systat-update")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try tree.chmod(state, 0o755)

    try UpdateInstaller.prepareStateDirectory(state)

    #expect(tree.mode(of: state) == 0o700)
}

@Test func aStateFolderOthersCanChangeIsRefused() throws {
    // The staged app, the lock and the result file live there.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let caches = tree.root.appendingPathComponent("Caches")
    try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
    try tree.chmod(caches, 0o777)

    #expect(throws: UpdateInstaller.Failure.sharedLibrary) {
        try UpdateInstaller.prepareStateDirectory(caches.appendingPathComponent("systat-update"))
    }
}

@Test func aStateFolderThatIsALinkIsRefused() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    let elsewhere = tree.root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
    let state = tree.root.appendingPathComponent("systat-update")
    try FileManager.default.createSymbolicLink(at: state, withDestinationURL: elsewhere)

    #expect(throws: UpdateInstaller.Failure.stateFolder) { try UpdateInstaller.prepareStateDirectory(state) }
    #expect(tree.mode(of: elsewhere) == 0o755, "the link's target is left as it was")
}

@Test func aStateFolderThatCantBeMadeSaysSo() throws {
    // Not "can't replace itself where it's installed": the app's folder isn't the problem.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let closed = tree.root.appendingPathComponent("closed")
    try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: false)
    try tree.chmod(closed, 0o500)
    defer { try? tree.chmod(closed, 0o755) }

    #expect(throws: UpdateInstaller.Failure.stateFolder) {
        try UpdateInstaller.prepareStateDirectory(closed.appendingPathComponent("systat-update"))
    }
}

@Test func aRunFolderTheStateFolderCantHoldBlamesTheStateFolder() throws {
    // Not "can't replace itself where it's installed": the app's folder isn't the problem.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let state = tree.root.appendingPathComponent("systat-update")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try tree.chmod(state, 0o500)
    defer { try? tree.chmod(state, 0o700) }

    #expect(throws: UpdateInstaller.Failure.stateFolder) {
        try UpdateInstaller.makeRunDirectory(for: tree.root.appendingPathComponent("systat.app"), stateDirectory: state)
    }
}

@Test func theCopiedAppKeepsNoWayInForOthers() throws {
    // The code seal doesn't cover permissions, so a writable file or an ACL shipped in the image
    // would let other users change the app after it verifies.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let source = tree.root.appendingPathComponent("image/systat.app")
    let file = source.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: file)
    try tree.chmod(file, 0o666)
    try tree.chmod(source.appendingPathComponent("Contents"), 0o777)
    let acl = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["+a", "everyone allow add_file", source.path])
    acl.waitUntilExit()
    let copy = tree.root.appendingPathComponent("run/systat.app")

    #expect(UpdateInstaller.copyOut(source, to: copy))

    #expect(tree.mode(of: copy.appendingPathComponent("Contents/Info.plist")) == 0o644)
    #expect(tree.mode(of: copy.appendingPathComponent("Contents")) == 0o755)
    #expect(acl_get_link_np(copy.path, ACL_TYPE_EXTENDED) == nil, "no ACL is carried over")
}

@Test func theCopiedAppKeepsNoSetuidBit() throws {
    // Under /Applications a setuid file would run as this user for anyone who starts it.
    let tree = try Tree()
    defer { tree.cleanUp() }
    let source = tree.root.appendingPathComponent("image/systat.app")
    let tool = source.appendingPathComponent("Contents/MacOS/tool")
    try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: tool)
    try tree.chmod(tool, 0o6755)
    #expect(tree.mode(of: tool) == 0o6755)
    let copy = tree.root.appendingPathComponent("run/systat.app")

    #expect(UpdateInstaller.copyOut(source, to: copy))

    #expect(tree.mode(of: copy.appendingPathComponent("Contents/MacOS/tool")) == 0o755)
}
