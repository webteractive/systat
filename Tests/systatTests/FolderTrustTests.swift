import Foundation
import Testing
@testable import systat

/// The update checks the app and its folder, swaps the new app in and opens it there. Anyone who
/// can rename entries in the app's folder, or any folder above it, could put their own app in its
/// place, or swap the folder, between the checks and the launch.
private struct Tree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("systat-trust-\(UUID().uuidString)")
    var apps: URL { root.appendingPathComponent("Apps") }

    init() throws {
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try chmod(root, 0o755)
        try chmod(apps, 0o755)
    }

    func chmod(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func run(_ tool: String, _ args: [String]) throws {
        let p = try Process.run(URL(fileURLWithPath: tool), arguments: args)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(tool) \(args)")
    }

    /// ACLs off first: a deny-delete entry a test left would stop the removal.
    func cleanUp() {
        try? chmod(root, 0o755)
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "-N", root.path]).waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func aFolderOnlyThisUserCanChangeIsTrusted() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    #expect(FolderTrust.onlyTrustedCanChange(tree.apps))
}

@Test func rootAndAdminFoldersAreTrusted() {
    // Another admin can replace anything in /Applications (root:admin, group-writable) without
    // the updater, so it counts.
    #expect(FolderTrust.onlyTrustedCanChange(URL(fileURLWithPath: "/Applications")))
}

@Test func aFolderOthersCanWriteToIsNotTrusted() throws {
    for mode in [0o775, 0o757, 0o777, 0o1777] {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.chmod(tree.apps, mode)
        #expect(!FolderTrust.onlyTrustedCanChange(tree.apps), "mode \(String(mode, radix: 8))")
    }
    // World-writable with the sticky bit: anyone can create entries there, a folder of their own at
    // the app's name included if it is ever free.
    #expect(!FolderTrust.onlyTrustedCanChange(URL(fileURLWithPath: "/Users/Shared")))
}

@Test func anOpenFolderAboveTheAppIsNotTrusted() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    // Whoever can rename Apps can put a folder of their own in its place.
    try tree.chmod(tree.root, 0o777)
    #expect(!FolderTrust.onlyTrustedCanChange(tree.apps))
}

@Test func anACLThatLetsOthersAddEntriesIsNotTrusted() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    try tree.run("/bin/chmod", ["+a", "everyone deny delete", tree.apps.path])
    #expect(FolderTrust.onlyTrustedCanChange(tree.apps), "a deny entry takes nothing away from the owner")
    try tree.run("/bin/chmod", ["+a", "everyone allow add_subdirectory", tree.apps.path])
    #expect(!FolderTrust.onlyTrustedCanChange(tree.apps))
}

@Test func everyACLRightThatChangesAFolderIsNotTrusted() throws {
    for right in ["add_file", "add_subdirectory", "delete_child", "delete", "writesecurity", "chown"] {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.run("/bin/chmod", ["+a", "everyone allow \(right)", tree.apps.path])
        #expect(!FolderTrust.onlyTrustedCanChange(tree.apps), "\(right)")
    }
}

@Test func anACLEntryForThisUserAloneIsTrusted() throws {
    // It gives the owner what the owner already has; nobody else gains anything.
    let tree = try Tree()
    defer { tree.cleanUp() }
    try tree.run("/bin/chmod", ["+a", "\(NSUserName()) allow add_file,add_subdirectory,delete_child", tree.apps.path])
    #expect(FolderTrust.onlyTrustedCanChange(tree.apps))
    try tree.run("/bin/chmod", ["+a", "staff allow add_file", tree.apps.path])
    #expect(!FolderTrust.onlyTrustedCanChange(tree.apps), "a group naming this user names others too")
}

@Test func anInheritOnlyACLIsNotTrustedEither() throws {
    // It grants nothing on the folder itself, but every folder the updater creates inside inherits
    // it: the staging and run folders would be open to everyone.
    let tree = try Tree()
    defer { tree.cleanUp() }
    try tree.run("/bin/chmod", ["+a", "everyone allow add_file,file_inherit,directory_inherit,only_inherit", tree.apps.path])
    #expect(!FolderTrust.onlyTrustedCanChange(tree.apps))
}

@Test func onlyALocalVolumeThatKeepsOwnershipIsTrusted() throws {
    // A network share reports its files as owned by whoever mounted it, whatever the server
    // lets its other users do, so its modes and owners vouch for nothing.
    var root = statfs()
    try #require(statfs("/", &root) == 0)
    #expect(FolderTrust.volumeIsTrusted(flags: root.f_flags, mountedBy: root.f_owner))
    #expect(!FolderTrust.volumeIsTrusted(flags: root.f_flags & ~UInt32(MNT_LOCAL), mountedBy: 0), "a network share")
    #expect(!FolderTrust.volumeIsTrusted(flags: root.f_flags | UInt32(MNT_IGNORE_OWNERSHIP), mountedBy: 0))
    // A disk image attached by this user is theirs; one another user attached (at a folder of
    // theirs) holds whatever owners they gave its files, this user's included.
    #expect(FolderTrust.volumeIsTrusted(flags: root.f_flags, mountedBy: getuid()))
    #expect(!FolderTrust.volumeIsTrusted(flags: root.f_flags, mountedBy: getuid() + 1))
}

@Test func aVolumeThatIgnoresOwnershipIsNotTrusted() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    let image = tree.root.appendingPathComponent("v.dmg"), mount = tree.root.appendingPathComponent("mnt")
    try tree.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "2m", "-fs", "HFS+", "-volname", "systattest", image.path])
    try tree.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-owners", "off", "-mountpoint", mount.path, image.path])
    defer { try? tree.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
    let apps = mount.appendingPathComponent("Apps")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: false)
    try tree.chmod(apps, 0o755)

    // Every file there reads as owned by whoever looks, so the mode bits protect nothing.
    #expect(!FolderTrust.onlyTrustedCanChange(apps))
}
