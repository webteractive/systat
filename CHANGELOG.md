# Changelog

Each section is the release notes for its version: `scripts/release.sh` publishes the section headed with the version it releases.

## 0.1.2 — 2026-11-15

Security fixes to the updater from a second review. Update from 0.1.1 with Update in the panel or `systat --update`. That one update still runs 0.1.1's updater: if systat doesn't come back afterwards, open it yourself.

- systat now swaps the new version into place itself, in one step, before it quits: the app's slot is never empty, a new version that fails its check in place is swapped straight back, and one that can't be is made unopenable, with the old one kept.
- The update is pinned to the exact build that passed the checks, so nothing put in its place afterwards is swapped in or opened. The helper that reopens systat is never written to disk, never changes the app in place, and opens only that build. If something else is in place by then, it opens nothing, leaves it alone, and says why in an alert straight away. It waits for systat to quit on a pipe from systat, not a clock or a process list, so it works under any language or time zone setting.
- A failure found after systat quit is shown the next time it opens, even when it is already up to date, and a newer version offered later isn't blamed for it. It stays until you dismiss it or the next update goes in, and an update that's refused doesn't clear it. An open that fails is reported too, and so is an update that had to leave the previous version aside, which is kept as a note and no longer replaced by the next daily check.
- Update refuses when a systat newer than the one offered is already in the app's place (put there by hand), instead of swapping it out; the copy a stranded update left there, of the offered version, is still replaced.
- One update at a time, from the start of the download until systat quits: the panel and a terminal at once is refused within half a second, a second Update click does nothing, and the lock lasts until the helper that reopens systat has checked and opened the new version.
- `systat --update` reopens systat only if it was running, never reopens a new version that failed its check, reopens the copy it quit when the swap is refused (only if it is still that exact build and can start), says so whenever it leaves the copy it quit closed (or finds it gone), keeps the previous version when nothing is to be reopened and the new one isn't in place, quits any copy opened while it was quitting the first, stops cleanly on Ctrl-C during the download and its checks, once the step under way ends (a slow `codesign` or `spctl` run is ended at once), leaving nothing behind, ignores Ctrl-C, Ctrl-\, a closed terminal and a plain kill from the end of the download and its checks until it exits (and Ctrl-Z and a broken pipe from just before it quits the running copy), and says so when nothing will reopen it. If macOS's App Management blocks it, it says how to allow it. An update on a disk that can't swap an app in one step (HFS+) is refused before anything is downloaded.
- Clearer failures: an app moved or replaced during the download says so, a checksum that can't be fetched or read is a failed download, not a mismatch, an app run from the disk image is asked to move to Applications, a locked app (or one with a locked file in it, or locked during the download) is asked to be unlocked, GitHub's rate limit, an oversized answer or a repo with no release isn't called a network failure, a disk image with no systat in it or that won't eject isn't called one that couldn't be opened, a daily check returning just after an update failed no longer hides why, and an update that changed after its checks says so. Each tool it runs is stopped if it hangs for two minutes (an unmount on a stuck disk, say), instead of holding the update for good.
- A copy the updater had to disable has only its executable closed, so it can still be thrown away like any app.
- The installer command checks the release is signed by systat's own developer, asks Apple online that it is notarized, checks it is the version it names, and installs exactly the build it checked. With no version given, it won't install a latest release older than the systat in place, even one an update disabled, or older than a systat of yours in or running from a folder only you can change (elsewhere in your home folder, as Spotlight finds it, or running), which it would otherwise quit. Its downloads are capped in size and time, as the updater's are, and a failed one says whether the release, GitHub or the network was at fault. It works in `~/Library/Application Support`, not in Caches, which cleaner apps empty, and only if no one else can change that folder or one above it and it isn't on a network share, a drive that ignores ownership, or a disk image (the updater instead asks who mounted a volume), and it takes your home folder from your account, as the app does, not from HOME; it clears ACLs from its work folder and the new copy; one install runs at a time, and neither it nor an update starts while the other runs, and a copy that fails the last check after the move (or a move that failed partway) is taken out of `/Applications` (or disabled where it is), not opened. It refuses to run with `sudo`, checks it can replace the copy in Applications (yours, not locked, and that macOS lets your terminal change it) before quitting systat, reopens the old copy if it still can't remove it, quits only your own systat, stops cleanly on Ctrl-C or Ctrl-\ before that and ignores them (and Ctrl-Z) from quitting systat until it ends, clears out what an earlier run left (an image still mounted included), runs nothing if the download of the script itself is cut short, copies the app with the same permissions the updater gives it, replaces a copy the updater disabled, and prints any note a failed update left (and not one about an update that worked) as one line of plain text, as the panel shows it.
- It won't update systat on a network share, or when run as root, and it updates the app where it really is when it was opened through a link.
- Its update folder moves from `~/Library/Caches` to `~/Library/Application Support/systat-update`, where cleaner apps don't empty it, since it can hold the previous version after an update that couldn't finish. A run folder in it is kept while it may hold the only working copy, and pruned by a later update, once it is over a day old and a working systat is in place again. It is private, never used through a link, and must be one only you can change, like the app's folder, and a folder it creates is refused if it inherits an ACL that opens it.
- It won't update a copy of systat another user owns, one with a folder others can change (by permissions or ACL), or one it can't fully read, which it might not be able to remove after swapping it out, and it won't swap out a different app put at the same path during the download.
- The new app is copied out of the disk image without ACLs, group or other write, or setuid bits.
- A release link is used only if it is exactly the tag's page on this repo, and a download link only exactly as the release script names it.
- A note about an update is shown as one line of plain text, without control characters, ones that reverse how the line reads or hide, or anything that isn't UTF-8.
- A folder with an ACL entry that names only you no longer counts as shared.

## 0.1.1 — 2026-11-07

- systat updates itself. Once a day it asks GitHub for the latest release, and when there is a newer one the panel shows **Update to systat X**:
  - the download is checked against the release's SHA-256, and the new app must be systat at the release's version, notarized and signed by the same developer as the running one
  - the disk image must be signed by the same developer before it's opened, and Gatekeeper must accept the new app, which also checks the certificate hasn't been revoked
  - the old app is moved aside, not deleted, and is put back if the new one doesn't verify; if that happens, the panel says why the next time it offers the update
  - one update at a time, even if one is started from the panel and another from a terminal
  - it won't update itself in a folder other users can change, such as `/Users/Shared`, or on a drive that ignores ownership, and it only reopens an app that passes the same checks
- Settings has a switch for the daily check and a Check Now button.
- `systat --update` installs the newest release from a terminal, and `systat --check-update` only asks.
- 0.1.0 has no updater: update from it once with the installer command in the README.

## 0.1.0 — 2026-11-07

The first release.

- A gauge in the menu bar that turns red when memory, CPU or disk is critical:
  - memory: critical memory pressure, or swap over 4 GB under warning pressure
  - CPU: over 85% busy for 30 seconds
  - disk: under 15 GB free
- A panel with memory, CPU and disk bars, and the top 10 processes by memory or by CPU.
- Quit and Force Quit on your own processes:
  - each checks the row is still the same process before it signals, so a reused PID is never hit
  - processes owned by root or other users, and `loginwindow`, have no buttons
- Claude Code sessions fold their helper processes into one row, and quitting a session quits its helpers too.
- The list holds still under the pointer, so a row can't move as you click it.
- Opens at login, with a switch in Settings.
- An app icon to match: the menu bar gauge, drawn large on a graphite tile.
- About 0.1% CPU and 10 MB of memory with the panel closed, and about 3% CPU while it's open.
- Developer ID signed and notarized, with an installer: `curl -fsSL https://raw.githubusercontent.com/webteractive/systat/main/install.sh | sh`.
