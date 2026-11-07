import CryptoKit
import Foundation

/// A release version: exactly MAJOR.MINOR.PATCH in digits, with an optional leading "v".
/// Anything else (a dev build's "unknown", a pre-release, a tag with a path in it) is not one.
public struct SemVer: Comparable, Hashable, Sendable {
    public let major: Int, minor: Int, patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    public init?(_ text: String) {
        let body = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCIIDigit) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// A newer release than the one running.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let releasePage: URL
    /// The release's `systat-<version>.dmg` and its `.sha256`, when both are there.
    public let dmg: URL?
    public let checksum: URL?

    public init(version: String, releasePage: URL, dmg: URL?, checksum: URL?) {
        (self.version, self.releasePage, self.dmg, self.checksum) = (version, releasePage, dmg, checksum)
    }

    /// In-place install needs the image and its checksum; otherwise the release page is offered.
    public var isInstallable: Bool { dmg != nil && checksum != nil }

    /// Whether a bundle claiming `bundleVersion` is this release. The checksum comes from the same
    /// release as the image, so it can't catch an old signed build re-tagged as new; this can.
    public func isRelease(of bundleVersion: String?) -> Bool {
        guard let bundleVersion, let theirs = SemVer(bundleVersion) else { return false }
        return theirs == SemVer(version)
    }
}

/// Reads GitHub's "latest release" answer for webteractive/systat.
public enum UpdateCheck {
    public static let repo = "webteractive/systat"
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    public enum Failure: Error { case notAVersion(String) }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
        }
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url", assets }
    }

    /// The update to offer, or nil when `currentVersion` is as new or newer, or is not a release
    /// version (a dev build is never behind). Throws when the answer isn't a release.
    public static func evaluate(_ json: Data, currentVersion: String) throws -> AvailableUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: json)
        guard let latest = SemVer(release.tagName) else { throw Failure.notAVersion(release.tagName) }
        guard let current = SemVer(currentVersion), latest > current else { return nil }

        let version = latest.description
        // Only this repo's releases: the page is what "Download systat X" opens.
        let page = URL(string: release.htmlURL).flatMap(onGitHub)
            .flatMap { $0.path.hasPrefix("/\(repo)/releases/") ? $0 : nil } ?? releasesPage
        // Allowlist: this repo's download path for this tag, over https, under the exact name
        // package.sh gives each file. Anything else is ignored rather than fetched.
        let prefix = "/\(repo)/releases/download/\(release.tagName)/"
        func asset(_ name: String) -> URL? {
            release.assets.lazy
                .filter { $0.name == name }
                .compactMap { URL(string: $0.browserDownloadURL).flatMap(onGitHub) }
                .first { $0.path == prefix + name }
        }
        let dmgName = "systat-\(version).dmg"
        return AvailableUpdate(version: version, releasePage: page,
                               dmg: asset(dmgName), checksum: asset(dmgName + ".sha256"))
    }

    private static func onGitHub(_ url: URL) -> URL? {
        url.scheme == "https" && url.host == "github.com" ? url : nil
    }
}

public enum UpdateChecksum {
    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Hashes a file in 1 MB chunks, so a large download is never held in memory.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True when `data` hashes to the published digest: the first word of the .sha256 file,
    /// in either case. An empty or partial digest never matches.
    public static func matches(_ data: Data, published: String) -> Bool {
        matches(digest: sha256Hex(data), published: published)
    }

    public static func matches(digest: String, published: String) -> Bool {
        guard let expected = published.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              expected.count == 64 else { return false }
        return digest == expected
    }
}
