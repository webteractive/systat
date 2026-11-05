import AppKit

let systatVersion = "0.1.0"

let arguments = CommandLine.arguments
if arguments.contains("--version") {
    print("systat \(systatVersion)")
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    systat \(systatVersion): menu bar monitor for memory, CPU and disk.

    Run with no arguments to start the menu bar app.
      --sample           print one reading of the bars and top-10 lists, then exit
      --snapshot <dir>   render the panel, icons and Settings to PNGs in <dir>, then exit
      --bench [seconds]  measure CPU use with the menu closed, then open (default 30 s each), then exit
      --version          print the version
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
