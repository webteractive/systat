import AppKit
import SystatCore

/// From Info.plist: the bundle's, or the copy embedded in the binary (see Package.swift).
/// The commit and date are stamped into the bundle by scripts/build-app.sh.
let info = Bundle.main.infoDictionary ?? [:]
let systatVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"

let arguments = CommandLine.arguments
if ["--version", "-v", "version"].contains(arguments.dropFirst().first ?? "") {
    print(Format.versionLine(version: systatVersion, commit: info["SystatBuildCommit"] as? String,
                             date: info["SystatBuildDate"] as? String))
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    systat \(systatVersion): menu bar monitor for memory, CPU and disk.

    Run with no arguments to start the menu bar app.
      --sample           print one reading of the bars and top-10 lists, then exit
      --snapshot <dir>   render the panel, icons and Settings to PNGs in <dir>, then exit
      --bench [seconds]  measure CPU use with the menu closed, then open (default 30 s each), then exit
      --iconset <dir>    write the app icon's PNGs as an iconset into <dir> (for iconutil), then exit
      --version, -v      print the version, and the commit and build date of a packaged build
      --help             show this help
    """)
    exit(0)
}
if arguments.contains("--sample") {
    exit(await SampleDump.run())
}
if let flag = arguments.firstIndex(of: "--bench") {
    let seconds = flag + 1 < arguments.count ? Double(arguments[flag + 1]) ?? 30 : 30
    exit(await Bench.run(seconds: seconds))
}
if let flag = arguments.firstIndex(of: "--iconset") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("systat: --iconset needs a directory\n".utf8))
        exit(2)
    }
    do {
        try AppIcon.writeIconset(to: URL(fileURLWithPath: arguments[flag + 1]))
    } catch {
        FileHandle.standardError.write(Data("systat: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}
if let flag = arguments.firstIndex(of: "--snapshot") {
    guard flag + 1 < arguments.count else {
        FileHandle.standardError.write(Data("systat: --snapshot needs a directory\n".utf8))
        exit(2)
    }
    exit(await SnapshotDump.run(directory: arguments[flag + 1]))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
