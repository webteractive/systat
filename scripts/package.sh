#!/usr/bin/env bash
# Packages systat into dist/systat-<version>.dmg (plus a .sha256 sidecar) for
# distribution. The app is Developer ID signed with the hardened runtime, then
# notarized and stapled. The DMG is built around the stapled app, then signed,
# notarized and stapled itself. A downloaded copy opens with no Gatekeeper override.
#
# Nothing in this repo names who signs. The identity is the one valid "Developer ID
# Application" certificate in the keychain, found at run time and used by its
# SHA-1 hash. notarytool authenticates through a keychain profile, created once per
# machine with `xcrun notarytool store-credentials notary`. To override either, set
# SYSTAT_SIGN_IDENTITY (a SHA-1 hash or a name) or SYSTAT_NOTARY_PROFILE.
#
# Usage:
#   scripts/package.sh              build, sign, notarize, staple, verify
#   scripts/package.sh --preflight  only check the identity and the notary profile
#   scripts/package.sh --adhoc      ad-hoc signed and NOT notarized, for a machine
#                                   without the certificate; never ship it
set -euo pipefail
cd "$(dirname "$0")/.."

sign_identity=${SYSTAT_SIGN_IDENTITY:-}
notary_profile=${SYSTAT_NOTARY_PROFILE:-notary}
app_name=systat
bundle_id=dev.inggo.systat

mode=release
case "${1:-}" in
    "") ;;
    --preflight) mode=preflight ;;
    --adhoc) mode=adhoc ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: scripts/package.sh [--preflight | --adhoc]" >&2; exit 2 ;;
esac

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Run before anything builds. release.sh runs it ahead of its version bump, so a
# missing certificate or profile stops the release before it pushes anything.
preflight() {
    if [[ -n "$sign_identity" ]]; then
        security find-identity -v -p codesigning | grep -qF "$sign_identity" \
            || die "SYSTAT_SIGN_IDENTITY is not a valid signing identity in the keychain"
    else
        # Sign by SHA-1 hash, not by name: a renewed certificate keeps its name, and
        # codesign refuses a name that two valid certificates share.
        local found
        found=$(security find-identity -v -p codesigning | grep '"Developer ID Application: ' || true)
        case $(printf '%s' "$found" | grep -c . || true) in
            0) die "no valid \"Developer ID Application\" certificate in the keychain (use --adhoc for a local test build)" ;;
            1) sign_identity=$(printf '%s' "$found" | awk '{print $2}') ;;
            *) printf '%s\n' "$found" >&2
               die "several Developer ID Application certificates; pick one with SYSTAT_SIGN_IDENTITY=<hash>" ;;
        esac
    fi
    xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
        || die "notary keychain profile '$notary_profile' is missing or rejected; run: xcrun notarytool store-credentials $notary_profile"
}

# Submits one file and waits for the verdict. notarytool exits 0 on an Invalid
# verdict too, so read the status from its JSON, and print Apple's log on a rejection.
notarize() {
    local out id status
    out=$(xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --output-format json) \
        || die "notarytool submit failed for $1"
    id=$(printf '%s' "$out" | plutil -extract id raw -o - -)
    status=$(printf '%s' "$out" | plutil -extract status raw -o - -)
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2 || true
        die "notarization of $1 ended '$status' (submission $id)"
    fi
    echo "notarized $1 ($id)"
}

if [[ "$mode" == preflight ]]; then
    preflight
    echo "signing ready: identity $sign_identity, notary profile '$notary_profile'"
    exit 0
fi
if [[ "$mode" == release ]]; then preflight; fi

work=$(mktemp -d)
trap 'rm -rf "$work" .build' EXIT

scripts/build-app.sh
app="dist/$app_name.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
commit=$(/usr/libexec/PlistBuddy -c 'Print :SystatBuildCommit' "$app/Contents/Info.plist")
if [[ "$mode" == release && "$commit" == *-dirty ]]; then
    die "the working tree has uncommitted changes; a shipped build must match a commit"
fi

if [[ "$mode" == release ]]; then
    # The app holds one executable and no nested code, so one signature covers it.
    # No entitlements: systat needs no hardened-runtime exception (no JIT, no
    # unsigned libraries, no debugging of other processes).
    codesign --force --timestamp --options runtime --identifier "$bundle_id" \
        --sign "$sign_identity" "$app"
    codesign --verify --deep --strict --verbose=2 "$app"

    # Notarize and staple the app itself before building the DMG, so the copy a
    # user drags out carries its own ticket.
    ditto -c -k --keepParent "$app" "$work/$app_name.zip"
    notarize "$work/$app_name.zip"
    xcrun stapler staple "$app"
    spctl -a -vvv -t exec "$app"
else
    codesign --force --sign - --identifier "$bundle_id" "$app"
    codesign --verify --deep --strict "$app"
fi

stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/$app_name.app"
ln -s /Applications "$stage/Applications"

dmg="dist/$app_name-$version.dmg"
rm -f "$dmg" "$dmg.sha256"
hdiutil create -volname "systat $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null

if [[ "$mode" == release ]]; then
    codesign --force --timestamp --sign "$sign_identity" "$dmg"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    spctl -a -vvv -t open --context context:primary-signature "$dmg"
fi

# Written last: stapling rewrites the DMG. install.sh verifies the download
# against it. Bare lowercase hex, nothing else.
shasum -a 256 "$dmg" | awk '{print $1}' > "$dmg.sha256"

if [[ "$mode" == adhoc ]]; then
    echo "Packaged $dmg + .sha256 (version $version, commit $commit): AD-HOC, not notarized, do not ship"
else
    echo "Packaged $dmg + .sha256 (version $version, commit $commit): Developer ID signed, notarized, stapled"
fi
