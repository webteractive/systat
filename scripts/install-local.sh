#!/usr/bin/env bash
# Builds systat, installs it to /Applications/systat.app and relaunches it.
# Local ad-hoc build only: not signed with a Developer ID, not for distribution.
set -euo pipefail

cd "$(dirname "$0")/.."
app_name=systat
bundle_id=dev.inggo.systat
dest="/Applications/$app_name.app"
stage_root="$HOME/Library/Caches/systat-stage"
stage="$stage_root/$app_name.app"

cleanup() { rm -rf .build "$stage_root"; }
trap cleanup EXIT

swift build -c release --arch arm64 --product "$app_name"
binary="$(swift build -c release --arch arm64 --show-bin-path)/$app_name"

plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
binary_version=$("$binary" --version | awk '{print $2}')
if [[ "$plist_version" != "$binary_version" ]]; then
    echo "Version mismatch: Info.plist says $plist_version, the binary says $binary_version." >&2
    exit 1
fi

rm -rf "$stage_root"
mkdir -p "$stage/Contents/MacOS"
cp "$binary" "$stage/Contents/MacOS/$app_name"
cp Resources/Info.plist "$stage/Contents/Info.plist"
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
echo "Installed $app_name $plist_version (local ad-hoc build, not for distribution) to $dest"
