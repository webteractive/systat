import Foundation

/// The sh helper that reopens systat after an update. The app swaps the new bundle into place
/// itself, in one rename, before it quits (see `UpdateInstaller.swapIn`); a running app can't open
/// a second copy of itself, so this waits for it to exit and then opens the new one.
///
/// It never changes the app in place, so being cut short leaves what's installed as it was. The
/// app passes it with `sh -c`, never as a file, so nothing on disk can be rewritten between the
/// app's checks and its run. Its stdin is a pipe from the app, which is how it knows when to act,
/// with no clock, locale or PID in the way:
/// - it reads one line, and does nothing unless that is `go`, which the app writes only once the
///   swap is in: a failed swap, or an app that died first, closes the pipe without it,
/// - then it reads until end of file, which comes when the app exits, however it exits, since the
///   app holds the pipe's write end until then and passes it to no other process,
/// - it opens the app in place (if it is to open it at all) only if it is the exact build the app
///   swapped in (the requirement pins its code directory hash), and only then removes the work
///   folder, which holds the old app (`oldApp`),
/// - otherwise it opens nothing and leaves everything where it is: whatever is in place now was put
///   there after systat quit (the installer, another update), or failed its check for some passing
///   reason, and the old app stays in the work folder, named, until pruning finds a working systat
///   in place,
/// - when it refused, or the open failed, it writes "failed: why" in place of the result file, for the app to
///   show, and says it straight away with `alert` (the message added as its last argument): the app
///   may never be opened again to show the note.
public enum RelaunchScript {
    /// Puts the message on screen: no window of systat's own exists any more by then.
    public static let alert = [
        "/usr/bin/osascript",
        "-e", "on run argv",
        "-e", #"display alert "systat couldn't finish updating" message (item 1 of argv) as critical"#,
        "-e", "end run",
    ]

    /// `open` is the command that opens the app, one word per element, with the target path added
    /// last; empty when nothing should be opened, and then it only removes the work folder, once the
    /// build in place is the one swapped in.
    /// `appPID` only delays the open: see the wait in the script.
    public static func render(appPID: Int32, target: String, workDir: String, oldApp: String, resultFile: String,
                              requirement: String, open: [String] = ["/usr/bin/open"],
                              alert: [String] = RelaunchScript.alert) -> String {
        // An app the swap once disabled can't be removed until it's opened up.
        let cleanUp = #"/bin/chmod -R -P u+rwx "$WORKDIR" 2>/dev/null; /bin/rm -rf "$WORKDIR""#
        let opening = open.isEmpty ? "" : """

                \(open.map(quote).joined(separator: " ")) "$TARGET" || \\
                    report "The new version is installed, but it couldn't be opened. Open $TARGET."
            """
        // Checked even with nothing to open: the work folder holds the old app, the only working copy
        // left if the new one isn't in place.
        let finish = """
            # A check that fails for some passing reason (killed when memory is short, say) gets a second try.
            if verified || { /bin/sleep 1; verified; }; then
                \(cleanUp)\(opening)
            else
                if [ -d "$OLDAPP" ] && [ ! -L "$OLDAPP" ]; then
                    KEPT="The previous version is at $OLDAPP."
                else
                    KEPT="The previous version is gone."
                fi
                report "systat couldn't confirm that $TARGET is the version it just installed\(open.isEmpty ? "" : ", so it didn't open it"). $KEPT If you didn't replace systat yourself, reinstall it with the installer."
            fi
            """
        return """
        trap '' HUP INT TERM
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        TARGET=\(quote(target))
        WORKDIR=\(quote(workDir))
        OLDAPP=\(quote(oldApp))
        RESULT=\(quote(resultFile))
        verified() {
            [ -d "$TARGET" ] && [ ! -L "$TARGET" ] && \\
                /usr/bin/codesign --verify --deep --strict -R=\(quote(requirement)) "$TARGET" >/dev/null 2>&1
        }
        # printf, not echo: sh's echo would read a backslash in a path as an escape. Written in place of
        # whatever is there, so a link left at that path is replaced, not written through; set -C
        # refuses a file put back meanwhile, which only this user could do in the private folder.
        # The alert may stay up for hours, and says to run the installer: the update lock (descriptor 3,
        # from the app) is let go of first, as nothing is left to check or open.
        report() {
            exec 3>&-
            /bin/rm -f "$RESULT"
            (set -C; printf 'failed: %s\\n' "$1" > "$RESULT") 2>/dev/null
            \(alert.map(quote).joined(separator: " ")) "$1" >/dev/null 2>&1
        }
        # The app says go once its swap is in; without that there is nothing to do.
        IFS= read -r word || exit 0
        [ "$word" = go ] || exit 0
        # Then the pipe closes when the app exits, however it exits.
        /bin/cat >/dev/null
        # Its PID can outlast the pipe for a moment, and LaunchServices may not see it gone yet: up to
        # 2 s more. A zombie or a reused PID only delays the open.
        i=0
        while [ "$i" -lt 20 ] && kill -0 \(appPID) 2>/dev/null; do
            i=$((i + 1))
            /bin/sleep 0.1
        done
        \(finish)
        """
    }

    /// Single-quotes a value for sh.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
