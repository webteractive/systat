import Foundation
import Testing
@testable import systat

/// The swap leaves the app's slot empty for a moment, then opens whatever is there. Anyone who
/// can rename entries in the app's folder, or any folder above it, could fill that slot.
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

    func cleanUp() {
        try? chmod(root, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func aFolderOnlyThisUserCanChangeIsTrusted() throws {
    let tree = try Tree()
    defer { tree.cleanUp() }
    #expect(FolderTrust.onlyTrustedCanChange(tree.apps))
}

@Test func rootAndAdminFoldersAreTrusted() {
    // Admins can become root anyway, so /Applications (root:admin, group-writable) counts.
    #expect(FolderTrust.onlyTrustedCanChange(URL(fileURLWithPath: "/Applications")))
}

@Test func aFolderOthersCanWriteToIsNotTrusted() throws {
    for mode in [0o775, 0o757, 0o777, 0o1777] {
        let tree = try Tree()
        defer { tree.cleanUp() }
        try tree.chmod(tree.apps, mode)
        #expect(!FolderTrust.onlyTrustedCanChange(tree.apps), "mode \(String(mode, radix: 8))")
    }
    // World-writable with the sticky bit: anyone can create the app's name once the slot is empty.
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
