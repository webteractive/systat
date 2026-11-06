#!/usr/bin/env bash
# Builds systat from this working tree, installs it to /Applications/systat.app
# and relaunches it. Local ad-hoc build only: not signed with a Developer ID, not
# for distribution. To install a release, run ./install.sh instead.
set -euo pipefail

cd "$(dirname "$0")/.."
app_name=systat
bundle_id=dev.inggo.systat
dest="/Applications/$app_name.app"
stage_root="$HOME/Library/Caches/systat-stage"
stage="$stage_root/$app_name.app"

cleanup() { rm -rf .build dist "$stage_root"; }
trap cleanup EXIT

scripts/build-app.sh

rm -rf "$stage_root"
mkdir -p "$stage_root"
mv "dist/$app_name.app" "$stage"
codesign --force --sign - --identifier "$bundle_id" "$stage"
codesign --verify --deep --strict "$stage"

osascript -e "quit app \"$app_name\"" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -x "$app_name" >/dev/null || break
    sleep 0.5
done
if pgrep -x "$app_name" >/dev/null; then
    echo "$app_name is still running and did not quit; /Applications was not touched." >&2
    exit 1
fi

rm -rf "$dest"
mv "$stage" "$dest"
open "$dest"
echo "Installed $("$dest/Contents/MacOS/$app_name" --version) (local ad-hoc build, not for distribution) to $dest"
