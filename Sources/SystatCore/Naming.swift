import Foundation

/// Row names and second lines (spec: "Telling same-name processes apart").
public enum Naming {
    public static func displayName(_ r: ProcessRecord) -> String {
        if let app = r.app { return app.name }
        if let argv0 = r.arguments?.first, !argv0.isEmpty { return basename(argv0) }
        if let path = r.executablePath, !path.isEmpty { return basename(path) }
        return r.commandName
    }

    public static func isClaude(_ r: ProcessRecord) -> Bool {
        r.app == nil && displayName(r) == "claude"
    }

    public static func claudeLabel(arguments: [String]?, workingDirectory: String?, pid: Int32) -> String {
        var name: String?
        var resumeID: String?
        var resumedBare = false
        let args = Array((arguments ?? []).dropFirst())
        var i = 0
        func value(after index: Int) -> String? {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { return nil }
            return args[index + 1]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-n", "--name":
                if let v = value(after: i) { name = name ?? v; i += 1 }
            case "-r", "--resume":
                if let v = value(after: i) { resumeID = resumeID ?? v; i += 1 } else { resumedBare = true }
            case "-c", "--continue":
                resumedBare = true
            default:
                if arg.hasPrefix("--name="), name == nil {
                    let v = String(arg.dropFirst("--name=".count))
                    if !v.isEmpty { name = v }
                } else if arg.hasPrefix("--resume="), resumeID == nil {
                    let v = String(arg.dropFirst("--resume=".count))
                    if v.isEmpty { resumedBare = true } else { resumeID = v }
                }
            }
            i += 1
        }
        let folder = projectFolder(workingDirectory)
        if let name { return name }
        if let resumeID { return "session " + resumeID.prefix(8) }
        if resumedBare { return folder.map { "resumed · " + $0 } ?? "resumed" }
        return folder ?? "pid \(pid)"
    }

    public static func detail(for r: ProcessRecord, name: String, nameIsShared: Bool, home: String, now: Date) -> String {
        let base = baseDetail(for: r, name: name, nameIsShared: nameIsShared, home: home)
        guard let age = Format.age(since: r.startDate, now: now) else { return base }
        return base + " · " + age
    }

    public static let wellKnown: [String: String] = [
        "fseventsd": "File change tracker",
        "WindowServer": "Display server",
        "airportd": "Wi-Fi daemon",
        "kernel_task": "macOS kernel",
        "launchd": "Service manager",
        "mds": "Spotlight",
        "mds_stores": "Spotlight index",
        "mdworker_shared": "Spotlight indexer",
        "coreaudiod": "Audio",
        "bluetoothd": "Bluetooth",
        "cloudd": "iCloud sync",
        "backupd": "Time Machine",
        "photoanalysisd": "Photos analysis",
        "loginwindow": "Login session",
        "Dock": "Dock",
        "Finder": "Finder",
        "softwareupdated": "Software Update",
    ]

    private static func baseDetail(for r: ProcessRecord, name: String, nameIsShared: Bool, home: String) -> String {
        if isClaude(r) {
            return claudeLabel(arguments: r.arguments, workingDirectory: r.workingDirectory, pid: r.identity.pid)
        }
        let location = r.app?.bundlePath ?? r.executablePath
        if nameIsShared, let location, !isStandard(location, home: home) {
            return abbreviate(parent(location), home: home)
        }
        if let known = wellKnown[name] { return known }
        if let location { return abbreviate(parent(location), home: home) }
        return "pid \(r.identity.pid)"
    }

    private static func isStandard(_ path: String, home: String) -> Bool {
        let prefixes = ["/Applications/", "/System/", "/usr/", "/bin/", "/sbin/", "/Library/", home + "/Applications/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    private static func projectFolder(_ cwd: String?) -> String? {
        guard let cwd, cwd != "/", !cwd.isEmpty else { return nil }
        let last = basename(cwd)
        return last.isEmpty ? nil : last
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
