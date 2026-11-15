import Foundation
import Testing
@testable import systat

/// The swap needs a volume that can exchange two folders in one rename. APFS can; HFS+ can't.
@Test func anAPFSFolderCanSwap() {
    #expect(UpdateInstaller.canSwap(at: FileManager.default.temporaryDirectory))
}

@Test func anAppOnAVolumeThatCantSwapIsRefusedBeforeAnythingIsDownloaded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("systat-hfs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("hfs.dmg"), mount = root.appendingPathComponent("mount")
    func hdiutil(_ args: [String]) throws -> Int32 {
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: args)
        p.waitUntilExit()
        return p.terminationStatus
    }
    try #require(try hdiutil(["create", "-quiet", "-size", "4m", "-fs", "HFS+", "-volname", "systat-hfs", image.path]) == 0)
    try #require(try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0)
    defer { _ = try? hdiutil(["detach", "-quiet", "-force", mount.path]) }
    let app = mount.appendingPathComponent("Apps/systat.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

    #expect(!UpdateInstaller.canSwap(at: app))
    #expect(throws: UpdateInstaller.Failure.cantSwap) { try UpdateInstaller.installTarget(app) }
}

@Test func anAppRunFromAReadOnlyImageIsAskedToMove() throws {
    // The image systat ships on can't swap either; moving it is what the user needs to hear.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("systat-ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("hfs.dmg"), mount = root.appendingPathComponent("mount")
    func hdiutil(_ args: [String]) throws -> Int32 {
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: args)
        p.waitUntilExit()
        return p.terminationStatus
    }
    try #require(try hdiutil(["create", "-quiet", "-size", "4m", "-fs", "HFS+", "-volname", "systat-ro", image.path]) == 0)
    try #require(try hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0)
    // Detached however this ends, even if it stops before the re-attach below (detaching twice is harmless).
    defer { _ = try? hdiutil(["detach", "-quiet", "-force", mount.path]) }
    try FileManager.default.createDirectory(at: mount.appendingPathComponent("systat.app"), withIntermediateDirectories: true)
    try #require(try hdiutil(["detach", "-quiet", "-force", mount.path]) == 0)
    try #require(try hdiutil(["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, image.path]) == 0)
    defer { _ = try? hdiutil(["detach", "-quiet", "-force", mount.path]) }

    #expect(throws: UpdateInstaller.Failure.mustMove) { try UpdateInstaller.installTarget(mount.appendingPathComponent("systat.app")) }
}
