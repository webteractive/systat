import Foundation
import Testing
@testable import systat

/// install.sh's own functions, run by /bin/sh as the installer runs them: the script without its
/// last line (`{ main "$@"; }`), then the commands under test.
private func installer(_ commands: String, input: Data = Data()) throws -> Data {
    let p = try installerProcess(commands)
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    try p.run()
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    return out
}

/// `sh -c` running install.sh's functions, then `commands`; not started yet.
private func installerProcess(_ commands: String) throws -> Process {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../install.sh").standardizedFileURL
    let body = try String(contentsOf: script, encoding: .utf8)
    var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    while lines.last?.isEmpty == true { lines.removeLast() }
    try #require(lines.last == #"{ main "$@"; }"#)
    lines.removeLast()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", lines.joined(separator: "\n") + "\n" + commands]
    return p
}

@Test(arguments: ["0.1.2", "10.0.0", "123456.0.0"])
func theInstallerTakesAVersion(_ version: String) throws {
    #expect(try installer(#"is_version '\#(version)' && echo yes"#) == Data("yes\n".utf8))
}

@Test(arguments: ["", "1.2", "1.2.3.4", "1.2.3a", ".1.2", "1..2", "1.2.3.", "1234567.0.0", "v1.2.3", "1.2.3/..", "1.2.3 "])
func theInstallerRefusesWhatIsntAVersion(_ text: String) throws {
    #expect(try installer(#"is_version "$(printf '%s' '\#(text)')" || echo no"#) == Data("no\n".utf8))
}

@Test func theInstallerComparesVersionsByNumber() throws {
    let pairs = [("0.1.1", "0.1.2", true), ("0.1.2", "0.1.2", false), ("0.1.10", "0.1.9", false),
                 ("0.9.9", "0.10.0", true), ("1.0.0", "0.99.99", false), ("009.0.0", "10.0.0", true)]
    for (a, b, isOlder) in pairs {
        let out = try installer("if older \(a) \(b); then echo older; else echo not; fi")
        #expect(out == Data((isOlder ? "older\n" : "not\n").utf8), "\(a) vs \(b)")
    }
}

@Test func theInstallerPrintsANoteAsPlainText() throws {
    // C0 and C1 controls go (a terminal may act on either), and characters that reverse how the
    // line reads or hide; a tab, line break or separator becomes a space. é and a no-break space stay.
    let note = "failed: a\u{9B}31mb\u{1B}[2J\u{202E}c\u{2066}d\u{200F}e\u{FEFF}f\u{07}\tg\nh\u{2028}i é\u{A0}j\n"
    let out = try installer("plain", input: Data(note.utf8))
    #expect(String(decoding: out, as: UTF8.self) == "failed: a31mb[2Jcdef g h i é\u{A0}j")
}

@Test func theInstallerLeavesOutWhatIsntUTF8InANote() throws {
    // As the app does: the rest of the note stays, é included, and a character cut short goes.
    let out = try installer("plain", input: Data([0x66, 0x3A, 0x20, 0x78, 0x9B, 0x79, 0xFF, 0x7A, 0x0A, 0xC3, 0xA9, 0x20, 0xC3]))
    #expect(out == Data("f: xyz é".utf8))
}

@Test func theInstallerDropsEveryFormatCharacterTheAppDrops() throws {
    // Every character in Unicode's format category (Cf), which the app leaves out of a note.
    let format = (0...0x10FFFF).compactMap(Unicode.Scalar.init).filter { $0.properties.generalCategory == .format }
    #expect(format.count > 150)
    var note = String.UnicodeScalarView()
    for scalar in format { note.append("x"); note.append(scalar) }
    let out = try installer("plain", input: Data(("failed: " + String(note)).utf8))
    let text = String(decoding: out, as: UTF8.self)
    #expect(text == "failed: " + String(repeating: "x", count: format.count),
            "left in: \(text.unicodeScalars.filter { $0 != "x" }.map { String($0.value, radix: 16) })")
}

@Test func theInstallerPrintsANoteAsTheAppShowsIt() throws {
    // The same filter both ways: whatever a note holds, the installer prints what the panel shows.
    var note = String.UnicodeScalarView()
    let spaces = (0...0x10FFFF).compactMap(Unicode.Scalar.init).filter { $0.properties.generalCategory == .spaceSeparator }
    note.append(contentsOf: spaces)
    note.append(contentsOf: "failed: a\u{FFFD}b\u{9B}c\u{202E}d\te\u{2028}f\u{1F600}g é\u{A0}h".unicodeScalars)
    note.append(contentsOf: spaces)
    note.append("\n")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-note-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = folder.appendingPathComponent("result")
    // Bytes that aren't UTF-8: a stray lead, past U+10FFFF, a five-byte form, a control inside a
    // character, and a character cut short at the end.
    let bytes = Data(String(note).utf8) + Data([0x20, 0xFF, 0xC3, 0x79, 0xF4, 0x90, 0x80, 0x80, 0x79, 0xF8, 0x88, 0x80, 0x80, 0x80,
                                                0x79, 0xC3, 0x01, 0xA9, 0x7A, 0xE2, 0x62])
    try bytes.write(to: result)

    let shown = try #require(UpdateInstaller.lastResult(from: [result]))
    let printed = String(decoding: try installer("plain", input: bytes), as: UTF8.self)
    #expect(printed == shown)
}

@Test(arguments: [("404", 22, "has no systat-0.1.2.dmg"), ("404", 56, "has no systat-0.1.2.dmg"),
                  ("503", 22, "HTTP 503"), ("403", 22, "rate limit"), ("429", 22, "rate limit"),
                  ("200", 63, "far too large"), ("000", 28, "timed out"), ("000", 6, "curl error 6")])
func theInstallerSaysWhyADownloadFailed(_ code: String, _ status: Int32, _ says: String) throws {
    // Not blamed on the release when the network or GitHub failed, nor on the network when the
    // release did. (With redirects, a 404 can come back as curl error 56.)
    let out = try installer("""
        curl() { printf '%s' '\(code)'; return \(status); }
        version=0.1.2
        (fetch https://github.com/x "$TMPDIR/none" 1024 "$download_patience" "release v0.1.2 has no systat-0.1.2.dmg" "systat-0.1.2.dmg") 2>&1 || true
        """)
    #expect(String(decoding: out, as: UTF8.self).contains(says))
}

@Test func theInstallerWorksOnlyInAFolderNoOneElseCanChange() throws {
    // As the updater requires of its own: anyone else who could change it, or a folder above it, by
    // permissions or by an ACL that would pass on to the new copy, could swap or rewrite it.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-trust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    func trusted(after change: String) throws -> Bool {
        let out = try installer("""
            f='\(folder.path)'
            /bin/chmod -N "$f"; /bin/chmod 0700 "$f"
            \(change)
            volume_trusted() { return 0; }
            if only_trusted_can_change "$f"; then echo yes; else echo no; fi
            """)
        return out == Data("yes\n".utf8)
    }
    #expect(try trusted(after: ""))
    #expect(try trusted(after: #"/bin/chmod +a "group:everyone deny delete" "$f""#), "a deny entry takes nothing away")
    #expect(try trusted(after: #"/bin/chmod +a "user:$(id -un) allow add_file,delete_child" "$f""#), "names only this user")
    #expect(try !trusted(after: #"/bin/chmod g+w "$f""#))
    #expect(try !trusted(after: #"/bin/chmod o+w "$f""#))
    #expect(try !trusted(after: #"/bin/chmod +a "group:everyone allow add_file" "$f""#))
    #expect(try !trusted(after: #"/bin/chmod +a "group:staff allow delete_child,file_inherit,directory_inherit" "$f""#))
    #expect(try !trusted(after: #"/bin/chmod +a "group:everyone allow writesecurity" "$f""#))
    #expect(try !trusted(after: #"/bin/chmod 0700 "$f"; f="$f/none""#), "a folder that isn't there")
}

@Test func theInstallersVolumeCheckIgnoresAForgedMountLine() throws {
    // Asked of the kernel and the system, not read from mount's text, where a mount point can hold a
    // line break and forge a mount line for another folder.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-volume-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    let image = box.appendingPathComponent("v.dmg").path
    func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    func trusted(_ path: String) throws -> Bool {
        try installer("if volume_trusted \"$(printf '%s' '\(path)')\"; then echo yes; else echo no; fi") == Data("yes\n".utf8)
    }
    try #require(try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "V", image]) == 0)
    let loose = box.appendingPathComponent("loose").path
    let forged = box.appendingPathComponent("a\n/dev/disk99 on \(box.path)").path
    try fm.createDirectory(atPath: loose, withIntermediateDirectories: false)
    try fm.createDirectory(atPath: forged, withIntermediateDirectories: true)
    try #require(try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-owners", "off", "-mountpoint", loose, image]) == 0)
    defer {
        _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", loose])
        try? fm.removeItem(at: box)
    }

    // Every disk image is refused (another user could attach one), so these two show that, not the
    // ownership rule: theInstallerRefusesADriveThatIgnoresOwnership covers that with diskutil stubbed.
    #expect(try trusted(box.path))
    #expect(try !trusted(loose), "a disk image, ignoring ownership too")
    try fm.createDirectory(atPath: loose + "/inside", withIntermediateDirectories: false)
    #expect(try !trusted(loose + "/inside"), "below it too")

    // Another user's image mounted at a path holding a line break, ending its mount line as one for
    // this folder with options of their choosing (here: ignoring ownership).
    try #require(try run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", loose]) == 0)
    try #require(try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-owners", "off", "-mountpoint", forged, image]) == 0)
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", forged]) }
    #expect(try trusted(box.path), "a forged mount line changes nothing")
}

@Test func theInstallersFolderCheckLooksAtTheVolume() throws {
    // Every folder above passes by owner and permissions, but the volume doesn't.
    let out = try installer(#"volume_trusted() { return 1; }; if only_trusted_can_change "$TMPDIR"; then echo yes; else echo no; fi"#)
    #expect(out == Data("no\n".utf8))
}

@Test func theInstallerTakesACopyThatIsntTheBuildCheckedOutOfReach() throws {
    // Out of /Applications, into the work folder; or, if it can't be moved, with nothing in it
    // executable, links left alone.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-reject-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    let out = try installer("""
        dest='\(box.path)/Applications/systat.app'; work='\(box.path)/work'
        mkdir -p "$dest/Contents/MacOS" "$work" '\(box.path)/elsewhere'
        cp /usr/bin/true "$dest/Contents/MacOS/evil"; cp /usr/bin/true '\(box.path)/elsewhere/tool'
        ln -s '\(box.path)/elsewhere/tool' "$dest/Contents/MacOS/systat"
        reject_dest; [ ! -e "$dest" ] && [ -x "$work/rejected.app/Contents/MacOS/evil" ] && echo moved
        mkdir -p "$dest/Contents/MacOS"; cp /usr/bin/true "$dest/Contents/MacOS/evil"
        ln -s '\(box.path)/elsewhere/tool' "$dest/Contents/MacOS/systat"
        reject_dest; [ -e "$dest" ] && [ ! -x "$dest/Contents/MacOS/evil" ] && echo disabled
        [ -x '\(box.path)/elsewhere/tool' ] && echo "link left alone"
        """)
    #expect(String(decoding: out, as: UTF8.self) == "moved\ndisabled\nlink left alone\n")
}

@Test func theInstallersLastCheckGetsASecondTry() throws {
    // codesign killed when memory is short, say, would otherwise take a good copy out of the way:
    // as the relaunch helper does, a failed check is tried again a second later.
    let flag = FileManager.default.temporaryDirectory.appendingPathComponent("systat-once-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: flag) }
    let once = try installer("""
        this_build=x
        codesign() { [ -e '\(flag)' ] && return 0; : > '\(flag)'; return 1; }
        if is_this_build; then echo yes; else echo no; fi
        """)
    #expect(once == Data("yes\n".utf8))
    let never = try installer("this_build=x; codesign() { return 1; }; if is_this_build; then echo yes; else echo no; fi")
    #expect(never == Data("no\n".utf8))
}

@Test func theInstallerWaitsForAnUpdateSystatIsMakingItself() throws {
    // Each would take the other's copy for one it can replace: the updater's own lock, a flock,
    // is seen from the shell.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-ulock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lock = folder.appendingPathComponent("lock")
    func busy() throws -> Bool {
        try installer("if updater_busy '\(lock.path)'; then echo yes; else echo no; fi") == Data("yes\n".utf8)
    }
    func status() throws -> String {
        String(decoding: try installer("if updater_busy '\(lock.path)'; then echo 0; else echo $?; fi"), as: UTF8.self)
    }

    #expect(try !busy(), "no lock file: no update")
    var held: UpdateInstaller.Lock? = try UpdateInstaller.Lock.take(lock)
    #expect(try busy())
    withExtendedLifetime(held) {}
    held = nil
    var free = false
    for _ in 0..<50 where !free {
        free = try !busy()
        if !free { Thread.sleep(forTimeInterval: 0.02) }
    }
    #expect(free, "free again once the update lets go")
    #expect(FileManager.default.fileExists(atPath: lock.path), "the probe leaves the updater's lock file")

    // One it can't open isn't an update under way: said otherwise.
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lock.path)
    #expect(try status() == "2\n")
    #expect(try status() != "0\n")
}

@Test func theInstallerQuitsOnlyTheAppNotSystatsCommandLineModes() throws {
    // systat --bench or --sample runs the same executable: only the app counts as running, and only
    // the copy at the very path asked about (not ~/Applications/systat.app for /Applications/systat.app).
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-running-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    // Not a .app, nor anything on disk: a process whose command line is exactly that of an app at
    // <path> (exec -a), waiting on its input.
    let app = box.appendingPathComponent("x/Applications/fake").path
    // Its path ends with the one asked about, as ~/Applications/systat.app ends with /Applications/systat.app.
    let elsewhere = box.path + "/home" + app
    // Each fake's bundle says it is systat, as the app's does (a folder of the test's, not a .app).
    func bundle(_ path: String, id: String = "dev.inggo.systat") throws {
        let contents = URL(fileURLWithPath: path).appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
    func waitForCommandLine(_ p: Process, _ want: String) throws {
        var seen = false
        for _ in 0..<1000 where !seen {
            let ps = Process(), out = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "command=", "-p", String(p.processIdentifier)]
            ps.standardOutput = out
            try ps.run()
            let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            ps.waitUntilExit()
            seen = line.trimmingCharacters(in: .whitespacesAndNewlines) == want
            if !seen { usleep(10_000) }
        }
        try #require(seen, "\(want)")
    }
    func start(_ path: String, _ args: [String]) throws -> (Process, Pipe) {
        let p = Process(), feed = Pipe()
        // bash: exec -a isn't POSIX, and /bin/sh may be dash.
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"exec -a "$0" /bin/cat "$@""#, path + "/Contents/MacOS/systat"] + args
        p.standardInput = feed
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        // Until its command line is the one it was given; without that, the checks below prove nothing.
        try waitForCommandLine(p, ([path + "/Contents/MacOS/systat"] + args).joined(separator: " "))
        return (p, feed)
    }
    try bundle(app)
    try bundle(elsewhere)
    func running(_ path: String) throws -> Bool {
        try installer("me=$(id -u); if app_running '\(path)'; then echo yes; else echo no; fi") == Data("yes\n".utf8)
    }
    // A command-line mode: systat --sample. (perl, which, unlike cat, runs on with --sample after it.)
    let mode: (Process, Pipe) = try {
        let p = Process(), feed = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"exec -a "$0" /usr/bin/perl -e '<STDIN>' -- --sample"#, app + "/Contents/MacOS/systat"]
        p.standardInput = feed
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        try waitForCommandLine(p, app + "/Contents/MacOS/systat -e <STDIN> -- --sample")
        return (p, feed)
    }()
    #expect(try !running(app), "a command-line mode isn't the app")
    let other = try start(elsewhere, [])
    #expect(try !running(app), "a copy elsewhere isn't the one at this path")
    #expect(try running(elsewhere))
    let real = try start(app, [])
    #expect(try running(app))

    // Something else given systat's path (a debugger, say) isn't the app, though its command line ends
    // in it: its argv[0] is its own. Nor is an app whose executable is called systat but whose bundle
    // isn't systat's. Listed unscoped (listing kills nothing), as the scoped check would leave both
    // out anyway.
    let debugger = Process(), feed = Pipe()
    debugger.executableURL = URL(fileURLWithPath: "/bin/bash")
    debugger.arguments = ["-c", #"exec -a /usr/bin/lldb /bin/cat - "$0""#, app + "/Contents/MacOS/systat"]
    debugger.standardInput = feed
    debugger.standardOutput = FileHandle.nullDevice
    debugger.standardError = FileHandle.nullDevice
    try debugger.run()
    try waitForCommandLine(debugger, "/usr/bin/lldb - " + app + "/Contents/MacOS/systat")
    let notSystat = box.appendingPathComponent("x/Other/fake").path
    try bundle(notSystat, id: "com.example.other")
    let impostor = try start(notSystat, [])
    let listed = String(decoding: try installer("me=$(id -u); app_pids"), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    #expect(listed.contains(String(real.0.processIdentifier)))
    #expect(!listed.contains(String(debugger.processIdentifier)))
    #expect(!listed.contains(String(impostor.0.processIdentifier)))
    #expect(!listed.contains(String(mode.0.processIdentifier)))
    // A systat whose bundle was moved or trashed while it ran still counts: nothing at its path to read.
    let gone = try start(box.appendingPathComponent("trashed/fake").path, [])
    let withGone = String(decoding: try installer("me=$(id -u); app_pids"), as: UTF8.self)
    #expect(withGone.split(separator: "\n").map(String.init).contains(String(gone.0.processIdentifier)))
    try gone.1.fileHandleForWriting.close()
    gone.0.waitUntilExit()
    // Nor one whose bundle is half removed: Contents left, but no Info.plist to read.
    let half = box.appendingPathComponent("half/fake").path
    try fm.createDirectory(atPath: half + "/Contents/MacOS", withIntermediateDirectories: true)
    let halfRun = try start(half, [])
    let withHalf = String(decoding: try installer("me=$(id -u); app_pids"), as: UTF8.self)
    #expect(withHalf.split(separator: "\n").map(String.init).contains(String(halfRun.0.processIdentifier)))
    try halfRun.1.fileHandleForWriting.close()
    halfRun.0.waitUntilExit()
    // Quitting the app at that path stops it, and only it.
    _ = try installer("me=$(id -u); quit_systat '\(app)'")
    for _ in 0..<1000 where real.0.isRunning { usleep(10_000) }
    // Stopped by the script, not by the cleanup below.
    let quitByScript = !real.0.isRunning
    if real.0.isRunning { real.0.terminate() }
    real.0.waitUntilExit()
    #expect(quitByScript)
    #expect(real.0.terminationReason == .uncaughtSignal)
    #expect(mode.0.isRunning && other.0.isRunning && debugger.isRunning && impostor.0.isRunning)
    for (p, feed) in [mode, other, impostor, (debugger, feed)] { try feed.fileHandleForWriting.close(); p.waitUntilExit() }
    try real.1.fileHandleForWriting.close()
}

@Test func theInstallersLockIsAFlockThatGoesWithIt() throws {
    // Held on a descriptor for as long as the installer runs, refused to a second one, and gone when
    // it ends, however it ends: no process ID to outlive it or be reused.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-ilock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lock = folder.appendingPathComponent("systat-install.lock").path
    let out = try installer("""
        if take_install_lock '\(lock)'; then echo taken; fi
        ( if take_install_lock '\(lock)'; then echo again; else echo "refused $?"; fi )
        """)
    #expect(out == Data("taken\nrefused 1\n".utf8))
    // Private: another user who could open it could hold it, and stop every install and update.
    let mode = try FileManager.default.attributesOfItem(atPath: lock)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // Let go when the script ended (at once with lockf's descriptor form; within half a second with
    // the perl holder an older macOS uses).
    var gone = false
    for _ in 0..<40 where !gone {
        gone = !UpdateInstaller.installerIsRunning(URL(fileURLWithPath: lock))
        if !gone { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(gone, "let go when the script ended")
    // As soon as a probe or another test's child lets go of it (see InPlaceSwapTests).
    var held: UpdateInstaller.Lock?
    for _ in 0..<50 where held == nil {
        held = try? UpdateInstaller.Lock.take(URL(fileURLWithPath: lock))
        if held == nil { Thread.sleep(forTimeInterval: 0.02) }
    }
    let mine = try #require(held)
    #expect(try installer("if take_install_lock '\(lock)'; then echo taken; else echo \"refused $?\"; fi") == Data("refused 1\n".utf8),
            "the same kind of lock the updater takes")
    withExtendedLifetime(mine) {}
}

@Test func theInstallerRefusesADiskImageForItsFolder() throws {
    // Another user can attach one at a folder of theirs, its files owned by anyone: only a disk
    // image this user's Mac knows as its own (not one attached as an image) is trusted.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-dmg-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    let image = box.appendingPathComponent("v.dmg").path, mount = box.appendingPathComponent("m").path
    func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    try #require(try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "V", image]) == 0)
    try fm.createDirectory(atPath: mount, withIntermediateDirectories: false)
    try #require(try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-owners", "on", "-mountpoint", mount, image]) == 0)
    defer {
        _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount])
        try? fm.removeItem(at: box)
    }
    let out = try installer("if volume_trusted '\(mount)'; then echo yes; else echo no; fi")
    #expect(out == Data("no\n".utf8), "keeps ownership, but is an image")
}

@Test func theInstallerRefusesADriveThatIgnoresOwnership() throws {
    // A real drive (not an image) set to ignore ownership: every file reports this user as owner.
    func trusted(permissions: String, bus: String) throws -> Bool {
        let out = try installer("""
            diskutil() { printf '%s' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>GlobalPermissionsEnabled</key><\(permissions)/><key>BusProtocol</key><string>\(bus)</string></dict></plist>'; }
            if volume_trusted "$TMPDIR"; then echo yes; else echo no; fi
            """)
        return out == Data("yes\n".utf8)
    }
    #expect(try trusted(permissions: "true", bus: "USB"))
    #expect(try !trusted(permissions: "false", bus: "USB"), "ignores ownership")
    #expect(try !trusted(permissions: "true", bus: "Disk Image"))
}

@Test func theInstallerIgnoresEveryWayToStopItHalfway() throws {
    // Ctrl-C, Ctrl-\, Ctrl-Z, a closed terminal, TERM, a broken pipe, and a background job writing
    // to (or reading from) the terminal: each could leave systat quit, or gone.
    let out = String(decoding: try installer("ignore_interruptions; trap"), as: UTF8.self)
    for signal in ["HUP", "INT", "QUIT", "TERM", "TSTP", "PIPE", "TTOU", "TTIN"] {
        #expect(out.contains("SIG\(signal)") || out.contains(" \(signal)\n"), "\(signal) in \(out)")
    }
}

@Test func theInstallersLockWorksWithAnOlderLockf() throws {
    // lockf's descriptor form is new in macOS 26.4: with an older one, a process of the installer's own
    // holds the lock for as long as the script runs.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-oldlockf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lock = folder.appendingPathComponent("systat-install.lock").path
    // rm stubbed: the holder's own unlink, not the script's, is what must clear its "held" file.
    let out = try installer("""
        lockf() { case $# in 3|4) case "$*" in *" 9") return 64 ;; esac ;; esac; /usr/bin/lockf "$@"; }
        rm() { :; }
        if take_install_lock '\(lock)'; then echo taken; fi
        if /usr/bin/lockf -k -s -t 0 '\(lock)' true; then echo free; else echo "held $?"; fi
        """)
    #expect(out == Data("taken\nheld 75\n".utf8))

    // Its holder ignores TERM (lockf would reset it) and isn't in the script's process group.
    let term = try installer("""
        lockf() { case $# in 3|4) case "$*" in *" 9") return 64 ;; esac ;; esac; /usr/bin/lockf "$@"; }
        take_install_lock '\(lock)' || exit 1
        kill -TERM "$holder"
        sleep 0.3
        if /usr/bin/lockf -k -s -t 0 '\(lock)' true; then echo free; else echo "held $?"; fi
        [ "$(ps -o pgid= -p "$holder" | tr -d ' ')" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] && echo "own group"
        """)
    #expect(term == Data("held 75\nown group\n".utf8))
    // And let go once the script has ended (its holder checks every half second).
    var free = false
    for _ in 0..<40 where !free {
        free = !UpdateInstaller.installerIsRunning(URL(fileURLWithPath: lock))
        if !free { Thread.sleep(forTimeInterval: 0.1) }
    }
    #expect(free)
    // Nor is its "held" file left behind, whichever way the script ended.
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".held") }
    #expect(left.isEmpty, "\(left)")
}

@Test func twoInstallsStartingTogetherWithAnOlderLockfDontBothGoAhead() throws {
    // Each perl holder says it holds the lock in a file of its own run's: one run never takes another's
    // word for its own. The winner holds it until the loser has given up (after every try).
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lock = folder.appendingPathComponent("systat-install.lock").path
    let refused = folder.appendingPathComponent("refused").path
    do {
        try? FileManager.default.removeItem(atPath: refused)
        let runs = try (0..<2).map { _ in
            let p = try installerProcess("""
                lockf() { case $# in 3|4) case "$*" in *" 9") return 64 ;; esac ;; esac; /usr/bin/lockf "$@"; }
                if take_install_lock '\(lock)'; then
                    echo taken
                    i=0
                    while [ ! -e '\(refused)' ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
                else
                    echo "refused $?"
                    : > '\(refused)'
                fi
                """)
            let out = Pipe()
            p.standardOutput = out
            return (p, out)
        }
        for (p, _) in runs { try p.run() }
        let said = runs.map { (p, out) -> String in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text
        }
        #expect(said.filter { $0 == "taken\n" }.count == 1, "\(said)")
        // The winner's holder lets go within half a second of its script's end: waited for, so it
        // isn't left running after the test.
        for _ in 0..<40 where UpdateInstaller.installerIsRunning(URL(fileURLWithPath: lock)) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

@Test func theInstallersLockFileIsMadePrivateEvenIfAnEarlierRunLeftItOpen() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-lockmode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let lock = folder.appendingPathComponent("systat-install.lock").path
    FileManager.default.createFile(atPath: lock, contents: nil, attributes: [.posixPermissions: 0o644])
    try #require(try FileManager.default.attributesOfItem(atPath: lock)[.posixPermissions] as? Int == 0o644)
    let acl = Process()
    acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
    acl.arguments = ["+a", "group:everyone allow read", lock]
    try acl.run()
    acl.waitUntilExit()
    try #require(acl_get_file(lock, ACL_TYPE_EXTENDED) != nil)

    #expect(try installer("take_install_lock '\(lock)' || echo failed").isEmpty, "taken")
    #expect(try FileManager.default.attributesOfItem(atPath: lock)[.posixPermissions] as? Int == 0o600)
    #expect(acl_get_file(lock, ACL_TYPE_EXTENDED) == nil, "no ACL left")
}

@Test func theInstallerQuitsEveryCopyAndReopensTheOneItReplacesIfAnotherWont() throws {
    // Stubs for which copies run: the one at $dest quits when asked; one elsewhere may hang.
    func run(destRuns: Bool, elsewhereHangs: Bool) throws -> (out: String, err: String, status: Int32) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let quit = folder.appendingPathComponent("quit").path
        let p = try installerProcess("""
            dest=/A/systat.app
            sleep() { :; }
            quit_systat() { : > '\(quit)'; }
            app_running() {
                case "${1:-}" in
                    "$dest") [ \(destRuns) = true ] && [ ! -e '\(quit)' ] ;;
                    *) { [ \(destRuns) = true ] && [ ! -e '\(quit)' ]; } || [ \(elsewhereHangs) = true ] ;;
                esac
            }
            running_elsewhere() { [ \(elsewhereHangs) = true ]; }
            works() { true; }
            open() { echo "opened $1"; }
            was_running=no
            elsewhere=no
            quit_and_wait "nothing was installed"
            echo "carried on: was_running=$was_running elsewhere=$elsewhere"
            """)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (o, e, p.terminationStatus)
    }

    // The copy at $dest quits; one elsewhere hangs: $dest's is opened again, and the error says so.
    let both = try run(destRuns: true, elsewhereHangs: true)
    #expect(both.status == 1)
    #expect(both.out == "opened /A/systat.app\n")
    #expect(both.err.contains("/A/systat.app was opened again"))
    #expect(both.err.contains("was also running from somewhere other than"))

    // Only the copy at $dest runs, and quits: carried on.
    let only = try run(destRuns: true, elsewhereHangs: false)
    #expect(only.status == 0)
    #expect(only.out == "carried on: was_running=yes elsewhere=no\n")

    // Only one elsewhere runs, and hangs: nothing opened, and no "also".
    let other = try run(destRuns: false, elsewhereHangs: true)
    #expect(other.status == 1)
    #expect(other.out.isEmpty)
    #expect(other.err.contains("still running and did not quit"))
    #expect(other.err.contains("was running from somewhere other than"))
}

@Test func theInstallerEjectsOnlyAnImageMountedInItsOwnFolder() throws {
    // An earlier run's image at <work>/mount is ejected; a link there to another volume ejects nothing.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-eject-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    // realpath, not resolvingSymlinksInPath: that drops /private, which the mount table keeps.
    func mounted(_ path: String) throws -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0, let real = realpath(path, nil) else { return false }
        defer { free(real) }
        return withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            == String(cString: real)
    }
    let image = box.appendingPathComponent("v.dmg").path
    try #require(try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "2m", "-fs", "APFS", "-volname", "V", image]) == 0)

    // Mounted at the work folder's own mount point: ejected, and the folder gone.
    let work = box.appendingPathComponent("work").path, mount = work + "/mount"
    try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
    try #require(try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount, image]) == 0)
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount]) }
    _ = try installer("clear_out '\(work)'")
    #expect(try !mounted(mount))
    #expect(!fm.fileExists(atPath: work))

    // Mounted elsewhere, with a link to it at the work folder's mount: left mounted.
    let other = box.appendingPathComponent("other").path
    try fm.createDirectory(atPath: other, withIntermediateDirectories: false)
    try #require(try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", other, image]) == 0)
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", other]) }
    try fm.createDirectory(atPath: work, withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: mount, withDestinationPath: other)
    _ = try installer("clear_out '\(work)'")
    #expect(try mounted(other), "a volume a link points at isn't ejected")
}

@Test func theInstallerRefusesALatestOlderThanTheSystatInPlace() throws {
    // With no version asked for: never older than a systat that verifies in place, even one whose
    // Contents was closed (opened up first, readable, nothing made runnable), and a check that fails
    // once for some passing reason gets a second try.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-downgrade-\(UUID().uuidString)")
    let contents = box.appendingPathComponent("fake/Contents")
    try fm.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { _ = try? installer("chmod -R u+rwx '\(box.path)'"); try? fm.removeItem(at: box) }
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.1.1"], format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let tries = box.appendingPathComponent("tries").path
    func refused(latest: String, verifies: String, closed: Bool = false) throws -> Bool {
        try? fm.removeItem(atPath: tries)
        if closed { try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: contents.path) }
        let out = try installerProcess("""
            dest='\(box.path)/fake'
            sleep() { :; }
            codesign() { echo x >> '\(tries)'; case '\(verifies)' in always) return 0 ;; second) [ "$(wc -l < '\(tries)')" -ge 2 ] ;; *) return 1 ;; esac; }
            mdfind() { :; }
            refuse_downgrade '\(latest)'
            echo carried on
            """)
        let pipe = Pipe()
        out.standardOutput = pipe
        out.standardError = FileHandle.nullDevice
        try out.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        out.waitUntilExit()
        return out.terminationStatus != 0 && !text.contains("carried on")
    }
    #expect(try refused(latest: "0.1.0", verifies: "always"))
    #expect(try !refused(latest: "0.1.1", verifies: "always"), "the same version reinstalls")
    #expect(try !refused(latest: "0.1.2", verifies: "always"))
    #expect(try !refused(latest: "0.1.0", verifies: "never"), "not a systat that verifies")
    #expect(try refused(latest: "0.1.0", verifies: "second"), "a second try")
    #expect(try refused(latest: "0.1.0", verifies: "always", closed: true), "Contents closed")
}

@Test func theInstallerRefusesALatestOlderThanASystatElsewhereInTheHomeFolder() throws {
    // ~/Applications/systat.app 0.1.5, not running, nothing in /Applications: found by Spotlight, and
    // only a copy that verifies counts.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-home-copy-\(UUID().uuidString)")
    // Opened up first: a folder this test closes would otherwise stay behind if it stops early.
    defer { _ = try? installer("chmod -R u+rwx '\(box.path)'"); try? fm.removeItem(at: box) }
    let copy = box.appendingPathComponent("home copy/systat.app")
    try fm.createDirectory(at: copy.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.1.5"], format: .xml, options: 0)
        .write(to: copy.appendingPathComponent("Contents/Info.plist"))
    func run(latest: String, verifies: Bool, found given: [String]) throws -> (err: String, status: Int32) {
        // As Spotlight names them: real paths (/private/var/…), while HOME goes through /var.
        let realBox = try #require(realpath(box.path, nil).map { s in defer { free(s) }; return String(cString: s) })
        let found = given.map { $0.hasPrefix(box.path + "/") ? realBox + $0.dropFirst(box.path.count) : $0 }
        let p = try installerProcess("""
            HOME='\(box.path)'
            dest='\(box.path)/none/systat.app'
            me=$(id -u)
            sleep() { :; }
            codesign() { \(verifies); }
            # The volume is theInstallersFolderCheckLooksAtTheVolume's (diskutil is slow, folder by folder).
            volume_trusted() { true; }
            # As mdfind -0 gives them: each path ended by a NUL, as a path may hold a line break.
            mdfind() { [ "$1" = -0 ] && [ "$2" = -onlyin ] && [ "$3" = "$HOME" ] || return 1; \(found.map { "printf '%s\\0' '\($0)'" }.joined(separator: "; ")) \(found.isEmpty ? ":" : ""); }
            refuse_downgrade '\(latest)'
            echo carried on
            """)
        let err = Pipe()
        // Run from the home folder, where a relative path would find the copy.
        p.currentDirectoryURL = box
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (e, p.terminationStatus)
    }
    let refused = try run(latest: "0.1.1", verifies: true, found: [copy.path])
    #expect(refused.status == 1)
    #expect(refused.err.contains("systat 0.1.5 is at "))
    #expect(refused.err.contains("/home copy/systat.app, newer than the latest release (0.1.1)"))
    #expect(try run(latest: "0.1.5", verifies: true, found: [copy.path]).status == 0, "the same version")
    #expect(try run(latest: "0.1.1", verifies: false, found: [copy.path]).status == 0, "not a systat that verifies")
    #expect(try run(latest: "0.1.1", verifies: true, found: []).status == 0)
    #expect(try run(latest: "0.1.1", verifies: true, found: [box.path + "/gone/systat.app"]).status == 0, "nothing there")
    // A name another user chose, with a line break in it, can't slip a second path in: the copy after
    // the break would refuse the install, if it were read on its own.
    #expect(try run(latest: "0.1.1", verifies: true, found: [box.path + "/drop/x\n" + copy.path]).status == 0, "a line break")
    // Nor a path through a link (one another user can swap between the checks and the reading):
    // Spotlight names real paths, so only one that is its own real path counts.
    try fm.createSymbolicLink(atPath: box.appendingPathComponent("link").path, withDestinationPath: box.appendingPathComponent("home copy").path)
    #expect(try run(latest: "0.1.1", verifies: true, found: [box.path + "/link/systat.app"]).status == 0, "through a link")
    // Nor a relative path (there from the folder it runs in), or one outside the home folder.
    #expect(try run(latest: "0.1.1", verifies: true, found: ["home copy/systat.app"]).status == 0, "relative")
    let outside = fm.temporaryDirectory.appendingPathComponent("systat-outside-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: outside) }
    try fm.createDirectory(at: outside, withIntermediateDirectories: false)
    try fm.copyItem(at: copy, to: outside.appendingPathComponent("systat.app"))
    #expect(try run(latest: "0.1.1", verifies: true, found: [outside.appendingPathComponent("systat.app").path]).status == 0, "outside")
    // One an update disabled, its Contents closed: opened up first, as the copy in place is.
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: copy.appendingPathComponent("Contents").path)
    #expect(try run(latest: "0.1.1", verifies: true, found: [copy.path]).status == 1, "Contents closed")
    // One in the Trash would never be opened: not counted.
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.appendingPathComponent("Contents").path)
    let trashed = box.appendingPathComponent(".Trash/systat.app")
    try fm.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: copy, to: trashed)
    // (By its real path, as Spotlight names it, while HOME goes through a link: /var/….)
    #expect(try run(latest: "0.1.1", verifies: true, found: [trashed.path]).status == 0, "in the Trash")
    // The updater's and the installer's own work copies (a run left by a crash, say) aren't copies of
    // the user's: never opened, and named nowhere the user would look.
    for work in ["Library/Application Support/systat-update/run-1", "Library/Caches/systat-update/run-1",
                 "Applications/.systat-update/run-1", "Library/Application Support/systat-install"] {
        let staged = box.appendingPathComponent(work + "/systat.app")
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: copy, to: staged)
        #expect(try run(latest: "0.1.1", verifies: true, found: [staged.path]).status == 0, "\(work)")
    }

    // One another user could have put there (~/Public/Drop Box lets anyone add a folder): not
    // looked at, as it could be anything, a FIFO that would hang codesign included.
    let drop = box.appendingPathComponent("drop")
    let planted = drop.appendingPathComponent("x/systat.app")
    try fm.createDirectory(at: planted.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try fm.copyItem(at: copy.appendingPathComponent("Contents/Info.plist"), to: planted.appendingPathComponent("Contents/Info.plist"))
    try fm.setAttributes([.posixPermissions: 0o733], ofItemAtPath: drop.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drop.path) }
    #expect(try run(latest: "0.1.1", verifies: true, found: [planted.path]).status == 0, "in a folder others can add to")
}

@Test func theInstallerWontQuitANewerSystatRunningElsewhereForAnOlderLatest() throws {
    // systat 0.1.5 runs from ~/Applications, nothing in /Applications: a latest set back to 0.1.1 must
    // not quit it and open 0.1.1 in its place. Only copies that verify count, the one at $dest is
    // refuse_downgrade's, and a check that fails once gets a second try.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-newer-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: box) }
    for (name, version) in [("home", "0.1.5"), ("dest", "0.1.9"), ("old", "0.1.0")] {
        let contents = box.appendingPathComponent("\(name)/systat.app/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
    let tries = box.appendingPathComponent("tries").path
    func newer(latest: String, running: [String], verifies: String = "always") throws -> String {
        try? fm.removeItem(atPath: tries)
        let listing = running.map { "\(box.path)/\($0)/systat.app/Contents/MacOS/systat" }
        let out = try installer("""
            dest='\(box.path)/dest/systat.app'
            me=$(id -u)
            sleep() { :; }
            # The volume is theInstallersFolderCheckLooksAtTheVolume's (diskutil is slow, folder by folder).
            volume_trusted() { true; }
            app_pids() { \(listing.indices.map { "echo \($0 + 1)" }.joined(separator: "; ")) \(listing.isEmpty ? ":" : ""); }
            ps() { case "$4" in \(listing.enumerated().map { "\($0.offset + 1)) echo '\($0.element)' ;;" }.joined(separator: " ")) *) return 1 ;; esac; }
            codesign() { echo x >> '\(tries)'; case '\(verifies)' in always) return 0 ;; second) [ "$(wc -l < '\(tries)')" -ge 2 ] ;; *) return 1 ;; esac; }
            newer_running '\(latest)' || echo none
            """)
        return String(decoding: out, as: UTF8.self)
    }
    #expect(try newer(latest: "0.1.1", running: ["home"]) == "0.1.5\n")
    // Running from a folder another user can change: its version could be anything (and its
    // executable swapped for one that hangs codesign), so it doesn't count.
    let shared = box.appendingPathComponent("shared")
    try fm.createDirectory(at: shared, withIntermediateDirectories: false)
    try fm.copyItem(at: box.appendingPathComponent("home/systat.app"), to: shared.appendingPathComponent("systat.app"))
    try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path) }
    #expect(try newer(latest: "0.1.1", running: ["shared"]) == "none\n", "in a folder others can change")
    #expect(try newer(latest: "0.1.1", running: ["old", "home"]) == "0.1.5\n")
    #expect(try newer(latest: "0.1.5", running: ["home"]) == "none\n", "the same version")
    #expect(try newer(latest: "0.1.6", running: ["home"]) == "none\n")
    #expect(try newer(latest: "0.1.1", running: ["dest"]) == "none\n", "the copy at $dest is refuse_downgrade's")
    #expect(try newer(latest: "0.1.1", running: ["home"], verifies: "never") == "none\n", "not a systat that verifies")
    #expect(try newer(latest: "0.1.1", running: ["home"], verifies: "second") == "0.1.5\n", "a second try")
    #expect(try newer(latest: "0.1.1", running: []) == "none\n")
}

@Test func theInstallerRefusesBeforeQuittingANewerSystatRunningElsewhere() throws {
    func run(wasRunning: Bool, destRuns: Bool) throws -> (out: String, err: String, status: Int32) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-newer-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let quit = folder.appendingPathComponent("quit").path
        let p = try installerProcess("""
            dest=/A/systat.app
            latest=0.1.1
            sleep() { :; }
            newer_running() { echo 0.1.5; }
            quit_systat() { : > '\(quit)'; }
            app_running() { case "${1:-}" in "$dest") [ \(destRuns) = true ] ;; *) true ;; esac; }
            running_elsewhere() { true; }
            works() { true; }
            open() { echo "opened $1"; }
            was_running=\(wasRunning ? "yes" : "no")
            elsewhere=no
            quit_and_wait "nothing was installed"
            echo carried on
            """)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(!FileManager.default.fileExists(atPath: quit), "nothing quit")
        return (o, e, p.terminationStatus)
    }
    // The first look, before anything is quit: it stops, naming both versions and how to go ahead.
    let first = try run(wasRunning: false, destRuns: false)
    #expect(first.status == 1)
    #expect(first.out.isEmpty)
    #expect(first.err.contains("systat 0.1.5 is running from somewhere other than /A/systat.app, newer than the latest release (0.1.1); nothing was installed"))
    #expect(first.err.contains("sh -s -- 0.1.1"))
    // A second look, after the copy at $dest was quit (a newer one opened meanwhile): $dest's is reopened.
    let second = try run(wasRunning: true, destRuns: false)
    #expect(second.status == 1)
    #expect(second.out == "opened /A/systat.app\n")
    #expect(second.err.contains("/A/systat.app was opened again"))
    // A newer copy opened while it waits for the first to quit: looked at again before each quit.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-newer-loop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let quits = folder.appendingPathComponent("quits").path
    let loop = try installerProcess("""
        dest=/A/systat.app
        latest=0.1.1
        sleep() { :; }
        newer_running() { [ "$(cat '\(quits)' 2>/dev/null | wc -l)" -ge 1 ] && echo 0.1.5; }
        quit_systat() { echo x >> '\(quits)'; }
        app_running() { case "${1:-}" in "$dest") false ;; *) true ;; esac; }
        running_elsewhere() { true; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo carried on
        """)
    let loopErr = Pipe()
    loop.standardOutput = FileHandle.nullDevice
    loop.standardError = loopErr
    try loop.run()
    let loopText = String(decoding: loopErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    loop.waitUntilExit()
    #expect(loop.terminationStatus == 1)
    #expect(loopText.contains("systat 0.1.5 is running from somewhere other than"))
    // The copy quit by the first try isn't reopened, and the error says so.
    #expect(loopText.contains("and that copy, if it quit, wasn't reopened"))
    #expect((try? String(contentsOfFile: quits, encoding: .utf8)) == "x\n", "not quit again once a newer one runs")

    // The copy at $dest was asked to quit but takes a while, and a newer one opens meanwhile: it is
    // given a moment to go, then opened again, rather than left closed with nothing said.
    let slow = try installerProcess("""
        dest=/A/systat.app
        latest=0.1.1
        sleep() { :; }
        checks='\(folder.path)/dest-checks'
        newer_running() { [ -e '\(folder.path)/slow-quit' ] && echo 0.1.5; }
        quit_systat() { : > '\(folder.path)/slow-quit'; }
        # Still running for the first few looks after the quit, then gone; something else runs on.
        app_running() {
            case "${1:-}" in
                "$dest") [ ! -e '\(folder.path)/slow-quit' ] && return 0
                         echo x >> "$checks"; [ "$(wc -l < "$checks")" -lt 8 ] ;;
                *) true ;;
            esac
        }
        running_elsewhere() { true; }
        works() { true; }
        open() { echo "opened $1"; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo carried on
        """)
    let slowOut = Pipe(), slowErr = Pipe()
    slow.standardOutput = slowOut
    slow.standardError = slowErr
    try slow.run()
    let slowText = String(decoding: slowOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let slowMessage = String(decoding: slowErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    slow.waitUntilExit()
    #expect(slow.terminationStatus == 1)
    #expect(slowText == "opened /A/systat.app\n")
    #expect(slowMessage.contains("/A/systat.app was opened again"))

    // Still quitting after the moment it is given: the refusal says so, as it may close yet.
    let stuck = try installerProcess("""
        dest=/A/systat.app
        latest=0.1.1
        sleep() { :; }
        newer_running() { [ -e '\(folder.path)/stuck-quit' ] && echo 0.1.5; }
        quit_systat() { : > '\(folder.path)/stuck-quit'; }
        app_running() { true; }
        running_elsewhere() { true; }
        works() { true; }
        open() { echo "opened $1"; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        """)
    let stuckErr = Pipe()
    stuck.standardOutput = FileHandle.nullDevice
    stuck.standardError = stuckErr
    try stuck.run()
    let stuckMessage = String(decoding: stuckErr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    stuck.waitUntilExit()
    #expect(stuck.terminationStatus == 1)
    #expect(stuckMessage.contains("/A/systat.app was asked to quit and hasn't yet; if it closes, open it again"))

    // A second call (systat reopened meanwhile) that refuses at once: no wait for a quit this call
    // never sent.
    let sleeps = folder.appendingPathComponent("sleeps").path
    let again = try installerProcess("""
        dest=/A/systat.app
        latest=0.1.1
        sleep() { echo x >> '\(sleeps)'; }
        newer_running() { echo 0.1.5; }
        quit_systat() { :; }
        app_running() { true; }
        running_elsewhere() { true; }
        works() { true; }
        open() { :; }
        was_running=yes
        elsewhere=no
        quit_sent=yes
        quit_and_wait "nothing was installed"
        """)
    again.standardOutput = FileHandle.nullDevice
    again.standardError = FileHandle.nullDevice
    try again.run()
    again.waitUntilExit()
    #expect(again.terminationStatus == 1)
    #expect(!FileManager.default.fileExists(atPath: sleeps), "no wait")

    // A latest to compare, and no newer copy running: it quits and carries on.
    let none = try installer("""
        dest=/A/systat.app
        latest=0.1.1
        sleep() { :; }
        newer_running() { return 1; }
        quit_systat() { : > '\(folder.path)/quit-none'; }
        app_running() { [ ! -e '\(folder.path)/quit-none' ]; }
        running_elsewhere() { true; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo carried on
        """)
    #expect(String(decoding: none, as: UTF8.self) == "carried on\n")

    // With no version left to compare (one was asked for): not checked, and the copy is quit.
    let asked = try installer("""
        dest=/A/systat.app
        sleep() { :; }
        newer_running() { echo 0.1.5; }
        quit_systat() { : > '\(folder.path)/quit-asked'; }
        app_running() { [ ! -e '\(folder.path)/quit-asked' ]; }
        running_elsewhere() { true; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo carried on
        """)
    #expect(String(decoding: asked, as: UTF8.self) == "carried on\n")
    #expect(FileManager.default.fileExists(atPath: folder.path + "/quit-asked"))
}

@Test func theInstallerRefusesANewerSystatRunningElsewhereBeforeDownloading() throws {
    // Found out before the download, not after it: the release is never fetched.
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("systat-newer-main-\(UUID().uuidString)")
    try fm.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let p = try installerProcess("""
        HOME='\(home.path)'
        dest='\(home.path)/Applications/systat.app'
        volume_trusted() { true; }
        only_trusted_can_change() { true; }
        updater_busy() { return 1; }
        fetch() { printf '{"tag_name":"v0.1.1"}' > "$2"; }
        mdfind() { :; }
        curl() { echo "downloaded $*"; }
        newer_running() { [ "$1" = 0.1.1 ] && echo 0.1.5; }
        # This test's home folder, not the account's (which main takes, as the app does).
        account_home() { echo "$HOME"; }
        main
        """)
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    #expect(p.terminationStatus == 1)
    #expect(!o.contains("Downloading") && !o.contains("downloaded"))
    #expect(e.contains("systat 0.1.5 is running from somewhere other than"))
    #expect(e.contains("nothing was installed"))
}

@Test func theInstallerNotesACopyThatOpensElsewhereWhileItWaits() throws {
    // A copy opened elsewhere during the wait is quit with the rest: noted as one, so the last message
    // (or an error) says it wasn't reopened.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-opened-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let out = try installer("""
        dest=/A/systat.app
        sleep() { :; }
        quits='\(folder.path)/quits'
        quit_systat() { echo x >> "$quits"; [ "$(wc -l < "$quits")" -ne 1 ] || : > '\(folder.path)/opened'; }
        app_running() { [ ! -e "$quits" ] || [ "$(wc -l < "$quits")" -lt 2 ]; }
        running_elsewhere() { [ -e '\(folder.path)/opened' ]; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo "elsewhere=$elsewhere"
        """)
    #expect(String(decoding: out, as: UTF8.self) == "elsewhere=yes\n")
}

@Test func theInstallersLastMessageNeedsNoQuitToHaveRun() throws {
    // A copy elsewhere that quits by itself before the wait: elsewhere is noted, and the last message
    // (which reads also) mustn't fail under set -u after a good install.
    let out = try installer("""
        dest=/A/systat.app
        sleep() { :; }
        quit_systat() { :; }
        app_running() { false; }
        running_elsewhere() { true; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo "systat was$also running"
        """)
    #expect(String(decoding: out, as: UTF8.self) == "systat was running\n")
    // The copy at $dest ran too, and both quit by themselves: "also", as when they were quit.
    let both = try installer("""
        dest=/A/systat.app
        sleep() { :; }
        quit_systat() { :; }
        app_running() { false; }
        running_elsewhere() { true; }
        was_running=yes
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo "systat was$also running"
        """)
    #expect(String(decoding: both, as: UTF8.self) == "systat was also running\n")
}

@Test(.enabled(if: isUniversal("/bin/echo"), "needs a universal /bin/echo"))
func theInstallerPinsEveryArchitectureOfTheVeryBuild() throws {
    // Real signed code, universal (arm64e and x86_64): copies of two system tools, signed ad hoc (never
    // run, and not app bundles). The pin admits that build alone, by each architecture's hash.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-pin-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    let built = box.appendingPathComponent("built").path, other = box.appendingPathComponent("other").path
    try fm.copyItem(atPath: "/bin/echo", toPath: built)
    try fm.copyItem(atPath: "/bin/cat", toPath: other)
    try fm.createFile(atPath: box.appendingPathComponent("unsigned").path, contents: Data("not code\n".utf8))
    let out = String(decoding: try installer("""
        codesign -f -s - '\(built)' '\(other)' 2>/dev/null
        pin=$(pin_build '\(built)' always)
        printf '%s\\n' "$pin" | grep -o 'cdhash H"[0-9a-f]*"' | wc -l | tr -d ' '
        codesign --verify -R="$pin" '\(built)' 2>/dev/null && echo built-passes
        codesign --verify -R="$pin" '\(other)' 2>/dev/null || echo other-refused
        pin_build '\(box.path)/unsigned' always || echo unsigned-unpinned
        """), as: UTF8.self)
    #expect(out == "2\nbuilt-passes\nother-refused\nunsigned-unpinned\n")
}

@Test func theInstallerJudgesASystatStartedByARelativePathFromItsOwnFolder() throws {
    // Started from a terminal as fake/Contents/MacOS/systat: its bundle is read where it runs, not
    // where the installer runs, which may hold another bundle at that path (put there by anyone).
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-relative-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: box) }
    func bundle(_ folder: String, id: String) throws {
        let contents = box.appendingPathComponent("\(folder)/fake/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
    try bundle("app", id: "dev.inggo.systat")
    try bundle("installer", id: "com.example.other")
    // A real bundle's executable folder, there as in any copy that runs.
    try fm.createDirectory(at: box.appendingPathComponent("app/fake/Contents/MacOS"), withIntermediateDirectories: true)
    // An exported CDPATH (cd then looks a relative folder up through it, and prints where it went)
    // mustn't change where a copy is placed.
    var environment = ProcessInfo.processInfo.environment
    environment["CDPATH"] = ".:/tmp"
    let p = Process(), feed = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", #"exec -a "$0" /bin/cat"#, "fake/Contents/MacOS/systat"]
    p.currentDirectoryURL = box.appendingPathComponent("app")
    p.standardInput = feed
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    defer { try? feed.fileHandleForWriting.close(); p.waitUntilExit() }
    var seen = false
    for _ in 0..<1000 where !seen {
        let ps = Process(), out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(p.processIdentifier)]
        ps.standardOutput = out
        try ps.run()
        seen = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "fake/Contents/MacOS/systat"
        ps.waitUntilExit()
        if !seen { usleep(10_000) }
    }
    try #require(seen)
    let installer = try installerProcess("""
        me=$(id -u)
        app_pids
        echo ---
        app_command \(p.processIdentifier)
        """)
    installer.currentDirectoryURL = box.appendingPathComponent("installer")
    installer.environment = environment
    let out = Pipe()
    installer.standardOutput = out
    try installer.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    installer.waitUntilExit()
    let real = try #require(realpath(box.appendingPathComponent("app").path, nil).map { s in defer { free(s) }; return String(cString: s) })
    let (listed, command) = (text.components(separatedBy: "---\n")[0], text.components(separatedBy: "---\n").last ?? "")
    #expect(listed.split(separator: "\n").map(String.init).contains(String(p.processIdentifier)))
    #expect(command == real + "/fake/Contents/MacOS/systat\n")

    // Started as ../fake/… from a folder beside it, or as ./systat from inside the bundle: the same
    // copy, its path written plainly, and counted.
    try fm.createDirectory(at: box.appendingPathComponent("app/side"), withIntermediateDirectories: true)
    for (folder, argv0) in [("app/side", "../fake/Contents/MacOS/systat"), ("app/fake/Contents/MacOS", "./systat")] {
        try fm.createDirectory(at: box.appendingPathComponent(folder), withIntermediateDirectories: true)
        let q = Process(), qFeed = Pipe()
        q.executableURL = URL(fileURLWithPath: "/bin/bash")
        q.arguments = ["-c", #"exec -a "$0" /bin/cat"#, argv0]
        q.currentDirectoryURL = box.appendingPathComponent(folder)
        q.standardInput = qFeed
        q.standardOutput = FileHandle.nullDevice
        try q.run()
        defer { try? qFeed.fileHandleForWriting.close(); q.waitUntilExit() }
        var started = false
        for _ in 0..<1000 where !started {
            let ps = Process(), psOut = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "command=", "-p", String(q.processIdentifier)]
            ps.standardOutput = psOut
            try ps.run()
            started = String(decoding: psOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == argv0
            ps.waitUntilExit()
            if !started { usleep(10_000) }
        }
        try #require(started)
        let check = try installerProcess("""
            me=$(id -u)
            app_pids
            echo ---
            app_command \(q.processIdentifier)
            """)
        check.currentDirectoryURL = box.appendingPathComponent("installer")
        check.environment = environment
        let checkOut = Pipe()
        check.standardOutput = checkOut
        try check.run()
        let found = String(decoding: checkOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check.waitUntilExit()
        let parts = found.components(separatedBy: "---\n")
        #expect(parts[0].split(separator: "\n").map(String.init).contains(String(q.processIdentifier)), "\(argv0)")
        #expect(parts.last == real + "/fake/Contents/MacOS/systat\n", "\(argv0)")
    }
}

@Test func aScriptCutShortRunsNothingWhereverItIsCut() throws {
    // curl | sh runs what arrived: wherever the last line is cut, main never runs (not even with
    // the version asked for dropped), and the whole line runs it with its arguments.
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../install.sh").standardizedFileURL
    var lines = try String(contentsOf: script, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    while lines.last?.isEmpty == true { lines.removeLast() }
    let last = String(try #require(lines.last))
    func run(_ tail: String) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "main() { echo \"ran $#\"; }\n" + tail, "sh", "0.1.0"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text
    }
    for cut in 1..<last.count {
        #expect(try run(String(last.prefix(cut))).isEmpty, "cut to \(last.prefix(cut))")
    }
    #expect(try run(last) == "ran 1\n")
}

@Test func theInstallerTellsTheAppFromSystatsCommandLineModesAsTheAppDoes() throws {
    // main.swift starts a command-line mode for these arguments, and the app for any others (macOS's
    // own, such as -AppleLanguages): the installer reads them the same way, from the same list.
    let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/systat/main.swift").standardizedFileURL
    let source = try String(contentsOf: main, encoding: .utf8)
    var flags = Set<String>()
    for line in source.split(separator: "\n") where line.contains("arguments") {
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "\"") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "\"") else { break }
            let literal = String(after[..<close])
            if literal.hasPrefix("-") || literal == "version" { flags.insert(literal) }
            rest = after[after.index(after: close)...]
        }
    }
    try #require(flags.isSuperset(of: ["--version", "--help", "--update", "--bench", "--snapshot"]), "\(flags)")
    let first: Set = ["--version", "-v", "version"]
    var commands = ""
    for flag in flags.sorted() {
        commands += "is_cli_mode ' \(flag)' && echo 'yes \(flag)' || echo 'no \(flag)'\n"
        if !first.contains(flag) {
            commands += "is_cli_mode ' -AppleLanguages (de) \(flag) 5' && echo 'yes later \(flag)' || echo 'no later \(flag)'\n"
        }
    }
    commands += "is_cli_mode '' && echo 'yes none' || echo 'no none'\n"
    commands += "is_cli_mode ' -AppleLanguages (de)' && echo 'yes macos' || echo 'no macos'\n"
    commands += "is_cli_mode ' x --version' && echo 'yes version-later' || echo 'no version-later'\n"
    commands += "is_cli_mode ' *' && echo 'yes glob' || echo 'no glob'\n"
    let out = String(decoding: try installer(commands), as: UTF8.self).split(separator: "\n").map(String.init)
    for flag in flags {
        #expect(out.contains("yes \(flag)"), "\(flag)")
        if !first.contains(flag) { #expect(out.contains("yes later \(flag)"), "\(flag) after others") }
    }
    // And the other way: every word the installer takes for a mode is one main.swift knows.
    let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../install.sh").standardizedFileURL, encoding: .utf8)
    let body = try #require(script.components(separatedBy: "is_cli_mode() {").last?.components(separatedBy: "\n}\n").first)
    // The words of its case patterns that answer "a mode" (return 0).
    let patterns = body.split(separator: "\n").filter { $0.contains(" in ") && $0.contains("return 0") }
        .map { $0.components(separatedBy: " in ").last!.components(separatedBy: ")").first! }
    let words = Set(patterns.flatMap { $0.split(whereSeparator: { " |".contains($0) }).map(String.init) })
    try #require(!words.isEmpty)
    #expect(words.isSubset(of: flags), "\(words.subtracting(flags))")
    #expect(out.contains("no none"))
    #expect(out.contains("no macos"))
    #expect(out.contains("no version-later"), "version counts only first, as main.swift reads it")
    #expect(out.contains("no glob"))
}

@Test func theInstallerCountsTheAppStartedWithArgumentsOrByName() throws {
    // The app started with macOS's own arguments (open --args), or by its bare name through a link on
    // PATH: still the app, found by its real executable. A command-line mode isn't.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-named-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: box) }
    // A real executable in a bundle folder (not a .app): a copy of a system tool won't run.
    let macOS = box.appendingPathComponent("app/fake/Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.inggo.systat"], format: .xml, options: 0)
        .write(to: box.appendingPathComponent("app/fake/Contents/Info.plist"))
    let exe = macOS.appendingPathComponent("systat").path
    let clang = Process(), source = Pipe()
    clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    clang.arguments = ["-x", "c", "-", "-o", exe]
    clang.standardInput = source
    clang.standardError = FileHandle.nullDevice
    try clang.run()
    try source.fileHandleForWriting.write(contentsOf: Data("#include <unistd.h>\nint main(void){pause();return 0;}\n".utf8))
    try source.fileHandleForWriting.close()
    clang.waitUntilExit()
    try #require(clang.terminationStatus == 0)
    let real = try #require(realpath(exe, nil).map { s in defer { free(s) }; return String(cString: s) })
    var started: [Process] = []
    defer { for p in started { p.terminate(); p.waitUntilExit() } }
    func start(_ argv0: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", #"exec -a "$0" "$@""#, argv0, exe] + args
        p.currentDirectoryURL = box
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        started.append(p)
        let want = ([argv0] + args).joined(separator: " ")
        var seen = false
        for _ in 0..<1000 where !seen {
            let ps = Process(), out = Pipe()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "command=", "-p", String(p.processIdentifier)]
            ps.standardOutput = out
            try ps.run()
            seen = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == want
            ps.waitUntilExit()
            if !seen { usleep(10_000) }
        }
        try #require(seen, "\(want)")
        return p
    }
    let withArgs = try start(real, ["-AppleLanguages", "(de)"])
    let byName = try start("systat", [])
    // Through a link of the user's (~/bin/systat), by its absolute or relative path.
    try fm.createDirectory(at: box.appendingPathComponent("bin"), withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: box.appendingPathComponent("bin/systat").path, withDestinationPath: exe)
    let linkPath = try #require(realpath(box.appendingPathComponent("bin").path, nil).map { s in defer { free(s) }; return String(cString: s) }) + "/systat"
    let byLink = try start(linkPath, [])
    let byRelativeLink = try start("bin/systat", [])
    // Through a link with another name (~/bin/sysmon): found by the executable it runs.
    try fm.createSymbolicLink(atPath: box.appendingPathComponent("bin/sysmon").path, withDestinationPath: exe)
    let byOtherName = try start(box.appendingPathComponent("bin").path + "/sysmon", [])
    let bench = try start(real, ["--bench", "5"])
    let version = try start(real, ["version"])
    let out = String(decoding: try installer("""
        me=$(id -u)
        app_pids
        echo ---
        app_command \(byName.processIdentifier)
        """), as: UTF8.self)
    let parts = out.components(separatedBy: "---\n")
    let listed = parts[0].split(separator: "\n").map(String.init)
    #expect(listed.contains(String(withArgs.processIdentifier)), "macOS's own arguments")
    #expect(listed.contains(String(byName.processIdentifier)), "by its bare name")
    #expect(listed.contains(String(byLink.processIdentifier)), "through a link, by its path")
    #expect(listed.contains(String(byRelativeLink.processIdentifier)), "through a link, by a relative path")
    #expect(listed.contains(String(byOtherName.processIdentifier)), "through a link with another name")
    #expect(!listed.contains(String(bench.processIdentifier)), "a command-line mode")
    #expect(!listed.contains(String(version.processIdentifier)), "a command-line mode")
    #expect(parts.last == real + "\n")
}

@Test func theInstallerNotesTheCopyInPlaceOpenedWhileItWaits() throws {
    // The copy at $dest opened during the wait is quit with the rest: noted as running, so a failure
    // after reopens it.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("systat-dest-opened-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let out = try installer("""
        dest=/A/systat.app
        sleep() { :; }
        quits='\(folder.path)/quits'
        quit_systat() { echo x >> "$quits"; }
        # Something elsewhere runs from the start; the copy at $dest opens after the first quit, and
        # everything is gone after the second.
        app_running() {
            n=$(cat "$quits" 2>/dev/null | wc -l)
            case "${1:-}" in "$dest") [ "$n" -eq 1 ] ;; *) [ "$n" -lt 2 ] ;; esac
        }
        running_elsewhere() { true; }
        was_running=no
        elsewhere=no
        quit_and_wait "nothing was installed"
        echo "was_running=$was_running"
        """)
    #expect(String(decoding: out, as: UTF8.self) == "was_running=yes\n")
}

@Test func theInstallersFolderCheckIgnoresGrepOptionsFromTheEnvironment() throws {
    // A GREP_OPTIONS of -q or -o (grep still honours it) would pass a folder a group can add to.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-grepopts-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    let acl = Process()
    acl.executableURL = URL(fileURLWithPath: "/bin/chmod")
    acl.arguments = ["+a", "group:staff allow add_file", box.path]
    try acl.run()
    acl.waitUntilExit()
    try #require(acl.terminationStatus == 0)
    // Nor an exported function standing in for grep (bash, as /bin/sh, imports them).
    let hijacked = try installerProcess("""
        volume_trusted() { true; }
        only_trusted_can_change '\(box.path)' && echo trusted || echo refused
        """)
    var hijackedEnvironment = ProcessInfo.processInfo.environment
    hijackedEnvironment["BASH_FUNC_grep%%"] = "() { cat > /dev/null; }"
    hijacked.environment = hijackedEnvironment
    let hijackedOut = Pipe()
    hijacked.standardOutput = hijackedOut
    hijacked.standardError = FileHandle.nullDevice
    try hijacked.run()
    let hijackedText = String(decoding: hijackedOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    hijacked.waitUntilExit()
    #expect(hijackedText == "refused\n", "an exported grep function")
    for options in ["-q", "-o", "--color=always"] {
        let p = try installerProcess("""
            volume_trusted() { true; }
            only_trusted_can_change '\(box.path)' && echo trusted || echo refused
            """)
        var environment = ProcessInfo.processInfo.environment
        environment["GREP_OPTIONS"] = options
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(text == "refused\n", "GREP_OPTIONS=\(options)")
    }
}

@Test func theInstallerTakesTheHomeFolderFromTheAccountAsTheAppDoes() throws {
    // HOME pointing elsewhere: the installer still takes the account's home folder, as Foundation's
    // homeDirectoryForCurrentUser does in this test process (which kept the real HOME), so the app
    // and the installer look for each other's locks in the same place.
    let p = try installerProcess("account_home")
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = FileManager.default.temporaryDirectory.path
    p.environment = environment
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    #expect(text == FileManager.default.homeDirectoryForCurrentUser.path + "\n")

    // Nor CFFIXED_USER_HOME: systat started from the Dock or at login never has it, so following one
    // a shell exports would split them again.
    let fixed = try installerProcess("account_home")
    environment["CFFIXED_USER_HOME"] = "/private/tmp/fixed-home"
    fixed.environment = environment
    let fixedOut = Pipe()
    fixed.standardOutput = fixedOut
    try fixed.run()
    let fixedText = String(decoding: fixedOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    fixed.waitUntilExit()
    #expect(fixedText == FileManager.default.homeDirectoryForCurrentUser.path + "\n")

    // Nor a Perl module the environment slips in (PERL5OPT, PERL5LIB), which could print any folder.
    let lib = FileManager.default.temporaryDirectory.appendingPathComponent("systat-perl5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: lib) }
    try Data("package Evil; BEGIN { print \"/evil\"; exit 0 } 1;\n".utf8).write(to: lib.appendingPathComponent("Evil.pm"))
    let perl = try installerProcess("account_home")
    var perlEnvironment = ProcessInfo.processInfo.environment
    perlEnvironment["PERL5OPT"] = "-MEvil"
    perlEnvironment["PERL5LIB"] = lib.path
    perl.environment = perlEnvironment
    let perlOut = Pipe()
    perl.standardOutput = perlOut
    try perl.run()
    let perlText = String(decoding: perlOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    perl.waitUntilExit()
    #expect(perlText == FileManager.default.homeDirectoryForCurrentUser.path + "\n")
}

@Test func theInstallersFolderCheckRejectsByModeBeforeAskingAboutTheVolume() throws {
    // Thousands of bundles another user can plant (in ~/Public/Drop Box) each cost the check only
    // their owner and mode, not a diskutil call (a fifth of a second each), before being refused.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-modefirst-\(UUID().uuidString)")
    try fm.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: box) }
    try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: box.path)
    let calls = box.appendingPathComponent("volume-calls").path
    let out = String(decoding: try installer("""
        volume_trusted() { echo x >> '\(calls)'; true; }
        only_trusted_can_change '\(box.path)' && echo trusted || echo refused
        """), as: UTF8.self)
    #expect(out == "refused\n")
    #expect(!fm.fileExists(atPath: calls), "the volume wasn't asked about")
}

@Test func theInstallerSkipsCopiesInTheDropBoxByName() throws {
    // ~/Public/Drop Box takes anyone's files: a copy there is never one of the user's, and is passed
    // over by its name alone, before anything about it is looked up.
    let fm = FileManager.default
    let box = fm.temporaryDirectory.appendingPathComponent("systat-dropbox-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: box) }
    let planted = box.appendingPathComponent("Public/Drop Box/x/systat.app")
    try fm.createDirectory(at: planted.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let real = try #require(realpath(box.path, nil).map { s in defer { free(s) }; return String(cString: s) })
    let calls = box.appendingPathComponent("trust-calls").path
    let out = String(decoding: try installer("""
        HOME='\(box.path)'
        dest='\(box.path)/none/systat.app'
        me=$(id -u)
        only_trusted_can_change() { echo x >> '\(calls)'; false; }
        mdfind() { printf '%s\\0' '\(real)/Public/Drop Box/x/systat.app'; }
        refuse_downgrade 0.1.1
        echo carried on
        """), as: UTF8.self)
    #expect(out == "carried on\n")
    #expect(!fm.fileExists(atPath: calls), "not looked up")
}

@Test func theInstallerStopsSayingWhyWhenItCantDropAnExportedFunction() throws {
    // bash imports a function named [ but can't unset it: the installer stops there, saying so,
    // rather than run with it standing in for test.
    let p = try installerProcess("echo ran")
    var environment = ProcessInfo.processInfo.environment
    environment["BASH_FUNC_[%%"] = "() { return 0; }"
    p.environment = environment
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    #expect(p.terminationStatus == 1)
    #expect(o.isEmpty)
    #expect(e.contains("your environment exports a shell function named ["))
}
