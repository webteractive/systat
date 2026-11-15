import Foundation
import Testing
@testable import systat

/// Whether the system tool at `path` has more than one architecture, as the tests that pin each one
/// need: true on macOS 26 (arm64e and x86_64); a later macOS whose tools have one skips them.
func isUniversal(_ path: String) -> Bool {
    let lipo = Process(), out = Pipe()
    lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
    lipo.arguments = ["-archs", path]
    lipo.standardOutput = out
    lipo.standardError = FileHandle.nullDevice
    guard (try? lipo.run()) != nil else { return false }
    let archs = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    lipo.waitUntilExit()
    return lipo.terminationStatus == 0 && archs.split(separator: " ").count > 1
}

@Test func requirementBindsTheAppAndTheTeam() {
    #expect(CodeSigning.requirement(identifier: "dev.inggo.systat", team: "2VJCCC449X")
        == #"identifier "dev.inggo.systat" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2VJCCC449X" and notarized"#)
    for bad in ["", "2VJCCC449", "2VJCCC449XX", #"2VJCCC449""#, "2vjccc449x", "2VJCC 449X"] {
        #expect(CodeSigning.requirement(identifier: "dev.inggo.systat", team: bad) == nil, "\(bad)")
    }
    for bad in ["", #"dev.inggo.systat" or anchor apple"#, "dev inggo", "dev.inggo.systat\n"] {
        #expect(CodeSigning.requirement(identifier: bad, team: "2VJCCC449X") == nil, "\(bad)")
    }
}

@Test func theImageRequirementNamesOnlyTheTeam() {
    // The DMG's signing identifier comes from its file name, so only the team and notarization are required.
    #expect(CodeSigning.imageRequirement(team: "2VJCCC449X")
        == #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2VJCCC449X" and notarized"#)
    #expect(CodeSigning.imageRequirement(team: #"2VJCCC449""#) == nil)
}

@Test func anAdHocBundleFailsTheTeamRequirement() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("systat-sig-\(UUID().uuidString)/x.app")
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("x").path)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x", "CFBundleIdentifier": "x.test"],
                                       format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path])
    sign.waitUntilExit()
    #expect(sign.terminationStatus == 0)

    #expect(CodeSigning.satisfies(app, requirement: "anchor apple generic and certificate leaf[subject.OU] = \"2VJCCC449X\" and notarized") == false)
    #expect(CodeSigning.satisfies(app, requirement: "identifier \"x.test\""), "the ad-hoc signature itself is valid")
}

@Test(.enabled(if: isUniversal("/usr/bin/true"), "needs a universal /usr/bin/true"))
func aPinnedRequirementNamesEveryArchitecturesHash() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("systat-pin-\(UUID().uuidString)/x.app")
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("x").path)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x", "CFBundleIdentifier": "x.test"],
                                       format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path])
    sign.waitUntilExit()

    // /usr/bin/true is universal: two slices, two hashes, and codesign (which checks every
    // architecture) accepts the pinned requirement.
    #expect(CodeSigning.sliceOffsets(macOS.appendingPathComponent("x"))?.count == 2)
    let pinned = try #require(CodeSigning.pinned(#"identifier "x.test""#, to: app))
    #expect(pinned.components(separatedBy: "cdhash H").count == 3, "\(pinned)")
    #expect(CodeSigning.isExactly(app, requirement: pinned))
    let verify = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", "-R=" + pinned, app.path])
    verify.waitUntilExit()
    #expect(verify.terminationStatus == 0)

    // A single-architecture executable has one.
    let thin = try Process.run(URL(fileURLWithPath: "/usr/bin/lipo"), arguments: ["-thin", "arm64e", "/usr/bin/true", "-output", macOS.appendingPathComponent("x").path])
    thin.waitUntilExit()
    let resign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path])
    resign.waitUntilExit()
    #expect(CodeSigning.sliceOffsets(macOS.appendingPathComponent("x")) == nil)
    let one = try #require(CodeSigning.pinned(#"identifier "x.test""#, to: app))
    #expect(one.components(separatedBy: "cdhash H").count == 2)
    #expect(CodeSigning.isExactly(app, requirement: one))
}

@Test(.enabled(if: isUniversal("/usr/bin/true"), "needs a universal /usr/bin/true"))
func aPinMissingAnArchitectureIsRefused() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("systat-pin-\(UUID().uuidString)/x.app")
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("x").path)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x", "CFBundleIdentifier": "x.test"],
                                       format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path])
    sign.waitUntilExit()
    let pinned = try #require(CodeSigning.pinned(#"identifier "x.test""#, to: app))
    let hashes = pinned.components(separatedBy: " and (")[1].dropLast().components(separatedBy: " or ")
    #expect(hashes.count == 2)

    // Each architecture is checked on its own, so a pin naming only one hash passes only one of them.
    for hash in hashes {
        #expect(!CodeSigning.isExactly(app, requirement: #"identifier "x.test" and "# + hash))
    }
}

/// A universal header, built by hand.
private func fatHeader(magic: UInt32, slices: [UInt64], wide: Bool, count: UInt32? = nil) -> Data {
    var data = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    func put64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    put32(magic)
    put32(count ?? UInt32(slices.count))
    for offset in slices {
        put32(0x0100_000c); put32(0)          // cputype, cpusubtype
        if wide { put64(offset); put64(0x1000); put32(14); put32(0) } else { put32(UInt32(offset)); put32(0x1000); put32(14) }
    }
    return data
}

private func offsets(of header: Data, padTo size: Int = 0x10000) throws -> [UInt64]? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("systat-fat-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try (header + Data(count: max(0, size - header.count))).write(to: file)
    return CodeSigning.sliceOffsets(file)
}

@Test func sliceOffsetsReadBothUniversalFormats() throws {
    #expect(try offsets(of: fatHeader(magic: 0xcafebabe, slices: [0x4000, 0x8000], wide: false)) == [0x4000, 0x8000])
    #expect(try offsets(of: fatHeader(magic: 0xcafebabf, slices: [0x4000, 0x8000], wide: true)) == [0x4000, 0x8000])
}

@Test func malformedUniversalHeadersHaveNoOffsets() throws {
    #expect(try offsets(of: fatHeader(magic: 0xcafebabe, slices: [], wide: false)) == nil, "no slices")
    #expect(try offsets(of: fatHeader(magic: 0xcafebabe, slices: [0x4000], wide: false, count: 17), padTo: 0) == nil,
            "more slices than any real binary")
    #expect(try offsets(of: fatHeader(magic: 0xcafebabf, slices: [0x4000, 0x8000], wide: true).prefix(40), padTo: 0) == nil,
            "cut short")
    #expect(try offsets(of: fatHeader(magic: 0xcafebabe, slices: [0x4000, 0x20000], wide: false)) == nil,
            "a slice past the end of the file")
}
