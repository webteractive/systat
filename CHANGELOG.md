# Changelog

Each section is the release notes for its version: `scripts/release.sh` publishes the section headed with the version it releases.

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
