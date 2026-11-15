# systat — design

2026-11-05. Status: reviewed, open decisions settled, waiting for approval.

The decisions left open in the first draft are now settled. The last section
lists them with the reasons for each.

## What it is

**systat** is a native macOS menu bar app for a quick look at the Mac's
resources: memory, CPU and disk. Its icon turns red when one of them is
critical, and its menu shows what is using them, with a one-click way to
quit the heaviest processes.

It has no Dock icon and no window of its own apart from Settings. It does
not show live numbers in the menu bar; Activity Monitor already does that.

Success: the icon turns red before the Mac starts to feel slow, and one
click on the menu shows what is to blame and gets rid of it.

## Goals

1. A menu bar icon that turns red when any one of RAM, CPU or disk is at a
   critical level.
2. For RAM and CPU, the top 10 heaviest processes, each with Quit and Force
   Quit.
3. Telling processes with the same name apart, so the right one gets killed.
4. Making it impossible to kill something that would freeze the Mac or log
   the user out.

## Non-goals

- Notifications, sounds or badges. The red icon is the only alert.
- Numbers or graphs in the menu bar.
- History, charts over time, or logs.
- Network, battery, GPU or temperature.
- A process list for disk. Disk gets a bar and nothing else.
- Killing anything automatically. systat only acts when the user clicks.
- Quitting processes owned by another user or by root, and asking for an
  admin password to do it.
- The App Store. (Developer ID signing, notarization and an installer were
  added for the first release, and in-app updates after it; see "Build and
  install" and "Updates".)

## Anti-goals

These would make systat a failure even if every feature works:

- **systat itself becoming a load.** It runs exactly when the Mac is short
  of RAM and CPU. Budget: under 1% CPU on average while the menu is closed, and
  under about 60 MB of memory. The builder measures both on the installed
  app before calling the work done.
- **Killing the wrong thing.** Force Quit has no confirmation, so the row
  clicked must be the process meant, and the list must not reorder under the
  cursor in a way that makes the user hit the wrong row.
- **Crying wolf.** If the icon is red during normal work, people learn to
  ignore it. Short spikes must not turn it red.

## Constraints

- Swift and SwiftUI.
- No Dock icon (`LSUIElement`).
- Targets macOS 26 on Apple silicon. Built with Xcode 26 and Swift 6.
- Installed into `/Applications/systat.app`. Releases are Developer ID signed
  and notarized; local builds are ad-hoc signed.
- Opens at login.
- Clear build output (`.build/`, the project's own DerivedData) when a build
  is done.
- No third-party dependencies unless one saves a lot of work.

## The menu bar icon

A small gauge: an arc with a needle and a hub.

- **Normal:** monochrome, drawn as a template image so it matches the other
  menu bar icons in light and dark mode. Needle points low (to the left).
- **Critical:** red `#C8232C`, needle points high (to the right). It is not a
  template image in this state, so the red survives.

SVG, 18×18 viewBox, stroke width 2, round caps:

- arc: `M2.5 12.5 a6.5 6.5 0 1 1 13 0`
- needle, normal: `M9 12.5 L6.2 7.6`
- needle, critical: `M9 12.5 L12.6 7.2`
- hub: circle at (9, 12.5), radius 1.6, filled

The icon has two states only. It does not show which resource is critical
or how many.

## Critical limits

A resource is critical when:

| Resource | Critical when |
| --- | --- |
| Memory | macOS memory pressure is at its critical (red) level, **or** more than 4 GB of swap is in use while pressure is at least at its warning (yellow) level |
| CPU | more than 85% busy, held for 30 seconds. Short spikes do not count |
| Disk | under 15 GB free on the data volume (`/System/Volumes/Data`); clears once 16 GB or more is free |

The icon is red while at least one resource is critical.

Two earlier drafts were dropped during review:

- "Swap over 75% full". macOS adds swap as it needs it, so used ÷ total sits
  high most of the time. A fixed amount is steadier.
- "Under 10% or under 15 GB free". On a typical 228 GB disk the 10% part
  (22.8 GB) always wins, so the 15 GB part never mattered.

Details:

- **Memory pressure** is the kernel's level
  (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical).
  This is the same signal behind Activity Monitor's pressure graph.
- **Swap in use** is the `used` figure from `vm.swapusage`.
- **Swap counts only while pressure is raised.** macOS gives swap back
  slowly: after a heavy spell, swap can stay above 4 GB for hours while
  pressure is back to normal and the Mac is fine. A red icon then would be
  crying wolf. Swap over 4 GB together with warning-level pressure is the
  case worth flagging.
- **CPU busy** is the whole machine across all cores: 100% minus idle, from
  the host CPU tick counters, measured between two samples.
- **CPU "held for 30 seconds"**: CPU turns critical once every sample in the
  last 30 seconds was over 85%. It clears once it has been at or under 85%
  for 30 seconds, so it does not flap around the line.
- **Memory** has no hold time. It changes slowly, and red memory pressure is
  already sustained by nature.
- **Disk** has no hold time either, but it turns critical under 15 GB free and
  clears only at 16 GB or more. Downloads, builds and purging move free space
  back and forth across one fixed line; the 1 GB gap stops the icon flapping
  there.
- **Disk free** is the space available for important use
  (`volumeAvailableCapacityForImportantUsage`), which counts purgeable space
  the way Finder does.
- **Units follow the app that shows the same number.** Memory and swap use
  2³⁰ bytes per GB, as Activity Monitor does, so 16 GB of RAM reads `16 GB`
  rather than `17.2 GB`, and the 4 GB swap limit is 4 × 2³⁰ bytes. Disk uses
  10⁹ bytes per GB, as Finder does, so the 15 GB and 16 GB disk figures are
  15 × 10⁹ and 16 × 10⁹ bytes.
- **Sleep resets the CPU hold.** If more than 15 seconds pass between two
  samples (the Mac slept, or systat was stalled), CPU goes back to normal and
  the 30-second count starts again. One busy sample after waking must not
  turn the icon red.

The limits are not editable in this version (see Settings).

## The dropdown

Opens when the menu bar icon is clicked. A SwiftUI `MenuBarExtra` in window
style suits it, since the menu has bars, a switch and buttons in rows; the
builder can choose otherwise. The panel is 380 pt wide.

From top to bottom:

### 1. Header

- Left: a status line. When critical, a red dot and "3 resources critical"
  in red. With one resource it reads "1 resource critical"; when none, it
  reads "All normal" in the normal text colour, with no dot.
- Right: when it last updated, in secondary grey. It reads "Updated just now"
  while readings arrive on time, and counts ("Updated 5s ago", then minutes)
  once the last reading is 3 s or more old. A label that changed every second
  would redraw the panel every second, which cost more than all the readings.

### 2. Three bars

One row each for Memory, CPU and Disk: the label on the left, a one-line
detail on the right, and an 8 pt bar under them.

| Bar | Fill | Detail line (example) |
| --- | --- | --- |
| Memory | memory used ÷ installed RAM | `7.9 of 8 GB · swap 4.9 of 6 GB` |
| CPU | % busy, whole machine | `90% busy · load 17.3` |
| Disk | space used ÷ capacity, data volume | `11 GB free of 228 GB` |

- "Memory used" is the figure Activity Monitor calls Memory Used: app memory
  + wired + compressed.
- When the Mac has no swap in use or allocated, the memory detail leaves the
  swap part out: `7.9 of 16 GB`.
- "Load" is the 1-minute load average.
- A bar is red (`#C8232C`) when its own resource is critical, and neutral
  grey otherwise. Not the accent colour: on a blue-accent Mac three blue bars
  read as progress or selection, and grey makes the red stand out more.
- When a reading changes, a bar eases to its new length (and into red) over
  about 0.4 s instead of jumping. With Reduce Motion on, it jumps. The fill is
  a Core Animation layer, so the system's render server runs the animation and
  systat does no work per frame.

### 3. Memory / CPU switch

A two-segment control. It picks which list is shown below it. Each time the
menu opens, it starts on the resource that turned the icon red: CPU when CPU
is critical and memory is not, Memory in every other case. A red icon is
clicked to find the culprit, so the menu opens on the list that holds it.

### 4. Top 10 list

Ten rows, heaviest first. Each row has:

- **rank** (1–10), small and grey
- **name** on the first line: the app's name for GUI apps, otherwise the
  name from argv[0] (see "Telling same-name processes apart")
- **second line**, small and grey: see "Telling same-name processes apart"
- **value**, right-aligned in tabular figures: memory such as `833 MB` /
  `1.2 GB`, or CPU such as `68%`
- **actions**: Quit and Force Quit buttons; or, for a protected process, the
  text "macOS — protected" and no buttons

Rows are about 40 pt tall. Force Quit is drawn in the red accent colour.

What the numbers mean:

- **Memory** per process is its physical footprint, the number Activity
  Monitor shows in its Memory column.
- **CPU** per process is its share of one core over the last sample interval,
  as in Activity Monitor, so a process can show more than 100%.
- The list covers every process on the Mac, including root and system ones,
  because system daemons such as `fseventsd` and `WindowServer` are often
  among the heaviest.
- **Reading other users' processes.** Checked on macOS 26.4: a normal app
  gets "Operation not permitted" from `proc_pid_rusage` and
  `proc_pidinfo(PROC_PIDTASKINFO)` for root and system processes, so it
  cannot read their footprint, resident size or CPU time directly. `/bin/ps`
  is setuid root and can: `ps -axo pid,user,rss,%cpu,comm` lists every
  process in about 0.1 s and 60 ms of CPU. So:
  - the user's own processes: footprint and interval CPU through `libproc`;
  - everyone else's: resident size and `%cpu` from one `ps` run per refresh.
    `ps`'s `%cpu` is a decaying average rather than a strict interval figure;
    that is close enough for ranking.
  - `ps` is asked for numbers only (`pid=,rss=,%cpu=`), never for names. A
    command name can contain a newline and so forge a line for another
    process. Names and paths come from the kernel instead: `proc_pidpath`
    works for every process, root ones included.
  - The kernel's start time for another user's process is not wall-clock
    time, so those rows show no age.
  - Resident size counts shared memory, so it is not the same figure as
    footprint. Values read from `ps` get a leading `≈` (e.g. `≈ 1.2 GB`,
    `≈ 40%`). That way the list doesn't present two different measures as
    one.
  - `top -l 2` would give footprint for every process but costs about 1.8 s
    and half a second of CPU per call, too heavy to run every 2 seconds.
  - A privileged helper is out (no admin password, see Non-goals).
- systat leaves itself out of the list.
- **Right after the menu opens**, memory values are current but per-process
  CPU needs two samples. The CPU list fills in on the next refresh, about 2
  seconds later, and shows a quiet placeholder until then.

**Keeping the list steady** (from the anti-goal above): when the pointer is
over the list, or within about a second of a click, the rows do not reorder.
Values can keep updating in place. Rows reorder again once the pointer leaves
the list.

The same goes for rows whose process has exited. Most often that is the row
just Force Quit. While the pointer is over the list, that row stays in place,
greyed out, reading "Ended", with no buttons. Removing it would move every row
below it up by one, under a cursor that is about to click Force Quit again
with no confirmation. Ended rows go once the pointer leaves the list.

### 5. Footer

Three plain menu-style items, with a fourth above them only when a newer
release is available (see "Updates"):

- **Update to systat X**, in semibold; while installing it reads "Updating to
  systat X…", and after a failure it shows the reason and a link to the
  release
- **Open Activity Monitor**
- **Settings…**
- **Quit** (quits systat)

## Quit and Force Quit

- **Quit** asks the process to close. For a GUI app, the polite terminate
  (`NSRunningApplication.terminate()`), so it can ask to save. For anything
  else, SIGTERM.
- **Force Quit** acts at once, with **no confirmation**: SIGKILL, or
  `forceTerminate()` for a GUI app.

**A `claude` session goes with its helpers.** Each Claude Code session
starts helper processes, such as its MCP servers. For a `claude` row:

- Quit and Force Quit signal the session and every process under it. At the
  moment of the click, systat collects the session's descendants owned by the
  user, then sends the same signal to all of them.
- The row's memory and CPU figures include those helpers, so the number
  shows what one click will free.
- Helpers that belong to a listed `claude` session are not listed as rows of
  their own, so the same memory is not counted twice.

Every other process is signalled on its own PID only. Killing a whole tree
elsewhere (for example a terminal and its shells) is riskier.

Behaviour around them:

- systat sends the signal to the exact PID shown in the row, not to "the
  process named X". Before sending, it checks that the PID still belongs to
  the same process (same start time). If the process has already gone,
  nothing is sent and the row shows "Ended" (see "Keeping the list steady").
- After a Quit, the row stays and shows a small "Quitting…" state until the
  process exits or the next few refreshes pass. If it is still running after
  about 5 seconds, the row goes back to normal so the user can choose Force
  Quit.
- If the signal fails, the row shows the reason in its second line ("Not
  permitted") instead of failing silently.
- The menu stays open after either action, so several processes can be
  killed in a row.

## Protected processes

macOS system processes (e.g. `fseventsd`, `WindowServer`, `airportd`, and
anything else whose death would freeze the Mac or log the user out) show
"macOS — protected" and have no kill buttons.

How to decide:

1. **Not owned by the user** (root, or a system account such as
   `_windowserver`): no kill buttons. systat could not signal these anyway
   without admin rights. If the executable lives in an Apple system location
   (`/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/usr/bin`), the row
   says "macOS — protected". Otherwise, for example a third-party root
   daemon, it says "system — not yours".
2. **Owned by the user but essential to the session**: a short built-in deny
   list, for processes whose death logs the user out or locks up the
   session. At least `loginwindow`, which runs as the user; the builder
   should check the user-owned system processes on a real Mac and add any
   others that fit. These show "macOS — protected".
3. Everything else owned by the user can be quit, including Apple apps that
   relaunch on their own (Finder, Dock).

## Telling same-name processes apart

When several processes share a name, a second line tells them apart:

| Process | Second line |
| --- | --- |
| `claude` started with `-n <name>` | the session name, e.g. `my-project` |
| `claude` started with `--resume <id>` | `session ` + the id's first 8 characters, e.g. `session 1a2b3c4d` |
| an app running from outside `/Applications` | its path, e.g. `/tmp/test-build` |

The rest:

- **Names come from argv[0], not the executable path.** `claude` runs from
  `~/.local/share/claude/versions/<version>`, so naming by path shows a
  version number such as `2.1.318` (as `top` does). Use the basename of
  argv[0], and the app name for GUI apps. For other users' processes, where
  argv cannot be read, use the executable name `ps` gives.
- **`claude` flags:** `-n`/`--name <name>` gives the session name;
  `-r`/`--resume <id>` gives the id. A bare `--resume` or `-r` with no id, or
  `--continue`/`-c`, shows `resumed` plus the project folder (next point).
- **Every row gets a second line**, not only duplicates, so the rows line up.
  For a row with nothing better, it is a short description for well-known
  system processes (`fseventsd` → "File change tracker", `WindowServer` →
  "Display server", `airportd` → "Wi-Fi daemon"); for a GUI app, the folder
  its `.app` is in, e.g. `/Applications` (the first line already carries the
  app's name, so repeating it would say nothing); or else the executable's
  folder. Paths under the home folder are shown with `~`.
- **A `claude` with none of those flags** shows the last folder of its
  working directory (the project it was started in), falling back to
  `pid <n>`.
- **Any executable outside `/Applications`, `/System` and the usual system
  folders** shows its path when another row has the same name. This is what
  catches a stray test build running alongside the installed app. `claude`
  is exempt: it always runs from outside `/Applications`, and its session
  name is what tells its rows apart.
- **Age**: when a process has been running for more than a day, the second
  line ends with its age, e.g. `session 1a2b3c4d · 13 days`. Long-running
  idle processes are often the ones worth quitting.

Reading another process's arguments, working directory and start time works
for the user's own processes; for others, show what can be read.

## Refresh

- Every **2 seconds** while the dropdown is open.
- Every **5 seconds** in the background, when it is closed.

To keep systat light: in the background, systat only reads the
three machine-wide figures it needs to colour the icon. It lists processes
only while the dropdown is open, and refreshes once immediately when the
dropdown opens. Also:

- Disk free space is the costliest machine-wide reading and changes slowly,
  so it is read at most every 30 s while closed and every 10 s while open.
- `ps`, which supplies other users' processes' figures, runs every other
  refresh while open (every 4 s). The user's own processes, the ones with
  kill buttons, are read fresh every 2 s.
- A process's path and arguments are read once and kept while it runs; the
  working directory is read only for `claude` rows, which need it. The cache
  is dropped when the menu closes.
- The panel's views exist only while it is shown.

Measured with `systat --bench` on macOS 26.4 (about 800 processes): about
0.03% CPU with the menu closed and about 2.8% while it is open.

## Settings…

A small window with:

- **Open at login** (on by default), through `SMAppService.mainApp`
- **Check for updates daily** (on by default), with the check's status and a
  **Check Now** button (or **Update** when one is available)
- the three critical limits shown read-only, as a reminder of what turns the
  icon red

Editable limits are left out of this version. Adding them later should only
mean wiring the existing values to a settings store.

## Updates

Ported from zetty's updater, with additions: the identity, team, version and
Gatekeeper checks, the pinned build, the swap in one rename, the lock, the
pipe the helper waits on and the result file below, and the quarantine
attribute is left alone rather than stripped.

- Once a day, starting a minute after launch, systat fetches
  `api.github.com/repos/webteractive/systat/releases/latest`. That one request
  is its only network use until the user starts an update (which downloads
  the image and its checksum), and the Settings switch turns it off. A failed
  daily check changes nothing on screen; Check Now reports it, naming GitHub's
  rate limit (403 or 429), no release at all (404), and an answer that can't
  be read (or is over 1 MB) apart from a network that can't be reached. Once
  the image has opened, one that holds no real `systat.app`, or won't eject,
  says so, not that it couldn't be opened.
- The tag must be a plain `X.Y.Z` (an optional `v`) and newer than the running
  version. A build whose version isn't one (a dev build) is never offered an
  update.
- Only assets named exactly `systat-<version>.dmg` and `.dmg.sha256`, at this
  repo's download path for that tag, over https on github.com (no other port,
  no user or password in the URL), are used. Without both, the update is
  offered only as a link to the release page, which must be exactly this
  tag's page on this repo, `https://github.com/webteractive/systat/releases/tag/<tag>`
  compared as written (so no query, fragment, encoding, dot segment or other
  page gets through); anything else links to the releases page instead. These checks keep the answer to this repo's files; they aren't what
  makes the download safe (GitHub redirects every asset to another host, and
  URLSession follows). The signature checks below are.
- Every response is read with a cap, failing as soon as it goes over: the
  release answer at 1 MB, the image at 200 MB, the checksum at 1 KB. The
  release request gives up after 15 s with nothing coming, the downloads
  after 30 s, and each after 5 minutes in all.
- **Update** is refused when the slot already holds a systat newer than the
  one offered (put there by hand while this one ran): swapped out, it would
  then be deleted, so the user is asked to open that one instead. Compared
  with the offered version, not the running one, so the copy a stranded
  update left there (the offered version, disabled) is still replaced.
- **Update** is refused when systat runs as root: the ownership checks below
  would read the wrong owner, and the helper would open the app as root.
- It first resolves the app's real path (links followed), and the checks and
  the helper both use that path, so a link on the way to the app can't be
  re-pointed between them. Then it checks systat can replace itself: an app run from the DMG
  or translocated (a downloaded app opened in place) is asked to move to
  Applications, and the app and its folder must be writable (moving a folder
  to a new parent needs write access to the folder itself). The app's folder
  and every folder above it must be changeable only by the user, root or an
  admin (another admin can already replace anything in `/Applications`
  without the updater): owned by the user with no group or other write, or by root with no
  other write and group write only for wheel or admin (as `/Applications`
  is); no ACL entry allowing anyone but the user to add, delete or rename
  entries or change permissions (a group counts even when the user is in it); and on a local volume that keeps ownership (not one set to
  ignore it, and not a network share, which reports what its mount says
  whatever the server lets others do), mounted by the system or the user
  (a disk image another user attached, at a folder of theirs, holds
  whatever owners they gave its files, the user's included). Anyone else who could add, rename or
  remove entries there, in `/Users/Shared` say, could swap their own app in
  between the checks and the launch. An ACL that can't be read counts as
  one that lets others in. A locked app (Finder's Locked, the `uchg` flag,
  the system `schg` flag, or an append-only flag, on the app or anything in it; checked again just
  before the swap) can't be renamed, or its old copy never removed, and is asked to be unlocked rather than blamed on App
  Management. Inherit-only ACL entries count too: they
  grant nothing on the folder, but the folders the updater creates inside
  would inherit them. Everything in the installed app must belong to the
  user too (links judged as themselves), no folder in it may be changeable by
  others, by mode (group or other write) or by ACL (they could plant a folder
  of their own in it; a file others can write can't stop its removal, so only
  folders are checked for that), and a folder in it that can't be read is refused,
  since it can't be checked: swapped out, the old app is removed, and a copy
  another user installed (one group-writable, say) would otherwise sit in the
  run folder for good, since the user can't remove another's files. Each of
  the three has its own message (another user owns it; others can change a
  folder in it; part of it can't be read), and only the first says another
  user. The swap asks again just before it exchanges anything.
- An app run from the DMG or translocated is asked to move to Applications
  before the volume's swap support is checked: neither can swap, and moving
  it is what fixes both.
- One update at a time for the user: staging starts by taking a `flock`
  lock on `~/Library/Application Support/systat-update/lock`, held until the process
  drops what it staged, or, once its swap is in, until the relaunch helper
  is done checking and opening the new version: the helper inherits the
  lock (its descriptor 3), and lets go of it before an alert (the kernel
  drops it once no holder is left).
  Another update holding it, from the panel and a terminal at once, fails
  this one within half a second (a lock held only for a moment, by a
  probe, isn't another update) with "Another update is in progress" (a second click in
  the panel while it installs does nothing); a lock it can't open or take for any other reason fails it too, saying so. The lock is per
  user: two admins updating a shared `/Applications` copy at once aren't
  serialized, which gives neither of them anything admin access doesn't
  already give.
- It then stages, touching nothing installed: download (refused over 200 MB),
  SHA-256 against the sidecar (read up to 1 KB, the image hashed in 1 MB
  chunks; a sidecar that can't be fetched, or an image that can't be read
  back, is a failed download, not a mismatch), check the image's own signature (this team, notarized; its
  signing identifier comes from the file name, so it isn't pinned), so an
  image from anyone else is never mounted, mount read-only (and unmount it
  after, retrying a busy volume, or fail: a run folder with an image still
  mounted in it can't be removed), copy out
  `systat.app` only if it's a real folder
  and not a symlink (without ACLs, with group and other write removed, and
  with no setuid or setgid bit, since the code seal doesn't cover
  permissions; `ditto` drops those bits itself when not run as root), and
  check it meets
  `identifier "<id>" and anchor apple generic and certificate
  leaf[subject.OU] = "<team>" and notarized`, where `<id>` and `<team>` are
  read from the running app's own signature, so the source names nobody, plus
  Apple's Developer ID markers (`certificate 1[field.1.2.840.113635.100.6.2.6]
  exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists`), which
  the image's requirement carries too, so the team's development certificates
  don't match. The check enforces revocation. Its
  `CFBundleShortVersionString` must equal the release's version. Both close
  the gap a compromised release would use, since the checksum comes from the
  same release: an old notarized systat re-tagged as new (a downgrade), or
  another notarized app from the same team renamed `systat.app`. Last,
  `spctl --assess`: the swapped-in app has no quarantine flag, so Gatekeeper
  wouldn't look at it on launch. With Gatekeeper turned off `spctl` accepts
  anything, which is why the revocation check above doesn't rely on it. An ad-hoc build has no team and can't install.
  Before any of these checks, the requirement is pinned to this very build:
  `and (cdhash H"…" or …)`, one code directory hash per architecture of its
  executable (each architecture is checked on its own and matches its own).
  The signature check and every later one use the pinned requirement, so
  nothing put in the staged app's place during or after these checks, even
  another notarized systat, can be swapped in or opened. A staging that fails removes its run folder the
  way pruning does, unmounting an image left mounted in it.
- Then systat swaps it in itself, before it quits, still holding the lock:
  it checks the installed app is still a real folder where it was, and the
  very one the checks were made on (same device and inode: another bundle
  put at that path meanwhile would be swapped out and removed) ("systat was
  moved, replaced or deleted while the update was being prepared"), and the staged
  app is one too and meets the pinned requirement ("changed after it was
  checked"; both asked of the path then, with `lstat`, not from a URL's
  cached answers, since `RENAME_SWAP` would swap a link in as readily), then
  writes a `swapped` mark in the run folder naming the slot, the pinned
  build and the unpinned requirement (or fails, changing nothing):
  from here on the run folder may hold the only copy of the old app. Then
  it exchanges them in one rename
  (`renamex_np` with `RENAME_SWAP`), so the slot is never empty and the old
  app ends up where the staged one was. An exchange refused with `EPERM` is
  macOS's App Management, which attributes `systat --update` to the
  terminal it runs in: the message says to allow that terminal or update
  from the panel. Moving a running app's bundle is fine: its code is
  already mapped. It checks the app now in place against the pinned
  requirement, and if that fails it exchanges them back ("didn't verify once
  in place, so the old one was put back"). If even that fails, the app in
  place is made unopenable (its executable set to mode 0, so neither Finder
  nor the login item can start it, while the app can still be thrown away
  like any other; never through a link, which would close whatever it
  points at), the old app is kept as `previous.app` in the work folder, and
  the message names the new version's path and where the old one is (or
  says it couldn't be kept, if it is gone), says the new one "may not work"
  rather than "was disabled" if the mode change failed, and, for a copy
  outside `/Applications`, that the installer installs to `/Applications`.
  systat is still running then, so the panel shows it, as a note like the
  helper's (no later check replaces it; Update isn't offered straight away,
  while the note says to use the installer, and comes back with the next
  check, since another update can replace the disabled copy), and it is
  written to the result file too: the login item can't start the disabled copy, and the message would
  otherwise go when systat quits. The installer
  command opens such an app up before it removes it (as it does one an
  earlier build closed by its `Contents/MacOS` folder). Whatever removes a
  run folder later opens such an app up first, and unmounts an image left
  mounted in it. The
  installed app is never deleted before its replacement verifies (zetty
  0.1.40 shipped a helper that did, and an interrupted copy left an app that
  couldn't launch).
- A running app can't open a second copy of itself, so an `sh` helper
  (`RelaunchScript`) reopens it. It starts before the swap (`posix_spawn`,
  in a session of its own, so a terminal's Ctrl-C or hang-up or a kill
  aimed at systat's process group never reaches it), with its stdin a pipe
  from systat, /dev/null for output, the update lock as descriptor 3 (from
  a copy numbered above 3, as a dup onto itself would leave it
  close-on-exec; it lets go of it before an alert, which may stay up for
  hours and says to run the installer) and no other file systat has open, and
  acts only on that pipe: systat writes `go` once
  the swap is in, and a failed swap closes the pipe without it, so the
  helper exits having done nothing. After `go` it reads until end of file,
  which comes when systat exits, however it exits: systat holds the write
  end until then (close-on-exec, and never handed to another process: the
  tools systat runs through Foundation's `Process` get no file it didn't
  pass them, so the moment before close-on-exec is set leaks nothing) and
  ignores SIGPIPE on it; a helper let go is reaped off the main thread. No clock, locale or process list is involved (an
  earlier version compared `ps` start times, which print in the locale and
  time zone, and so never matched when the app's environment and the
  helper's differed). Then it waits up to 2 s more while systat's PID is
  still alive, so LaunchServices sees it gone; a zombie or a reused PID only
  delays the open. It is passed with `sh -c`, never written to a file, so
  nothing on disk can be changed between the app's checks and its run. It
  never changes the app in place, so being cut short leaves what's
  installed as it was. It gets a fixed PATH and only
  HOME, USER, LOGNAME and TMPDIR from systat's environment, ignores HUP, INT
  and TERM (its first line), sets its PATH again and calls every tool by
  path. It opens the app in place only if it meets the pinned requirement
  (checked twice a second apart before it gives up, so a `codesign` killed
  when memory is short doesn't cost the open), and removes the work folder.
  It removes the work folder only then, even when it has nothing to open
  (`systat --update` with no copy running): the folder holds the old app,
  the only working copy left if the new one isn't in place.
  Otherwise it opens nothing and changes nothing: what's in place was put
  there after systat quit (by the installer, or another update), or failed
  its check for some passing reason, and either way disabling it would
  leave the user with an app that can't start and no way to see why. The
  old app stays in the work folder, named in the note (or the note says it
  is gone), until pruning finds a working systat in place. A refusal, or an
  open that fails, is written as "failed: why" (with `printf`, since sh's
  `echo` would read a backslash in a path as an escape) to
  `~/Library/Application Support/systat-update/result` (in place of whatever
  is there, so a link left at that path is replaced, not written through;
  systat writes its own notes the same way, creating the file afresh without
  following a link), and shown at once in
  an alert (`osascript`, the message passed as an argument, never as
  script): the note waits for systat's next launch, which may not come
  soon. The open command is quoted word by word. If the helper is gone by
  the time systat writes `go`, the write fails (it is checked), and systat
  writes the note itself if the helper was to reopen it: the new version is
  installed but nothing will. Any note left from an earlier update is cleared once the next
  update's swap is in, not before: a swap refused changed nothing, so the
  note still stands. While systat runs on after the swap, its
  old process reads any resources from the new bundle; systat has one
  executable and no frameworks, so nothing it loads late can mismatch.
- systat reads that result file at launch (and the one 0.1.1 kept in
  `~/Library/Caches/systat-update`, where its helper reports the update to
  this version), and keeps both until the note is dismissed or the next
  update's swap goes in, so quitting before reading it loses nothing.
  It reads only a regular file of the user's own,
  never through a link, never waiting on a pipe, and at most 4 KB, since
  this is at launch on the main thread; an empty one hides no other. A
  path in it can hold anything a file name can, so control characters (C0
  and C1) and format characters (which reverse how the line reads, or hide)
  are dropped, as is what isn't UTF-8 (a note cut short mid-character), and
  a tab, line break, or line or paragraph separator becomes a space. It
  shows the failure
  in the panel and in Settings as a note of its own, whatever the update
  state (often it is the new version, opened by hand, and up to date), and
  apart from any later offer, which was never tried, with a button that
  dismisses it and removes its files. An update refused, at once (another
  one running, say) or at the swap (App Management, say), leaves the note:
  it put nothing right. Failures before it quits are shown at once. A check
  already waiting on GitHub when an update starts leaves the install, or
  how it failed, alone; one that starts after a failure replaces it with
  the offer, as the README says ("until the next check"). The `systat-update` folder is kept at 0700
  (closed if it was left open), is never used through a link (it is opened
  without following one, and its owner checked), and, like the app's, it
  and every folder above it must be changeable only by the user, root or an
  admin, since the staged app can live there; one that can't be set up, or
  can't hold a run folder, has its own message, not the app folder's.
- The app's volume must be able to exchange two folders in one rename
  (`VOL_CAP_INT_RENAME_SWAP`; APFS can, HFS+ can't). That is checked with
  the folder checks, before anything is downloaded.
- Each attempt stages in its own `run-<uuid>` folder on the app's volume, so
  the swap is a rename: `~/Library/Application Support/systat-update` in a
  standard setup, or `.systat-update` beside the app on another volume. Not
  in Caches, which cleaner apps empty: a run folder can hold the only copy
  of the app. Each update also clears out 0.1.1's
  `~/Library/Caches/systat-update`: its stale runs and lock, and the folder
  once nothing is left (a run holding `previous.app` stays, and so does its
  result until the note is dismissed or the next update goes in: a 0.1.1
  helper may write it after launch, and after an update that worked it
  writes a line that is never shown, so never dismissed), and only if it is the user's own real folder that no one else
  can change.
  Beside the app only if the app's folder is the user's own and no one else
  can write to it, since anyone who can rename entries there could swap the
  staging folder or the app in it between the checks and the swap; the
  staging folder must be the user's own real folder (never a link) and is
  kept at 0700, as is each run folder, and is refused if it holds anything
  someone else owns (left open before, it could hold a planted entry that
  pruning would delete into) or carries an ACL entry that opens it. Each
  run folder is checked the same way once created, in case it inherited
  one. Anywhere else the update is refused
  with the "move it to a folder you own" message.
  Folders left by attempts that died more than a day ago are removed, except
  one whose app may be the only working copy of systat. Only real folders
  are looked at: a `run-` entry that is a link is never followed (removing
  it would unmount whatever is mounted at its target's `mount`). A run
  marked `swapped` is kept until its old app (`previous.app`, or
  `systat.app` if renaming it failed or the helper refused) is a leftover:
  when there's no app left, when the run holds the pinned build named in
  the mark (it never went in), or when the slot holds a working systat,
  one that meets the mark's unpinned requirement and whose executable can
  start (permissions aren't sealed, so an app whose executable only lost
  its execute bits still verifies; a disabled one, at mode 0, can't be read
  and fails either way).
  That covers the update that went in, and the slot put right later by the
  installer or another update. A mark that can't be read keeps the run.
  0.1.1 marked nothing, so a run it left holding `previous.app` stays: which
  slot it came from isn't known.
- Every tool the updater runs (`codesign`, `hdiutil`, `ditto`, `spctl`,
  `chmod`) is stopped after 2 minutes and counts as failed, so a hung tool
  or unmount can't hold the lock and the "Updating…" state until systat
  quits. The revocation check is not one of those tools: Security.framework
  makes it in-process, under its own network timeouts, not this limit.
- Once the swap is in, systat asks AppKit to quit. If that is cancelled (a
  modal sheet that refuses, say), it runs on holding the lock: the panel
  keeps showing "Updating…" with no button (a click would do nothing), and
  `systat --update` is refused with "Another update is in progress"; the
  helper waits for it, and opens the new version once it does quit.
- `systat --update` runs the same install from a terminal: it stages, quits
  the running copy it is replacing (matched by real path, however it was
  opened; copies elsewhere keep running), and looks again once it has quit
  (a copy opened meanwhile, by its login item say, would have its bundle
  swapped out from under it), then starts the helper and swaps, and the helper opens
  the new app once the command exits, only if a copy was running (otherwise
  it only removes the work folder, once the new app in place checks out); if
  the swap fails, it reopens the copy it quit, unless what's in place is a
  new version that failed its check, or isn't the copy it quit (it notes
  which file that was, and pins its build by code directory hash, before
  quitting it), or no longer is that build or can't start (or its build
  couldn't be read before quitting it); then it says it wasn't opened again,
  unless the error says what is in place (a stranded update). An app replaced during the download, which the swap
  then refuses, was what it quit, so that one is reopened.
  While it downloads and checks the update, Ctrl-C, Ctrl-\, a closed
  terminal or TERM stops it once the step under way ends (the download is
  cancelled, and a slow `spctl` or `codesign` run is ended at once; the
  app's own signature check, in-process, runs to its end), and staging removes
  its run folder (ejecting an image it attached), so nothing is left behind
  ("Stopped; nothing was changed"). Those four are watched before they are
  ignored, so none is lost in between, and once the download is checked
  they stay ignored, so none can end it with the update staged and left
  behind. From just before it quits the running copy until it exits it
  also ignores Ctrl-Z, a background job's terminal output or input (TTOU,
  TTIN) and a broken pipe, as the installer does (it never turns any of
  them back on: its last message and output, written out at exit, mustn't
  meet them), any of which would leave systat quit and not reopened. When the copy it
  quit is gone after a failed swap, it says so.
  `--check-update` only asks.

## Opening at login

On first launch systat registers itself as a login item with
`SMAppService.mainApp`, and the Settings switch turns it off and on. The
builder should confirm this works for an ad-hoc signed app in
`/Applications`; if it does not, a LaunchAgent in `~/Library/LaunchAgents`
is an acceptable fallback. Checked on macOS 26.4: `SMAppService.mainApp`
registers the ad-hoc app as enabled and allowed, with no approval prompt, so
no fallback is needed.

## Build and install

- Releases: `scripts/release.sh` bumps the version in `Resources/Info.plist`,
  and `scripts/package.sh` builds, Developer ID signs (hardened runtime, no
  entitlements), notarizes and staples the app and a DMG around it, with a
  `.sha256` sidecar. They are published as GitHub releases on
  `webteractive/systat`. `install.sh` at the repo root installs the latest
  release, or the version given; with none given, it refuses a latest
  release older than the systat in place, even one an update disabled
  (made readable, never runnable, so it can be verified), or older than a
  systat that verifies elsewhere in the home folder (as Spotlight finds
  it, read NUL-separated so a name holding a line break can't slip in a
  second path, and only whole paths in the home folder that are their own
  real paths, with no link another user could swap between checks; none in
  ~/Public/Drop Box, which takes anyone's files; none in the
  Trash, nor the updater's or installer's own work copies) or running from anywhere, which it would quit, opening the older
  latest in its place. Either counts only if it is wholly the user's, in
  folders no one else can change (one another user put in ~/Public/Drop
  Box, or one run from /Users/Shared, could be anything, and could hang
  the check), and is opened up first as the copy in place is. Running
  copies are looked at before the download and again before each quit (a
  copy started by a relative path is placed by its own working folder, one
  started through a link, under any name, by the executable it runs, and
  one started with macOS's own arguments counts as the app, as main.swift
  reads them; a command-line mode never does);
  the copy in place, if this quit already asked it to go, is given up to
  5 s to, then reopened, or the message says it may yet close and to
  reopen it. All this because the latest can be set back and would
  quietly downgrade it; each refusal says how to ask for that version by
  name. It verifies the checksum and the DMG's notarization before mounting
  it, then the app's signature and notarization, stages the app,
  and moves it into `/Applications` whole (a copy, when the home folder is on
  another volume; the check after the move catches a broken result). Both signatures must be
  systat's team's, and `codesign --check-notarization` asks Apple online
  (`spctl` says yes to everything with Gatekeeper off). It refuses to run as
  root, and checks it can replace the copy in place (the folder writable,
  nothing in the app another user's, nothing locked, and a folder made and
  removed inside it, which macOS's App Management refuses a terminal it
  hasn't allowed) before it quits systat. If the old copy still won't go,
  it keeps the new one in its work folder, says what is left in place
  (intact, or possibly broken), and opens the old one again if systat was
  running and it still works. Removing it, too, adds no execute bit to a
  file, so a disabled executable stays unrunnable if the removal fails. The
  probe can't be cut short by Ctrl-C or Ctrl-\: left behind, it would break
  the app's seal.
  It clears group and other write and setuid bits from the copy, as the
  updater does. Ctrl-C or Ctrl-\ before it quits systat ends it cleanly;
  from quitting systat until it ends, they are ignored, and so
  are Ctrl-Z, TERM and a background job's terminal output or input, as
  `systat --update` ignores them, and a closed terminal can't stop it opening systat (its
  output then fails, which it ignores). A broken pipe (its output piped
  to a reader that goes away) is ignored throughout: a write that then
  fails ends it through its cleanup, or, in the critical part, is ignored
  too. Before it is checked, the staged copy
  is pinned by the code directory hash of each architecture (read from
  `codesign -d`), which covers its Info.plist and so its version, and every
  check is made against that pin. Once systat has quit, it verifies the staged copy again against
  that pin (a second try a second later, as for the check after the move)
  before removing the old one: one gone, changed or replaced
  meanwhile installs nothing and, if
  systat was running, opens the copy in `/Applications` again, only if it
  verifies as systat and its executable can run (one with its execute bits
  cleared still verifies). If there is no working copy there, the message says to run the
  installer again; if it won't open, to open systat yourself. Before quitting systat it opens up the copy
  in place for its owner (`u+rwX`), so `find` and the probe can check it:
  no file gets an execute bit it didn't have, so an executable the updater
  disabled stays unrunnable if the install stops. A last check after the move (the pinned build) decides whether the copy is opened; one that fails is
  taken out of the way (below), not opened, with a message to run the installer again. The whole script is one
  function called on its last line, in braces (read whole before it runs),
  so a download cut short anywhere under `curl | sh` runs nothing, not even
  `main` without the version asked for, and it sets its own PATH, drops
  exported shell functions (stopping, and saying why, at one bash can't
  drop) and unsets CDPATH and GREP_OPTIONS (any could
  change what a check sees), and
  takes the home folder from the account, as the app started from the
  Dock or at login does, not from HOME (nor `CFFIXED_USER_HOME`, which
  that app never has; the updater takes its state folder from the account
  the same way); it unsets PERL5OPT and PERL5LIB too, as it runs perl. A systat
  started by a relative path is judged by its own working folder (`lsof`),
  not the installer's. Of the notes an update left,
  it prints only a failure, as one line of plain text the way the app shows
  it (C0 and C1 controls and the characters that reverse how a line reads
  or hide are dropped, a tab, line break or separator becomes a space, and
  what isn't UTF-8 is left out, U+FFFD too, and spaces trimmed at both
  ends: the same filter as the app's, which a test holds them to), and
  removes them all. Its downloads are capped as the updater's are (1 MB for
  the release answer, 200 MB for the image, 1 KB for the checksum) and given
  up on as the updater's are (the release answer after 15 s with nothing
  coming, a download after 30 s, either after 5 minutes in all); a failed
  download says, by the HTTP status first (with redirects curl can report
  a 404 as a failed read), whether the release (or the file in it) isn't there, GitHub
  refused (its rate limit) or failed, the file is too large, or the network
  failed or timed out. It works in
  `~/Library/Application Support/systat-install` (0700, its ACL cleared so
  nothing in it inherits one), not in Caches, which cleaner apps empty: from
  removing the old copy until the move, the new one there is the only one.
  Application Support and every folder above it must be on a volume that
  keeps ownership (asked of the system: `df` names the mount, `diskutil`
  says whether it keeps ownership, and a network share isn't a disk it
  knows; `mount`'s text isn't read, as a mount point can hold a line break
  and forge a line) and isn't a disk image (all another user can attach;
  `diskutil` doesn't say who mounted it, which the updater asks of the
  kernel instead), with its own message, and be changeable only by the user (root, or the
  admin group for a system folder, aside), by permissions or by an allow ACL
  for anyone else (an ACL it can't read fails it), the rule the updater
  applies to its own folders: anyone else could swap the work folder, and an
  inherited ACL that lets them write would pass on to every file of the new
  copy, which `codesign` doesn't look at. The copy's ACLs are cleared too
  (files and folders only, never through a link). One install runs at a
  time: a `flock` on `systat-install.lock` beside it (`lockf` on a
  descriptor the script holds open), let go when the script ends however it
  ends, so a lock file left behind means nothing and no process ID can be
  taken for an install. The lock file is the user's and private (0600, its ACL cleared; the
  updater's lock file is too), as
  another user who could open it could hold it and stop every install and
  update; the perl holder's "held" file is the run's own, and goes with it; a folder it can't write, or a lock it can't open,
  has its own message. It won't start while
  systat updates itself (the updater's `flock`, probed with `lockf`, and
  0.1.1's in Caches; a lock it can't open has its own message), and the
  updater refuses to start, saying the installer is running, while that
  lock is held (probed with a shared `flock`, let go at once): each would take
  the other's copy for one it can replace. A lock held only for a moment (the
  other side probing it) isn't taken for the other running: the installer
  waits up to a second for its own and probes the updater's twice, the
  updater tries its own for half a second and probes the installer's twice.
  With a `lockf` older than macOS 26.4, which has no descriptor form, a
  `perl` process of the installer's own holds its lock while the script
  runs (not `lockf`, which resets TERM): it ignores the signals the script
  ignores, runs in a process group of its own, says once it holds the lock
  (the installer waits for that, not for it merely being alive), and lets
  go within half a second of the script's end (it is held while the script
  is its parent, not while a process ID lives, which could be reused); it
  waits up to a second for the lock, as `lockf -t 1` does. Its `curl` runs with `-q`, so no `~/.curlrc` setting
  applies. Each takes its own lock before
  looking for the other's, so of two starting together at least one sees
  the other. A failure once the old copy is gone keeps the work folder
  (the new copy is only there); the lock goes with the script. Only the app counts as running
  systat, not systat's command-line modes, which run the same executable.
  The app is a process started by systat's executable (argv[0], `ps`'s
  comm, made absolute: against the process's own working folder if
  relative, or the executable it runs if started through a link), ending
  in `/Contents/MacOS/systat`, with none of systat's command-line modes
  among its arguments (as main.swift reads them; macOS's own may follow),
  in a bundle whose identifier is systat's (or
  with no Info.plist left at that path, as when it was moved, trashed or
  half removed while it ran):
  not a command-line mode, nor a debugger given systat's path, nor another
  app whose executable is called systat. It quits each such process with a TERM, by process ID, every 2 s
  while any runs: systat does nothing on quitting that a TERM skips, and
  unlike an AppleScript quit, which goes through LaunchServices, it can't
  launch a copy that has just quit (or a stray bundle of the same name),
  nor wait on one that hangs. Which
  copy runs from `/Applications` is told by the path `app_command` gives
  (argv[0] made absolute, or the executable `lsof` names), compared as
  written (a copy at `~/Applications/systat.app` isn't that one), and a
  copy quit from elsewhere is mentioned on success as on an error. Just
  before the old copy goes it looks again: a systat opened meanwhile (by its
  login item, say) is quit the same way (noting which copy ran, and
  reopening the one at `/Applications` if another won't quit), and the
  staged copy is checked again after that wait. The copy at `/Applications` is the
  one it reopens on a failure, only if that copy was running; a copy
  running from elsewhere that it quit isn't reopened, and any error says
  so. If a copy still won't quit, the one at `/Applications`, if it was
  running and did quit, is opened again. Its downgrade check opens up the copy in place (as the checks before
  the quit do) and gives `codesign` a second try, so a check failing for a
  passing reason never lets an older build in. It starts by clearing out what an earlier
  run left there (and in `~/Library/Caches/systat-install`, where earlier
  installers worked), ejecting an image still mounted there, only if it really is a mount point, judged without following a link (forcibly, if it
  must). The last check after the move gets a second try a second later,
  as the helper's does. A copy that fails it, or part of one left by a move
  across volumes that failed partway (one whose copy finished and only the
  removal of the source failed passes, and goes on), is taken out of
  `/Applications` into the work folder (`rejected.app`), or, if it can't
  be moved, left with nothing executable in it, whatever its executable is
  called and never through a link, so it can't start from the Dock or at
  login. A latest release whose tag isn't a version is refused without
  printing the tag, and a refused downgrade says how to name the version. The release notes are the
  CHANGELOG.md section for the version.
- The app icon is the menu bar gauge drawn large: white on a graphite tile,
  the needle at rest, only the critical end of the dial red, so the Dock icon
  never reads as an alert. It is drawn in code (`AppIcon.swift`, beside
  `GaugeIcon`) and packed into `AppIcon.icns` by `scripts/build-app.sh`.
- `Resources/Info.plist` is the only place the version is written. It is
  embedded in the binary, and `scripts/build-app.sh` stamps the bundle with
  the commit and build date that `--version` prints.
- Not sandboxed: the sandbox blocks reading other processes and sending them
  signals.
- For development, `scripts/install-local.sh` builds the working tree,
  ad-hoc signs it, replaces the app in `/Applications`, and relaunches it.
  It uses `install.sh`'s own functions and checks (Application Support's
  trust and volume, and that the copy in `/Applications` can be replaced),
  refusing to run unless that script still ends in its `{ main "$@"; }` call,
  so it can never install the published release instead: it takes the install lock first, then stages
  in a folder of its own run's in Application Support (not Caches), clears
  group and other write, setuid bits and ACLs from the build (as the
  installer does a release's; the build's umask and folder may allow any)
  before signing and pinning it, builds without the install lock's
  descriptor (a daemon the build starts would keep it), won't
  run alongside an install or an update (their locks),
  checks it can replace the copy in `/Applications` (App Management)
  before quitting systat, quits it as the installer does (reopening it if it
  gives up before removing the old copy), ignores
  interruptions from the quit until it ends, checks the staged
  copy is still the very build it made (pinned by code directory hash)
  before removing the old one, keeps the staged copy (naming it) if
  replacing the old one fails, verifies the copy in place is that build
  before opening it (taking anything else, or part of a copy, out of the
  way, as the installer does), says when systat was left quit, and
  removes staging folders earlier runs kept.
- Clean the build output afterwards.
- For checking a build without clicking the menu bar, the binary also takes
  `--sample` (one reading of the bars and both top-10 lists, as text),
  `--snapshot <dir>` (renders the panel, both icons and Settings to PNGs),
  `--bench [seconds]` (CPU used with the menu closed, then open),
  `--iconset <dir>` (the app icon's PNGs, which the build packs into
  `AppIcon.icns`), `--check-update` and `--update` (see "Updates"),
  `--version` (also `-v` and `version`) and `--help`.

## Visual reference

Colours: panel `#F5F5F7` with a 1 px `#C9C9CE` border and
12 pt corners; text `#1D1D1F`; secondary text `#6E6E73`; bar track
`#E0E0E5`; switch track `#E3E3E8`; critical red `#C8232C`. The real app
should use system colours and materials where they exist, so it fits light
and dark mode, and keep `#C8232C` for critical.

## Left to the builder

- Project setup: a plain Xcode project, Swift Package, Tuist or XcodeGen.
- How the panel is hosted (`MenuBarExtra` window style, or an `NSStatusItem`
  with a popover or panel).
- Which system APIs read each figure, as long as the numbers match the
  definitions above.
- Exact spacing, typography and colours beyond the visual reference,
  following macOS conventions.
- How to test. The limit logic (including the CPU hold and its clearing) and
  the second-line naming rules are worth unit tests with fake samples; the
  readings from the system are not.

## Settled decisions

Settled 2026-11-05. Items marked *changed* differ from the first draft.

1. Settings holds only "Open at login" plus read-only limits; limits are not
   editable. Editable limits are a settings store away when someone wants
   them.
2. Processes not owned by the user never get kill buttons, and no admin
   password is ever asked for. Third-party ones say "system — not yours". A
   privileged helper was out of scope while systat was ad-hoc signed only;
   releases are now Developer ID signed, but a helper is still not wanted.
3. Protection for user-owned processes is a short deny list starting with
   `loginwindow`; Finder and Dock can be quit, since they relaunch. Checked
   on macOS 26.4: `loginwindow` is the only user-owned process whose death
   ends the session; `WindowServer` runs as `_windowserver`, and the other
   user-owned system processes are relaunched by launchd.
4. Every row gets a second line; `claude` without `-n` or `--resume` shows
   its project folder; rows older than a day show their age.
5. *Changed.* The list holds still while the pointer is over it, and that
   includes ended processes. A row that has just been killed stays in place,
   greyed out as "Ended", until the pointer leaves. Collapsing it would shift
   the rows under a cursor that is about to Force Quit again.
6. The menu stays open after Quit or Force Quit, and a Quit that has not
   worked after 5 seconds is shown as such.
7. *Changed.* CPU clears only after 30 seconds back under 85%. Memory has no
   hold. Disk has no hold but clears at 16 GB free, a 1 GB gap above the
   15 GB limit.
8. Disk free counts purgeable space, as Finder does.
9. In the background, only machine-wide figures are read; processes are
   listed only while the menu is open.
10. *Changed.* The switch opens on the resource that is critical: CPU when
    CPU is critical and memory is not, Memory otherwise.
11. *Changed (detail).* Bars are red only for the resource that is critical,
    and neutral grey otherwise, not the accent colour.
12. systat's own budget: under 1% CPU and about 60 MB of memory, measured on
    the installed app.
13. No history, no automatic killing, no network, battery or GPU readings.
14. Other users' processes are read through `ps` (resident size and `ps`'s
    `%cpu`), since a normal app cannot read them directly. *Changed
    (detail):* those values are shown with a leading `≈`.
15. Only `claude` rows take their helpers with them. Every other process is
    signalled on its own PID, and a session's helpers are folded into its row.
16. *Changed.* Swap over 4 GB counts as critical only while memory pressure
    is at warning level or above. macOS gives swap back slowly, so swap
    alone keeps the icon red long after the Mac has recovered.
