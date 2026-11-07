import Foundation
import Testing
@testable import SystatCore

@Test func semVerReadsReleaseTagsOnly() {
    #expect(SemVer("v1.2.3") == SemVer(major: 1, minor: 2, patch: 3))
    #expect(SemVer("0.10.0") == SemVer(major: 0, minor: 10, patch: 0))
    for bad in ["", "v", "1.2", "1.2.3.4", "1.2.3-beta", " 1.2.3", "1.2.3/../x", "1..2", "+1.2.3", "1.2.x", "unknown"] {
        #expect(SemVer(bad) == nil, "\(bad)")
    }
}

@Test func semVerOrdersNumerically() throws {
    #expect(try #require(SemVer("0.10.0")) > #require(SemVer("0.9.9")))
    #expect(try #require(SemVer("1.0.0")) > #require(SemVer("0.99.99")))
    #expect(try #require(SemVer("0.1.1")) > #require(SemVer("0.1.0")))
}

private func releaseJSON(tag: String, assets: [(String, String)]) -> Data {
    let list = assets.map { #"{"name": "\#($0.0)", "browser_download_url": "\#($0.1)"}"# }.joined(separator: ",")
    return Data(#"""
    {"tag_name": "\#(tag)", "html_url": "https://github.com/webteractive/systat/releases/tag/\#(tag)",
     "draft": false, "prerelease": false, "assets": [\#(list)]}
    """#.utf8)
}

private let download = "https://github.com/webteractive/systat/releases/download"

@Test func aNewerReleaseIsOfferedWithItsImageAndChecksum() throws {
    let json = releaseJSON(tag: "v0.2.0", assets: [
        ("systat-0.2.0.dmg", "\(download)/v0.2.0/systat-0.2.0.dmg"),
        ("systat-0.2.0.dmg.sha256", "\(download)/v0.2.0/systat-0.2.0.dmg.sha256"),
    ])
    let update = try #require(try UpdateCheck.evaluate(json, currentVersion: "0.1.0"))
    #expect(update.version == "0.2.0")
    #expect(update.releasePage.absoluteString == "https://github.com/webteractive/systat/releases/tag/v0.2.0")
    #expect(update.dmg?.absoluteString == "\(download)/v0.2.0/systat-0.2.0.dmg")
    #expect(update.checksum?.absoluteString == "\(download)/v0.2.0/systat-0.2.0.dmg.sha256")
    #expect(update.isInstallable)
}

@Test func noUpdateWhenCurrentOrAheadOrADevBuild() throws {
    let json = releaseJSON(tag: "v0.2.0", assets: [])
    #expect(try UpdateCheck.evaluate(json, currentVersion: "0.2.0") == nil)
    #expect(try UpdateCheck.evaluate(json, currentVersion: "0.3.0") == nil)
    #expect(try UpdateCheck.evaluate(json, currentVersion: "unknown") == nil)
}

@Test func onlyThisReleasesOwnAssetsOnGitHubCanBeInstalled() throws {
    // Wrong names, another repo, plain http and another host are all ignored: the update can
    // still be shown, but only as a link to the release page.
    let json = releaseJSON(tag: "v0.2.0", assets: [
        ("systat-0.1.9.dmg", "\(download)/v0.2.0/systat-0.1.9.dmg"),
        ("systat-0.2.0.dmg", "https://github.com/someone/else/releases/download/v0.2.0/systat-0.2.0.dmg"),
        ("systat-0.2.0.dmg", "http://github.com/webteractive/systat/releases/download/v0.2.0/systat-0.2.0.dmg"),
        ("systat-0.2.0.dmg.sha256", "https://evil.example/webteractive/systat/releases/download/v0.2.0/x"),
        ("systat-0.2.0.dmg", "https://github.com:444/webteractive/systat/releases/download/v0.2.0/systat-0.2.0.dmg"),
        ("systat-0.2.0.dmg", "https://x@github.com/webteractive/systat/releases/download/v0.2.0/systat-0.2.0.dmg"),
        ("systat-0.2.0.dmg.sha256", "https://x:y@github.com/webteractive/systat/releases/download/v0.2.0/systat-0.2.0.dmg.sha256"),
    ])
    let update = try #require(try UpdateCheck.evaluate(json, currentVersion: "0.1.0"))
    #expect(update.dmg == nil && update.checksum == nil)
    #expect(!update.isInstallable)
}

@Test func aMalformedReleaseIsAnError() {
    #expect(throws: (any Error).self) { try UpdateCheck.evaluate(Data("{}".utf8), currentVersion: "0.1.0") }
    #expect(throws: (any Error).self) { try UpdateCheck.evaluate(Data("not json".utf8), currentVersion: "0.1.0") }
    #expect(throws: (any Error).self) {
        try UpdateCheck.evaluate(releaseJSON(tag: "v0.2.0/../../x", assets: []), currentVersion: "0.1.0")
    }
}

@Test func theStagedAppMustBeTheReleasedVersion() {
    let update = AvailableUpdate(version: "0.2.0", releasePage: UpdateCheck.releasesPage, dmg: nil, checksum: nil)
    #expect(update.isRelease(of: "0.2.0"))
    // An old build re-tagged as new, or an app with no version, is refused.
    #expect(!update.isRelease(of: "0.1.0"))
    #expect(!update.isRelease(of: "0.2.1"))
    #expect(!update.isRelease(of: nil))
    #expect(!update.isRelease(of: "0.2.0-beta"))
}

@Test func checksumMatchesOnlyTheExactDigest() {
    let data = Data("systat".utf8)
    let hex = UpdateChecksum.sha256Hex(data)
    #expect(hex.count == 64)
    #expect(UpdateChecksum.matches(data, published: hex))
    #expect(UpdateChecksum.matches(data, published: hex.uppercased() + "\n"))
    #expect(UpdateChecksum.matches(data, published: "\(hex)  systat-0.2.0.dmg\n"))
    #expect(!UpdateChecksum.matches(data, published: ""))
    #expect(!UpdateChecksum.matches(data, published: String(hex.dropLast())))
    #expect(!UpdateChecksum.matches(Data("other".utf8), published: hex))
}

@Test func aFileHashesInChunksToTheSameDigest() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("systat-hash-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 * 7) })   // spans several chunks
    try data.write(to: url)
    #expect(try UpdateChecksum.sha256Hex(fileAt: url) == UpdateChecksum.sha256Hex(data))
}

@Test func theReleaseLinkStaysOnThisRepo() throws {
    // A hostile answer can't make "Download systat X" open someone else's page.
    let json = Data(#"""
    {"tag_name": "v0.2.0", "html_url": "https://github.com/attacker/systat/releases/tag/v0.2.0", "assets": []}
    """#.utf8)
    let update = try #require(try UpdateCheck.evaluate(json, currentVersion: "0.1.0"))
    #expect(update.releasePage == UpdateCheck.releasesPage)

    // Nor can a path that starts on this repo and climbs out of it.
    for page in ["https://github.com/webteractive/systat/releases/../../attacker/x",
                 "https://github.com/webteractive/systat/releases/%2e%2e/%2e%2e/attacker/x",
                 "https://github.com:444/webteractive/systat/releases/tag/v0.2.0"] {
        let json = Data(#"{"tag_name": "v0.2.0", "html_url": "\#(page)", "assets": []}"#.utf8)
        #expect(try UpdateCheck.evaluate(json, currentVersion: "0.1.0")?.releasePage == UpdateCheck.releasesPage, "\(page)")
    }
}

private func stream(_ count: Int) -> AsyncStream<UInt8> {
    AsyncStream { continuation in
        for i in 0..<count { continuation.yield(UInt8(truncatingIfNeeded: i)) }
        continuation.finish()
    }
}

@Test func aCappedReadStopsAtTheLimit() async throws {
    #expect(try await CappedRead.data(stream(100), limit: 100).count == 100)
    await #expect(throws: CappedRead.TooLarge.self) { try await CappedRead.data(stream(101), limit: 100) }
}

@Test func aCappedDownloadWritesEverythingUpToTheLimit() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("systat-capped-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    let count = 300_000   // spans several chunks
    try await CappedRead.write(stream(count), to: url, limit: count)
    #expect(try Data(contentsOf: url) == Data((0..<count).map { UInt8(truncatingIfNeeded: $0) }))

    await #expect(throws: CappedRead.TooLarge.self) { try await CappedRead.write(stream(count + 1), to: url, limit: count) }
}
