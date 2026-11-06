#!/bin/sh
# Installs the published systat release into /Applications and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/webteractive/systat/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/webteractive/systat/main/install.sh | sh -s -- 0.1.0
#
# It downloads systat-<version>.dmg from the GitHub release (the latest one, unless a
# version is given) and checks it against the release's .sha256. It refuses an app
# whose Developer ID signature or notarization does not verify. The app is staged
# outside /Applications and moved in whole: copying a signed bundle straight into
# /Applications can stop halfway and leave a broken seal.
set -eu

repo=webteractive/systat
app=systat
dest="/Applications/$app.app"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "systat is a macOS app"
[ "$(uname -m)" = arm64 ] || die "systat needs a Mac with Apple silicon"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || die "systat needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))"

if [ $# -gt 0 ]; then
    version=${1#v}
else
    version=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | plutil -extract tag_name raw -o - -) \
        || die "could not find the latest release of $repo"
    version=${version#v}
fi
# Digits and dots only, as X.Y.Z: the version becomes part of a path and a URL.
case "$version" in
    *[!0-9.]* | .* | *. | *..*) die "not a version: $version" ;;
    *.*.*) ;;
    *) die "not a version: $version" ;;
esac

work="$HOME/Library/Caches/systat-install"
mount="$work/mount"
cleanup() {
    hdiutil detach -quiet "$mount" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM
rm -rf "$work"
mkdir -p "$work"

base="https://github.com/$repo/releases/download/v$version"
dmg="$work/$app-$version.dmg"
echo "Downloading systat $version"
curl -fsSL -o "$dmg" "$base/$app-$version.dmg" || die "no systat-$version.dmg in release v$version"
curl -fsSL -o "$dmg.sha256" "$base/$app-$version.dmg.sha256" || die "no checksum in release v$version"
[ "$(shasum -a 256 "$dmg" | awk '{print $1}')" = "$(tr -d '[:space:]' < "$dmg.sha256")" ] \
    || die "the download does not match the release checksum"

# Mount only a notarized image. </dev/null: under `curl | sh` the script itself is stdin.
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null \
    || die "Gatekeeper rejects the disk image (not notarized?)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg" </dev/null
ditto "$mount/$app.app" "$work/$app.app"
hdiutil detach -quiet "$mount"

codesign --verify --deep --strict "$work/$app.app" || die "the app's signature does not verify"
spctl -a -t exec "$work/$app.app" 2>/dev/null || die "Gatekeeper rejects the app (not notarized?)"

osascript -e "quit app \"$app\"" >/dev/null 2>&1 || true
i=0
while pgrep -x "$app" >/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
pgrep -x "$app" >/dev/null && die "systat is still running and did not quit; nothing was changed"

rm -rf "$dest"
mv "$work/$app.app" "$dest"
codesign --verify --deep --strict "$dest" || die "the installed copy's signature does not verify"
open "$dest"
echo "Installed $("$dest/Contents/MacOS/$app" --version) to $dest"
