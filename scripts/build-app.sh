#!/usr/bin/env bash
# Builds the release binary and assembles an UNSIGNED dist/systat.app around it.
# The callers sign it: scripts/package.sh with the Developer ID, and
# scripts/install-local.sh ad-hoc.
#
# The app icon is drawn by the binary itself (`systat --iconset`, see
# Sources/systat/UI/AppIcon.swift) and packed into AppIcon.icns with iconutil.
#
# The bundle's Info.plist is Resources/Info.plist plus SystatBuildCommit and
# SystatBuildDate, which `systat --version` prints. The commit ends in "-dirty"
# when the working tree has uncommitted changes.
#
# Usage: scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
app_name=systat
app="dist/$app_name.app"

swift build -c release --arch arm64 --product "$app_name"
binary="$(swift build -c release --arch arm64 --show-bin-path)/$app_name"

# arm64 only (spec: Apple silicon). Check the built executable, not the flags.
archs=$(lipo -archs "$binary")
if [[ "$archs" != "arm64" ]]; then
    echo "error: expected an arm64-only binary, got: $archs" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
binary_version=$("$binary" --version | awk '{print $2}')
if [[ "$version" != "$binary_version" ]]; then
    echo "error: Info.plist says $version, the binary says $binary_version" >&2
    exit 1
fi

commit=$(git rev-parse --short=7 HEAD)
if [[ -n "$(git status --porcelain)" ]]; then commit="$commit-dirty"; fi
date=$(date +%Y-%m-%d)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$app_name"

iconset=$(mktemp -d)/AppIcon.iconset
"$binary" --iconset "$iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SystatBuildCommit string $commit" \
    -c "Add :SystatBuildDate string $date" "$app/Contents/Info.plist"

echo "Built $app ($("$app/Contents/MacOS/$app_name" --version))"
