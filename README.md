# systat

A menu bar monitor for macOS that shows how much memory, CPU and disk the Mac is using, which processes are using them, and lets you quit one.

The icon is a small gauge. It turns red when a resource is critical, so you can glance up and see why the Mac is slow. Click it for the panel:

- **Three bars**: memory, CPU and disk, with figures: `9.7 of 16 GB · swap 1.2 of 2 GB`, `20% busy · load 4.8`, `279 GB free of 494 GB`.
- **Top 10 by memory or by CPU**, each with **Quit** and **Force Quit**. The list holds still while the pointer is over it, so a row can't move under your click.
- **Claude Code sessions** show as one row, labelled with the session's `--name` or its project folder. Their memory and CPU include their helper processes, and quitting a session quits its helpers too.

## Requirements

macOS 26 or later on Apple silicon.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/webteractive/systat/main/install.sh | sh
```

The installer:

- downloads the latest release and checks it against the release's SHA-256; it won't install a latest release older than the systat you have, in Applications (even one an update disabled), or in or running from a folder only you can change (one elsewhere in your home folder, as Spotlight finds it, or one running); name that version to install it anyway
- refuses a disk image or app that isn't signed and notarized by systat's own developer, and an app that isn't the version the release names, and installs exactly the build it checked
- quits your running systat (a copy running from somewhere other than `/Applications` is quit too, and it says so), replaces `/Applications/systat.app` and opens it, and prints any note a failed update left
- runs as you, not with `sudo`, so the app stays yours to update, and checks it can replace the copy in `/Applications` (yours, not locked, and that macOS lets your terminal change it) before it quits the running one
- works in `~/Library/Application Support/systat-install`, and refuses to if anyone else can change that folder or one above it, or it is on a network share, a drive that ignores ownership, or a disk image, as the updater does (the updater asks who mounted a volume instead)

To install a specific version, append `-s -- 0.1.0` to the `sh`. After that, systat updates itself (see [Updates](#updates)); running the command again also works.

You can also download `systat-<version>.dmg` from [Releases](https://github.com/webteractive/systat/releases) and drag systat into Applications. Releases are Developer ID signed and notarized by Apple, so they open without a Gatekeeper warning.

systat adds itself to your login items on first launch. To turn that off, open the panel, choose Settings… and switch off "Open at login".

## Updates

systat asks GitHub for the latest release once a day, starting a minute after it opens. When there is a newer one, the panel shows **Update to systat X**. Clicking it:

- downloads the release, checks it against the release's SHA-256, and opens the disk image only if it's signed by the same developer
- checks the new app is systat, at the version the release names, notarized and signed by the same developer as the copy you're running, and accepted by Gatekeeper
- swaps the new app into place in one step (the slot is never empty), quits and reopens it. If the new app fails its check once in place, the old one is swapped straight back. If even that fails, the new one is disabled so it can't open, the old one is kept, and the panel says where, in a note that stays until you dismiss it, even after systat quits. Any other failure is shown in the panel until the next check
- reopens the new app only if it is exactly the build that was checked. If it isn't (something replaced it after systat quit), it leaves it alone, opens nothing, and says so in an alert straight away, naming where the previous version is. That note is shown in the panel too, until you dismiss it
- runs one update at a time: a second one, from the panel or a terminal, is refused while the first is under way, and so is one while the installer command runs (the installer, likewise, won't start while an update is under way)

systat must be able to replace itself: if it's running straight from the disk image, it asks you to move it to Applications first. It also won't update itself in a folder other users can change, such as `/Users/Shared`, on a network share, on a drive set to ignore ownership, on a volume another user mounted, or on a disk that can't swap an app in one step (HFS+); use the installer command there instead. Nor will it update a copy another user owns, one with a folder others can change, or one it can't fully read, since it might not be able to remove the old version afterwards; each case has its own message. A copy locked in Finder (Get Info > Locked), or flagged append-only, or with such a file inside, has to be unlocked first. Nor will it update itself when run as root, or swap out a newer systat you put in its place by hand (it asks you to open that one instead). The installer command always installs to `/Applications`.

To turn the daily check off, open Settings… and switch off "Check for updates daily". "Check Now" checks once. From a terminal, `systat --update` does the same install, and `systat --check-update` only asks. If macOS won't let `--update` replace the app, allow your terminal in System Settings > Privacy & Security > App Management, or update from the panel. While `--update` downloads and checks the update, Ctrl-C stops it once the step it is on ends (a slow `codesign` or `spctl` run is ended at once) and leaves nothing behind; once the download is checked, Ctrl-C, Ctrl-\, closing the terminal and a plain `kill` are ignored until it exits, and from just before it quits the running copy, Ctrl-Z and a broken pipe too.

A build that isn't Developer ID signed, such as one made with `scripts/install-local.sh`, can check for updates but can't install them; it links to the release instead. 0.1.0 has no updater, so update from it with the installer command above.

**Uninstall:** switch off "Open at login", quit systat from its panel, and delete `/Applications/systat.app`. The updater's folder, `~/Library/Application Support/systat-update`, may also hold the previous version after an update that couldn't finish, and the installer leaves an empty `~/Library/Application Support/systat-install.lock` (and, after an install that failed partway, `systat-install`); delete them too, along with `~/Library/Caches/systat-update` (left by 0.1.1, which can hold its previous version) and, for a copy on another drive, the hidden `.systat-update` folder beside it.

## When the icon turns red

| Resource | Critical when | Clears when |
| --- | --- | --- |
| Memory | macOS reports critical memory pressure, or swap is over 4 GB while pressure is at warning | both conditions stop |
| CPU | over 85% busy for 30 seconds | under 85% for 30 seconds |
| Disk | under 15 GB free on the startup disk | 16 GB free or more |

Short CPU spikes don't turn it red. The panel opens on the CPU list when only CPU is critical, and on the memory list otherwise.

## Quit and Force Quit

- **Quit** asks the process to exit (an app's normal quit, or `SIGTERM`), so it can save its work. The row shows "Quitting…".
- **Force Quit** ends it at once (`SIGKILL`). It doesn't ask for confirmation.

systat acts only when you click. It only acts on processes you own, and it checks the row is still the same process (PID plus start time) before sending anything, so a reused PID is never hit.

These rows show no buttons:

- processes owned by root or another user: labelled `macOS — protected`, or `system — not yours` for third-party ones
- `loginwindow`, because quitting it logs you out

systat never asks for an admin password.

## Resource use

systat runs when the Mac is short of memory and CPU, so it is built to stay out of the way:

| Panel | CPU | Memory |
| --- | --- | --- |
| Closed (refreshes every 5 s) | about 0.1% | about 10 MB |
| Open (refreshes every 2 s) | about 3% | |

Its network use is the update check, one request a day to GitHub's API, which you can switch off, and the download when you click Update. It keeps two settings: that it has registered itself as a login item, and whether to check for updates. Updates work in `~/Library/Application Support/systat-update`, which holds a lock file between them and a note about the last update until you dismiss it or the next update goes in. Their working copies go there too (or, for an app on another drive, in a hidden `.systat-update` folder beside it), and so does the previous version if an update couldn't finish, until a later update, a day or more on, finds a working systat in place.

## Command line

The app's binary also answers a few flags, which are useful for checking a build:

```sh
/Applications/systat.app/Contents/MacOS/systat --version
```

| Flag | Does |
| --- | --- |
| `--version`, `-v`, `version` | print the version, plus the commit and build date of a packaged build |
| `--sample` | print one reading of the bars and both top-10 lists |
| `--snapshot <dir>` | render the panel (light and dark) and Settings to PNGs |
| `--bench [seconds]` | measure systat's own CPU use with the panel closed, then open |
| `--iconset <dir>` | write the app icon's PNGs as an iconset (the build uses this to make `AppIcon.icns`) |
| `--check-update` | ask GitHub whether a newer release exists |
| `--update` | install the newest release in place: quits systat, swaps it, and reopens it if it was running |
| `--help` | list the flags |

## Building from source

Swift 6.2 or later (Xcode 26), with no third-party dependencies.

```sh
swift test                    # unit and integration tests
scripts/install-local.sh      # build, ad-hoc sign, install to /Applications and relaunch
```

`install-local.sh` makes a local build for this Mac only. It isn't signed with a Developer ID.

## Releasing

Maintainers only. You need the Developer ID Application certificate in the keychain, and the `notary` notarytool profile (`xcrun notarytool store-credentials notary`, once per machine).

1. Rename the `## Unreleased` section of [CHANGELOG.md](CHANGELOG.md) to `## <version> — <date>` and commit it. That section becomes the release notes.
2. Run `scripts/release.sh patch` (or `minor`, `major`, `X.Y.Z`). Add `--dry-run` to see the plan without changing anything.
   - It checks signing, the tree and the tests before it pushes anything.
   - It bumps the version in `Resources/Info.plist`, then builds, signs, notarizes and staples the app and its DMG.
   - It tags the release and publishes `systat-<version>.dmg` and its `.sha256` to GitHub.
3. Install the published build with `./install.sh`, then delete `dist/`.

The in-app updater installs a release only when it carries both `systat-<version>.dmg` and `systat-<version>.dmg.sha256`, under exactly those names. A release without them is still offered, but only as a link to its page. `release.sh` uploads both.

`scripts/package.sh` does the packaging on its own:

- `--preflight` only checks signing.
- `--adhoc` makes an unsigned test DMG, for a machine without the certificate.

## License

[MIT](LICENSE)
