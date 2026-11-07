import Foundation
import Testing
@testable import systat

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
