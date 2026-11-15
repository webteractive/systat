#!/usr/bin/env bash
# Builds systat from this working tree, installs it to /Applications/systat.app
# and relaunches it. Local ad-hoc build only: not signed with a Developer ID, not
# for distribution. To install a release, run ./install.sh instead.
set -euo pipefail
# cd looks a relative folder up through CDPATH (printing where it went): never here.
unset CDPATH

cd "$(dirname "$0")/.."
app_name=systat
bundle_id=dev.inggo.systat
user_path=$PATH

# install.sh's own checks and helpers: everything but its last line, `{ main "$@"; }`, which would run it
# (refused if that isn't its last line, so it can never install the published release instead). It
# sets its own PATH, `dest` (/Applications/systat.app) and `die`.
[ "$(tail -n 1 install.sh)" = '{ main "$@"; }' ] || { echo "install.sh no longer ends in its main call; not run" >&2; exit 1; }
eval "$(sed '$d' install.sh)"
me=$(id -u)
# The account's home folder, as install.sh and the app take it.
HOME=$(account_home) || die "couldn't find your home folder"
export HOME
support="$HOME/Library/Application Support"
mkdir -p "$support"
# The folder it stages in must be this user's alone, as install.sh's must.
volume_trusted "$support" || die "$support is on a network share, a drive that ignores ownership, a disk image, or a volume macOS can't vouch for"
only_trusted_can_change "$support" || die "someone else can change $support or a folder above it"
# A working copy of a local build: ad-hoc signed, so any valid signature, and an executable that runs.
works() { [ -x "$dest/Contents/MacOS/$app_name" ] && codesign --verify --deep --strict "$dest" 2>/dev/null; }

# Not alongside an install, another local install, or an update: each would take the other's copy for
# one it can replace. Taken before anything is staged.
if take_install_lock "$support/systat-install.lock"; then
    :
elif [ $? -eq 1 ]; then
    die "a systat install is running; wait for it, then run this again"
else
    die "couldn't open the lock $support/systat-install.lock"
fi
for ulock in "$support/systat-update/lock" "$HOME/Library/Caches/systat-update/lock"; do
    if updater_busy "$ulock"; then
        die "systat is updating itself right now; wait for it to finish, then run this again"
    elif [ $? -eq 2 ]; then
        die "couldn't open systat's update lock $ulock"
    fi
done

# A staging folder of this run's own, in Application Support, not Caches: a cleaner app could empty
# that while systat quits, and the old copy would go with no new one to put in its place. Earlier
# runs' folders, kept after a failed replace, go: holding the lock, no other run uses them, and a
# local build can always be built again.
rm -rf "$support/systat-stage" "$HOME/Library/Caches/systat-stage" "$support"/systat-stage.*
stage_root=$(mktemp -d "$support/systat-stage.XXXXXX")
stage="$stage_root/$app_name.app"
# Where reject_dest puts a copy that isn't the build just made, out of the Dock's and login's reach.
work=$stage_root
cleanup() { rm -rf .build dist "$stage_root"; }
trap cleanup EXIT

# Without the install lock's descriptor: a daemon the build starts (git's fsmonitor, say) would keep it.
PATH=$user_path scripts/build-app.sh 9>&-
mv "dist/$app_name.app" "$stage"
# As install.sh copies a release: no group or other write, no setuid, and no ACL (the build's umask and
# folder may allow any), before it is signed and pinned. The seal doesn't cover permissions.
chmod -R -P go-w,ug-s "$stage"
find "$stage" ! -type l -exec chmod -N {} +
codesign --force --sign - --identifier "$bundle_id" "$stage"
codesign --verify --deep --strict "$stage"
# Only this very build from here on.
this_build=$(pin_build "$stage" "identifier \"$bundle_id\"") || die "couldn't read the new build's code directory hash"
# Checked before systat is quit, as install.sh checks: one this user can't replace would leave it quit
# for nothing.
replaceable_or_die "systat wasn't quit"

# From quitting systat until the new copy is in place, Ctrl-C or a closed terminal must not stop it
# halfway: systat would stay quit, or be gone. Quit as install.sh quits it (quit_and_wait).
ignore_interruptions
was_running=no
elsewhere=no
quit_and_wait "/Applications was not touched"
# Reopened if it was running, quit, isn't running again, and still works; otherwise says why not.
reopen() {
    [ "$was_running" = yes ] || return 0
    app_running "$dest" && return 0
    if ! works; then
        echo "systat was quit, and $dest isn't a working copy to reopen" >&2 || true
    elif open "$dest" 2>/dev/null; then
        echo "$dest was opened again" >&2 || true
    else
        echo "systat was quit and couldn't be reopened; open $dest yourself" >&2 || true
    fi
}
# The staged build must still be the one just built before the old copy goes; a systat opened
# meanwhile is quit again, and the build checked again after that wait.
staged_or_die() {
    is_the_build_checked "$stage" && return 0
    reopen
    die "the staged build at $stage changed or is gone; /Applications was not touched"
}
staged_or_die
if app_running; then
    quit_and_wait "/Applications was not touched"
    staged_or_die
fi
# From here a failure must not take the staged copy with it: it may be the only one left.
trap 'rm -rf .build dist' EXIT
# Opened up first, as install.sh does: an earlier build may have closed a folder rm can't empty.
chmod -R -P u+rwX "$dest" 2>/dev/null || true
rm -rf "$dest" 2>/dev/null || true
if [ -e "$dest" ] || [ -L "$dest" ]; then
    # What is left is reopened if it still works, as install.sh does; otherwise it may be incomplete.
    if ! works; then
        if [ "$was_running" = yes ]; then
            die "couldn't remove $dest; what is left there may not work, so systat wasn't reopened; the new build is at $stage"
        fi
        die "couldn't remove $dest; what is left there may not work; the new build is at $stage"
    fi
    reopen
    die "couldn't remove $dest; the old copy is still in place; the new build is at $stage"
fi
left=
[ "$was_running" = yes ] && left=", and systat was left quit"
# Across volumes mv copies: one that fails partway leaves part of a copy at $dest, taken out of the way.
if ! mv "$stage" "$dest" && ! is_this_build; then
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        if reject_dest; then
            die "couldn't put the new build in $dest; the copy there (incomplete, most likely) $rejected, and the new build is at $stage$left"
        fi
        die "couldn't put the new build in $dest, and couldn't take the copy there out of the way; delete it; the new build is at $stage$left"
    fi
    die "couldn't put the new build in $dest; it is at $stage$left"
fi
# The very build just made, now in place, before it is opened; anything else is taken out of the way.
if ! is_this_build; then
    reject_dest && die "the copy now at $dest isn't the build just made, so it ${rejected}$left; run this again"
    die "the copy now at $dest isn't the build just made, and couldn't be taken out of the way; delete it$left"
fi
rm -rf "$stage_root"
open "$dest" || die "the new build is installed at $dest, but couldn't be opened; open it yourself"
if [ "$elsewhere" = yes ]; then
    echo "systat was${also:-} running from somewhere other than $dest; that copy is no longer running, and the one at $dest opened in its place" || true
fi
echo "Installed $("$dest/Contents/MacOS/$app_name" --version) (local ad-hoc build, not for distribution) to $dest" || true
