import Foundation

/// Whether a row gets Quit and Force Quit (spec: "Protected processes").
public enum Protection: Sendable, Equatable {
    case killable, macOS, notYours

    public var label: String? {
        switch self {
        case .killable: nil
        case .macOS: "macOS — protected"
        case .notYours: "system — not yours"
        }
    }

    /// User-owned processes whose death ends the session.
    public static let userDenyList: Set<String> = ["loginwindow"]

    private static let appleSystemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/"]

    public static func classify(uid: UInt32, currentUID: UInt32, pid: Int32, executablePath: String?, name: String) -> Protection {
        if pid == 0 || pid == 1 { return .macOS }
        if uid != currentUID {
            guard let path = executablePath else { return .macOS }
            return appleSystemPrefixes.contains { path.hasPrefix($0) } ? .macOS : .notYours
        }
        let executable = executablePath.map(Naming.basename)
        let denied = userDenyList.contains(name) || executable.map(userDenyList.contains) == true
        return denied ? .macOS : .killable
    }
}

/// What happened when systat signalled a process.
public enum KillOutcome: Sendable, Equatable {
    case sent, gone, failed(String)

    public init(errno code: Int32) {
        switch code {
        case 0: self = .sent
        case ESRCH: self = .gone
        case EPERM: self = .failed("Not permitted")
        default: self = .failed(String(cString: strerror(code)))
        }
    }
}
