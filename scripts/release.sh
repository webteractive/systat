#!/usr/bin/env bash
# Cuts a systat release: version bump, commit, package, tag, GitHub release.
#
# The version lives in Resources/Info.plist (CFBundleShortVersionString), not in a
# package manifest, so generic release tools miss it. The release notes are the
# CHANGELOG.md section for the version, written by hand before running this. The
# release carries systat-<version>.dmg and its .sha256 sidecar, which install.sh
# verifies the download against.
#
# Everything that can fail cheaply is checked before anything is pushed: a clean
# tree on main, gh access to the repo, signing (package.sh --preflight), the
# CHANGELOG section, and the tests.
#
# Usage:
#   scripts/release.sh (patch | minor | major | X.Y.Z) [--yes] [--dry-run]
#
# An X.Y.Z equal to the current version releases it without a bump commit. That
# is how the first release, 0.1.0, ships.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=webteractive/systat
remote=origin
branch=main
plist=Resources/Info.plist
level=
assume_yes=0
dry_run=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) assume_yes=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        patch|minor|major) level=$1; shift ;;
        [0-9]*.[0-9]*.[0-9]*) level=$1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done
[[ -n "$level" ]] || { usage >&2; die "give a bump level (patch | minor | major) or an explicit X.Y.Z"; }

# --- Preconditions: nothing below changes anything -------------------------------
command -v gh >/dev/null || die "gh (GitHub CLI) is required"
permission=$(gh repo view "$repo" --json viewerPermission -q .viewerPermission 2>/dev/null) \
    || die "gh cannot see $repo; check the active account (gh auth status)"
case "$permission" in
    ADMIN|MAINTAIN|WRITE) ;;
    *) die "gh account $(gh api user -q .login) has '$permission' on $repo; it needs write access" ;;
esac

[[ -z "$(git status --porcelain)" ]] || die "the working tree is dirty; commit or stash first"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$branch" ]] || die "not on $branch"

scripts/package.sh --preflight >/dev/null || die "signing is not ready; run scripts/package.sh --preflight"

git fetch --quiet "$remote" "$branch"
[[ -z "$(git rev-list "HEAD..$remote/$branch")" ]] || die "behind $remote/$branch; pull first"

current=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
IFS=. read -r major minor patch <<<"$current"
case "$level" in
    patch) version="$major.$minor.$((patch + 1))" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    major) version="$((major + 1)).0.0" ;;
    *) version=$level ;;
esac
tag="v$version"
bump=1
[[ "$version" == "$current" ]] && bump=0

[[ -z "$(git tag -l "$tag")" ]] || die "tag $tag already exists locally"
[[ -z "$(git ls-remote --tags "$remote" "refs/tags/$tag")" ]] || die "tag $tag already exists on $remote"

# The notes are the CHANGELOG section headed "## <version>", up to the next "## ".
notes=$(awk -v v="$version" '
    $0 ~ "^## " { if (found) exit; if (index($0, "## " v " ") == 1 || $0 == "## " v) { found = 1; next } }
    found { print }' CHANGELOG.md)
[[ -n "${notes//[[:space:]]/}" ]] || die "CHANGELOG.md has no '## $version' section; write it, commit it, then release"

dmg="dist/systat-$version.dmg"
cat <<PLAN
Release plan
  version   $current -> $version$([[ $bump == 0 ]] && echo "   (no bump: releasing the current version)")
  commit    $([[ $bump == 1 ]] && echo "Release $tag (Info.plist; build $build -> $((build + 1)))" || echo "none")
  tag       $tag (annotated) on $remote
  assets    $dmg, $dmg.sha256
  notes     CHANGELOG.md, section $version ($(printf '%s\n' "$notes" | grep -c .) lines)
  repo      $repo, as $(gh api user -q .login)
PLAN

if [[ $dry_run == 1 ]]; then echo "[dry run] nothing was changed."; exit 0; fi
if [[ $assume_yes != 1 ]]; then
    printf 'Proceed? [y/N] '
    read -r reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || { echo "aborted."; exit 1; }
fi

echo "==> swift test"
swift test >/dev/null 2>&1 || die "tests failed; not releasing"

if [[ $bump == 1 ]]; then
    echo "==> bumping $plist to $version"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
        -c "Set :CFBundleVersion $((build + 1))" "$plist"
    git add "$plist"
    git commit -q -m "Release $tag"
fi
git push -q "$remote" "$branch"
release_commit=$(git rev-parse HEAD)

# After the bump, so the bundle carries the new version.
echo "==> packaging"
scripts/package.sh

[[ -f "$dmg" && -f "$dmg.sha256" ]] || die "expected $dmg and $dmg.sha256"
[[ "$(shasum -a 256 "$dmg" | awk '{print $1}')" == "$(cat "$dmg.sha256")" ]] || die "checksum mismatch: $dmg"
built=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/systat.app/Contents/Info.plist)
[[ "$built" == "$version" ]] || die "the packaged app reports $built, expected $version"

echo "==> tagging $tag"
git tag -a "$tag" "$release_commit" -m "systat $tag"
git push -q "$remote" "$tag"

echo "==> creating the GitHub release"
printf '%s\n' "$notes" > dist/notes.md
gh release create "$tag" --repo "$repo" --title "systat $version" --notes-file dist/notes.md "$dmg" "$dmg.sha256"

echo
echo "Released $tag ($release_commit)"
gh release view "$tag" --repo "$repo" --json url,assets -q '"  url     " + .url, "  assets  " + ([.assets[].name] | join(", "))'
echo
echo "Next: install the published build (./install.sh), then remove dist/."
