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
- Auto-update or the App Store. (Developer ID signing, notarization and an
  installer were added for the first release; see "Build and install".)

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

Three plain menu-style items:

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
- the three critical limits shown read-only, as a reminder of what turns the
  icon red

Editable limits are left out of this version. Adding them later should only
mean wiring the existing values to a settings store.

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
  release: it verifies the checksum and the DMG's notarization before mounting
  it, then the app's signature and notarization, stages the app,
  and moves it into `/Applications` whole. The release notes are the
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
- Clean the build output afterwards.
- For checking a build without clicking the menu bar, the binary also takes
  `--sample` (one reading of the bars and both top-10 lists, as text),
  `--snapshot <dir>` (renders the panel, both icons and Settings to PNGs),
  `--bench [seconds]` (CPU used with the menu closed, then open),
  `--iconset <dir>` (the app icon's PNGs, which the build packs into
  `AppIcon.icns`),
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
13. No history, no automatic killing, no network, battery or GPU.
14. Other users' processes are read through `ps` (resident size and `ps`'s
    `%cpu`), since a normal app cannot read them directly. *Changed
    (detail):* those values are shown with a leading `≈`.
15. Only `claude` rows take their helpers with them. Every other process is
    signalled on its own PID, and a session's helpers are folded into its row.
16. *Changed.* Swap over 4 GB counts as critical only while memory pressure
    is at warning level or above. macOS gives swap back slowly, so swap
    alone keeps the icon red long after the Mac has recovered.
