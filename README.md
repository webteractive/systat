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

- downloads the latest release and checks it against the release's SHA-256
- refuses an app whose signature or notarization doesn't verify
- quits a running systat, replaces `/Applications/systat.app` and opens it

To install a specific version, append `-s -- 0.1.0` to the `sh`. After that, systat updates itself (see [Updates](#updates)); running the command again also works.

You can also download `systat-<version>.dmg` from [Releases](https://github.com/webteractive/systat/releases) and drag systat into Applications. Releases are Developer ID signed and notarized by Apple, so they open without a Gatekeeper warning.

systat adds itself to your login items on first launch. To turn that off, open the panel, choose Settings… and switch off "Open at login".

## Updates

systat asks GitHub for the latest release once a day, starting a minute after it opens. When there is a newer one, the panel shows **Update to systat X**. Clicking it:

- downloads the release, checks it against the release's SHA-256, and opens the disk image only if it's signed by the same developer
- checks the new app is systat, at the version the release names, notarized and signed by the same developer as the copy you're running, and accepted by Gatekeeper
- quits, swaps the new app into place and reopens it; if anything fails, the installed copy is put back as it was, and the panel says why next time it offers the update

systat must be able to replace itself: if it's running straight from the disk image, it asks you to move it to Applications first. It also won't update itself in a folder other users can change, such as `/Users/Shared`, or on a drive set to ignore ownership; use the installer command there instead.

To turn the daily check off, open Settings… and switch off "Check for updates daily". "Check Now" checks once. From a terminal, `systat --update` does the same install, and `systat --check-update` only asks.

A build that isn't Developer ID signed, such as one made with `scripts/install-local.sh`, can check for updates but can't install them; it links to the release instead. 0.1.0 has no updater, so update from it with the installer command above.

**Uninstall:** switch off "Open at login", quit systat from its panel, and delete `/Applications/systat.app`.

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

Its only network use is the update check: one request a day to GitHub's API, which you can switch off. It keeps no data, except two settings: that it has registered itself as a login item, and whether to check for updates.

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
| `--update` | install the newest release in place: quits systat, swaps it, reopens it |
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
