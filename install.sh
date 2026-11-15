#!/bin/sh
# Installs the published systat release into /Applications and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/webteractive/systat/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/webteractive/systat/main/install.sh | sh -s -- 0.1.0
#
# It downloads systat-<version>.dmg from the GitHub release (the latest one, never older than
# a systat of this user's, in place, elsewhere in the home folder or running, unless a version
# is given) and checks it against the release's .sha256. The image and the app must be signed
# with systat's own Developer ID (its team, not just anyone's) and notarized, and the app must
# be the version asked for; from then on it is pinned to that exact build. The app is staged
# outside /Applications and moved in whole (copied, if the home folder is on another volume: a
# copy that fails partway, or doesn't pass the check after it, is taken back out): copying a
# signed bundle straight into /Applications can stop halfway and leave a broken seal.
#
# Everything is in main, called on the last line (in braces): under `curl | sh` a download cut
# short anywhere runs nothing at all, not half the script.
set -eu
# Exported shell functions (bash, as /bin/sh, imports them even in POSIX mode) would stand in for the
# commands this script runs: none from the caller. unset is a special builtin, found before any
# function in POSIX mode, so the two the clearing itself uses go first. (Run as `| sh`, as the README
# says: plain bash, `| bash`, lets a function shadow even unset.)
unset -f command compgen 2>/dev/null || :
case "${BASH_VERSION:-}" in
    ?*)
        set -f
        for f in $(command compgen -A function); do
            # One bash can't clear (named [, say) stops it, saying why.
            unset -f "$f" 2>/dev/null || {
                printf 'error: your environment exports a shell function named %s; run this from a shell without it\n' "$f" >&2
                exit 1
            }
        done
        set +f
        ;;
esac
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# cd looks a relative folder up through CDPATH (printing where it went), grep still honours
# GREP_OPTIONS (-q or -o would pass a folder a group can change), and perl loads what PERL5OPT and
# PERL5LIB name: none from the caller here.
unset CDPATH GREP_OPTIONS GREP_COLOR GREP_COLORS PERL5OPT PERL5LIB PERLLIB PERL5DB

repo=webteractive/systat
app=systat
dest="/Applications/$app.app"
# Who signs systat: a release signed by any other developer is refused, as the updater does.
team=2VJCCC449X
developer_id='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
signed_by_us="$developer_id and certificate leaf[subject.OU] = \"$team\" and notarized"
is_systat="identifier \"dev.inggo.systat\" and $signed_by_us"
# https only, redirects included: the signature checks would catch a swapped download anyway.
https="--proto =https --proto-redir =https"
# Given up on as the updater gives up: the release answer after 15 s with nothing coming, a download
# after 30 s, and either after 5 minutes in all.
release_patience="--connect-timeout 15 --speed-limit 1 --speed-time 15 --max-time 300"
download_patience="--connect-timeout 30 --speed-limit 1 --speed-time 30 --max-time 300"

# quit_note: said with any error once systat has been quit from a place other than $dest, a copy
# this install doesn't reopen.
quit_note=
# " also" when the copy at $dest ran as well as one elsewhere, for the messages that say so.
also=
# Whether systat has been asked to quit yet, in this run.
quit_sent=no
# The latest release's version, when no version was asked for: then none older than a systat this user
# has, in place, elsewhere in the home folder or running, is installed.
latest=
die() { printf 'error: %s%s\n' "$*" "$quit_note" >&2; exit 1; }

# X.Y.Z, digits only, at most 6 to a part, as the updater reads one: the version becomes part of a
# path and a URL.
is_version() {
    case "$1" in
        *[!0-9.]* | .* | *. | *..* | *.*.*.* | *[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) return 1 ;;
        *.*.*) return 0 ;;
        *) return 1 ;;
    esac
}

# Whether version $1 is older than version $2, both X.Y.Z.
older() {
    a=$1 b=$2
    for n in 1 2 3; do
        x=${a%%.*} y=${b%%.*}
        [ "$x" -lt "$y" ] && return 0
        [ "$x" -gt "$y" ] && return 1
        a=${a#*.} b=${b#*.}
    done
    return 1
}

# A note as one line of plain text, as the app shows it: C0 and C1 controls out (a terminal may act on
# either), and every format character (Unicode's Cf: they reverse how the line reads, or hide) and
# U+FFFD; a tab, line break or line or paragraph separator becomes a space, and what isn't UTF-8 is
# left out.
plain() {
    # UTF-8 first, so removing a control can't join the halves of a broken character: a line break
    # added so iconv never sees a cut-off tail (which would cost what follows), then what it lets
    # through though it isn't Unicode (past U+10FFFF, five- and six-byte forms).
    text=$({ cat; printf '\n'; } | iconv -c -f UTF-8 -t UTF-8 2>/dev/null \
        | LC_ALL=C sed "$(printf 's/\364[\220-\277][\200-\277]*//g;s/[\365-\377][\200-\277]*//g')" \
        | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | LC_ALL=C tr '\011\012\015' '   ' || true)
    # As UTF-8 bytes: C1 (U+0080-U+009F) and the Cf characters, U+00AD, U+0600-U+0605, U+061C,
    # U+06DD, U+070F, U+0890-U+0891, U+08E2, U+180E, U+200B-U+200F, U+202A-U+202E, U+2060-U+206F,
    # U+FEFF, U+FFF9-U+FFFB, U+110BD, U+110CD, U+13430-U+1343F, U+1BCA0-U+1BCA3, U+1D173-U+1D17A and
    # U+E0000-U+E007F; then U+2028-U+2029 become spaces.
    script=$(printf '%s' \
        's/\302[\200-\237\255]//g;s/\330[\200-\205\234]//g;s/\333\235//g;s/\334\217//g;' \
        's/\340\242[\220\221]//g;s/\340\243\242//g;s/\341\240\216//g;' \
        's/\342\200[\213-\217\252-\256]//g;s/\342\201[\240-\257]//g;s/\357\273\277//g;s/\357\277[\271-\273]//g;' \
        's/\360\221\202\275//g;s/\360\221\203\215//g;s/\360\223\220[\260-\277]//g;' \
        's/\360\233\262[\240-\243]//g;s/\360\235\205[\263-\272]//g;s/\363\240[\200\201][\200-\277]//g;' \
        's/\357\277\275//g;s/\342\200[\250\251]/ /g')
    # Then trimmed of spaces (Unicode's Zs) at both ends, as the app trims it.
    zs=$(printf '( |\302\240|\341\232\200|\342\200[\200-\212\257]|\342\201\237|\343\200\200)')
    printf '%s' "$text" | LC_ALL=C sed "$(printf "$script")" | LC_ALL=C sed -E "s/^$zs+//;s/$zs+\$//"
}

# Whether the copy at $dest is a working systat. codesign doesn't look at permissions: an executable
# that only lost its execute bits still verifies, and so does one the updater disabled (mode 0)
# once the checks before the quit have made it readable, so it must be runnable too.
works() {
    [ -x "$dest/Contents/MacOS/$app" ] && codesign --verify --deep --strict -R="$is_systat" "$dest" 2>/dev/null
}

# Ctrl-C, Ctrl-\, a closed terminal or TERM: each ends the script (and EXIT cleans up), or, while
# stopping halfway would leave things broken, does nothing. A broken pipe is ignored throughout: a
# write then fails instead, which ends the script through its EXIT trap (or, where it is ignored with
# || true, doesn't).
allow_interruptions() {
    trap 'exit 130' INT
    trap 'exit 131' QUIT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap - TSTP
    trap - TTOU
    trap - TTIN
}
# Ctrl-Z too: held stopped there, it would leave systat quit, or gone, until resumed; so too a
# background job stopped for writing to (or reading from) the terminal. And a broken pipe: with the
# output piped (to tee, say) and its reader gone, a note printed would end the script before it
# opens systat.
ignore_interruptions() { trap '' HUP INT QUIT TERM TSTP PIPE TTOU TTIN; }

# Asks every copy of systat's app (this user's), or the one at $1, to quit: a TERM to each, by process
# ID. systat does nothing on quitting that a TERM skips, and unlike an AppleScript quit, which goes
# through LaunchServices, it can't launch a copy that has just quit, nor wait on one that hangs.
quit_systat() {
    for pid in $(app_pids "${1:-}"); do
        kill -TERM "$pid" 2>/dev/null || true
    done
}

# Once a copy running from elsewhere has been asked to quit: any error from then on says it wasn't reopened.
note_quit_elsewhere() {
    [ "$elsewhere" = yes ] || return 0
    also=" also"
    [ "$was_running" = yes ] || also=
    quit_note="; systat was$also running from somewhere other than $dest, and that copy, if it quit, wasn't reopened"
}

# Quits every running systat of this user's and waits for them, up to 10 s, first stopping (as
# refuse_newer_running does) before each quit if a newer one runs from elsewhere and no version was
# asked for. Notes in was_running whether the copy at $dest ran, and in elsewhere whether one ran
# from another place (only ever set, so a second call adds to the first), and the quit_note an
# error then carries. If one won't quit, it stops, saying $1 (what wasn't done), and the copy at
# $dest, if it was running and did quit, is opened again if it works: another runs on.
quit_and_wait() {
    # Only a quit this call sent is waited for.
    quit_sent=no
    if app_running "$dest"; then was_running=yes; fi
    if running_elsewhere; then elsewhere=yes; fi
    # Asked again every 2 s (quit_systat), in case one ignores the first; each time only once no newer
    # systat runs from elsewhere (one may have opened meanwhile).
    i=0
    while app_running && [ $i -lt 20 ]; do
        # And one opened meanwhile, at $dest or elsewhere, is quit with the rest, so it is noted as one.
        [ $((i % 4)) -eq 0 ] && {
            refuse_newer_running "$1"
            if app_running "$dest"; then was_running=yes; fi
            if running_elsewhere; then elsewhere=yes; fi
            quit_systat || true
            quit_sent=yes
            note_quit_elsewhere
        }
        sleep 0.5
        i=$((i + 1))
    done
    # Noted even when nothing was left to quit (copies that quit by themselves first).
    note_quit_elsewhere
    if app_running; then
        if [ "$was_running" = yes ] && ! app_running "$dest"; then
            if ! works; then
                die "systat is still running (another copy) and did not quit; $1, and the copy at $dest, which did quit, isn't a working copy to reopen"
            fi
            if open "$dest" 2>/dev/null; then
                die "systat is still running (another copy) and did not quit; $1, and $dest was opened again"
            fi
            die "systat is still running (another copy) and did not quit; $1, and the copy at $dest, which did quit, couldn't be opened again, so open it yourself"
        fi
        die "systat is still running and did not quit; $1"
    fi
}

# Stops unless this user can replace the copy at $dest (its folder writable, nothing in it another
# user's or locked, and macOS's App Management not in the way), saying $1 if the folder can't be
# written. Checked before systat is quit: one this user can't replace would leave it quit for nothing.
replaceable_or_die() {
    [ -w "$(dirname "$dest")" ] || die "you can't change $(dirname "$dest"); $1"
    [ -e "$dest" ] || [ -L "$dest" ] || return 0
    # Opened up first, as far as it is this user's: a folder closed to it would hide what's inside from
    # find (one it still can't read stops the install), and fail the probe below. u+rwX, not u+rwx:
    # nothing becomes runnable that wasn't, so an executable the updater disabled (mode 0) stays
    # unrunnable if the install stops.
    chmod -R -P u+rwX "$dest" 2>/dev/null || true
    others=$(find "$dest" ! -user "$me" -print -quit 2>/dev/null) \
        || die "couldn't look through $dest; systat wasn't quit, and nothing was installed"
    [ -z "$others" ] \
        || die "$dest, or something in it, belongs to another user; delete it first (sudo rm -rf \"$dest\"), then run this again"
    # rm would empty a locked app and then fail on the lock.
    locked=$(find "$dest" \( -flags +uchg -o -flags +schg -o -flags +uappnd -o -flags +sappnd \) -print -quit 2>/dev/null) \
        || die "couldn't look through $dest; systat wasn't quit, and nothing was installed"
    [ -z "$locked" ] || die "$dest, or something in it, is locked (Get Info > Locked, or a flag set with chflags); clear its flags (chflags -R nouchg,nouappnd \"$dest\", and sudo chflags -R noschg,nosappnd \"$dest\" for the system ones), then run this again"
    # macOS's App Management can stop a terminal from changing another app: found out here, before
    # systat is quit, not when the old copy won't go.
    can_replace_app "$dest" \
        || die "couldn't change $dest; if macOS blocked it, allow your terminal in System Settings > Privacy & Security > App Management, then run this again"
}

# Stops if $1, the latest release, is older than the systat in place: the latest can be set back, and
# would quietly downgrade it (only when no version was asked for; the same version reinstalls it).
# Any systat in place counts, even one an update disabled: opened up first (u+rwX: readable, nothing
# made runnable), as the checks before the quit do, so neither a closed folder nor a mode-0
# executable hides its version or its signature. And a second try, as a check that fails for some
# passing reason mustn't let an older build in.
refuse_downgrade() {
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
        chmod -R -P u+rwX "$dest" 2>/dev/null || true
    fi
    installed=$(plutil -extract CFBundleShortVersionString raw -o - "$dest/Contents/Info.plist" 2>/dev/null) || installed=
    if is_version "$installed" && older "$1" "$installed" && verifies_as_systat "$dest"; then
        die "systat $installed is installed, newer than the latest release ($1); to install $1 anyway, give it as the version (| sh -s -- $1, or ./install.sh $1)"
    fi
    # Nor older than a copy anywhere else in this user's home folder (~/Applications, say), running or
    # not, as Spotlight knows them: installing the latest beside it would put the older one first.
    # (Running copies elsewhere are refuse_newer_running's, looked at again as they are quit.)
    # NUL-separated, as a name (another user's, in ~/Public/Drop Box) may hold a line break that would
    # slip in a second path: read one per line, with a path that held one marked (\001) and skipped.
    copies=$(mdfind -0 -onlyin "$HOME" "kMDItemCFBundleIdentifier == 'dev.inggo.systat'" 2>/dev/null \
        | LC_ALL=C tr '\n\000' '\001\n') || copies=
    # Spotlight names the real path; HOME may go through a link, or end in a slash.
    home=$(cd -P "$HOME" 2>/dev/null && pwd -P) || home=$HOME
    trash="$home/.Trash"
    marked=$(printf '\001')
    while IFS= read -r copy; do
        # By its name first, before anything on disk is looked at: whole paths in the home folder
        # only (none that held a line break, none relative), and not one in the Trash, which would
        # never be opened, nor the updater's or this installer's own work copies (a run a crash
        # left, say), which aren't copies of the user's.
        [ -n "$copy" ] && [ "$copy" != "$dest" ] || continue
        case "$copy" in *"$marked"*) continue ;; "$home"/*) ;; *) continue ;; esac
        case "$copy" in
            "$trash"/*) continue ;;
            # Anyone can add to it: never a copy of the user's, and passed over without a look.
            "$home/Public/Drop Box"/*) continue ;;
            */systat-update/* | */.systat-update/* | */systat-install/*) continue ;;
        esac
        # Then a real folder, and a bundle (its Contents there, even if an update closed it), before
        # anything in it is opened up or walked.
        [ -d "$copy" ] && [ ! -L "$copy" ] || continue
        [ -d "$copy/Contents" ] && [ ! -L "$copy/Contents" ] || continue
        # Its own real path, with no link anywhere in it: one another user could swap between the
        # checks below and the reading would let each step see something else. (Spotlight names
        # real paths.)
        real=$(cd -P "$copy" 2>/dev/null && pwd -P) || continue
        [ "$real" = "$copy" ] || continue
        # Only a copy wholly this user's: one in a folder another user can add to (~/Public/Drop Box)
        # could be anything.
        wholly_mine "$copy" || continue
        its=$(plutil -extract CFBundleShortVersionString raw -o - "$copy/Contents/Info.plist" 2>/dev/null) || continue
        if is_version "$its" && older "$1" "$its" && verifies_as_systat "$copy"; then
            die "systat $its is at $(printf '%s' "$copy" | plain), newer than the latest release ($1); to install $1 anyway, give it as the version (| sh -s -- $1, or ./install.sh $1)"
        fi
    done <<EOF
$copies
EOF
}

# With no version asked for, stops (saying $1) if a newer systat runs from elsewhere: it would be
# quit, and the older latest opened in its place. Looked at before the download, and again before
# each quit, as one may open meanwhile; then the copy at $dest may be quit already, and is opened again.
refuse_newer_running() {
    [ -n "${latest:-}" ] || return 0
    newer=$(newer_running "$latest") || return 0
    refused="systat $newer is running from somewhere other than $dest, newer than the latest release ($latest); $1; to install $latest anyway, give it as the version (| sh -s -- $latest, or ./install.sh $latest)"
    # The copy at $dest, asked to quit already, is given a moment to go (up to 5 s), so it isn't left
    # closed with nothing said once it does.
    if [ "${was_running:-no}" = yes ] && [ "${quit_sent:-no}" = yes ]; then
        waited=0
        while app_running "$dest" && [ $waited -lt 10 ]; do
            sleep 0.5
            waited=$((waited + 1))
        done
    fi
    if [ "${was_running:-no}" = yes ] && ! app_running "$dest"; then
        works || die "$refused; systat was quit, and $dest isn't a working copy to reopen"
        open "$dest" 2>/dev/null || die "$refused; systat was quit and couldn't be reopened from $dest, so open it yourself"
        die "$refused; $dest was opened again"
    fi
    if [ "${was_running:-no}" = yes ] && [ "${quit_sent:-no}" = yes ]; then
        die "$refused; $dest was asked to quit and hasn't yet; if it closes, open it again"
    fi
    die "$refused"
}

# This user's home folder, from their account (as the app, started from the Dock or at login, reads
# it), not HOME, which may point elsewhere: installer and updater would then look for each other's
# locks, and Spotlight for copies, in different places.
account_home() {
    # Not CFFIXED_USER_HOME either, which Foundation would take first: systat started from the Dock
    # or at login never has it, so following one a shell exports would split them again.
    home=$(perl -e 'print((getpwuid($<))[7])' 2>/dev/null) || return 1
    case "$home" in /*) printf '%s\n' "$home" ;; *) return 1 ;; esac
}

# Whether the bundle at $1 is wholly this user's: it and every folder above it changeable by no one
# else (only_trusted_can_change), and nothing in it another user's. One that isn't could be anything,
# an executable that would hang codesign included, and has no version worth going by. Opened up
# (u+rwX: readable, nothing made runnable) as the copy in place is, so one an update disabled counts.
wholly_mine() {
    only_trusted_can_change "$1" || return 1
    chmod -R -P u+rwX "$1" 2>/dev/null || true
    others=$(find "$1" ! -user "$me" -print -quit 2>/dev/null) || return 1
    [ -z "$others" ]
}

# Whether $1 is systat signed by its developer, with a second try: a check that fails for some passing
# reason mustn't let an older build in.
verifies_as_systat() {
    codesign --verify --deep --strict -R="$is_systat" "$1" 2>/dev/null \
        || { sleep 1; codesign --verify --deep --strict -R="$is_systat" "$1" 2>/dev/null; }
}

# The version of a systat running from somewhere other than $dest that is newer than $1, if one is and
# verifies as systat (as refuse_downgrade checks the copy in place): quitting it for an older latest
# would downgrade it as surely as replacing it. One whose bundle can't be read, or isn't wholly this
# user's, has no version to go by.
newer_running() {
    for pid in $(app_pids); do
        cmd=$(app_command "$pid") || continue
        bundle=${cmd%/Contents/MacOS/$app}
        [ "$bundle" != "$cmd" ] || continue
        # Resolved once, and only that path used from here: a link in it (one another user could
        # swap) would let each step see something else. Every folder above it then passes
        # wholly_mine, so nothing on it can change.
        bundle=$(cd -P "$bundle" 2>/dev/null && pwd -P) || continue
        # The copy at $dest is refuse_downgrade's, however its path is written.
        [ "$bundle" != "$dest" ] && [ "$bundle" != "$(cd -P "$dest" 2>/dev/null && pwd -P)" ] || continue
        wholly_mine "$bundle" || continue
        its=$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist" 2>/dev/null) || continue
        if is_version "$its" && older "$1" "$its" && verifies_as_systat "$bundle"; then
            echo "$its"
            return 0
        fi
    done
    return 1
}

# Downloads $1 to $2, at most $3 bytes, with the limits in $4, or stops saying why: $5 if it isn't
# there, otherwise naming it as $6. The release isn't blamed for the network or GitHub, nor the
# network for the release. By the HTTP status first: with redirects, curl can report a 404 as a
# failed read.
fetch() {
    status=0
    # -q first: no ~/.curlrc setting (insecure, a proxy, another output) applies.
    code=$(curl -q $https $4 --max-filesize "$3" -fsSL -w '%{http_code}' -o "$2" "$1" 2>/dev/null) || status=$?
    [ "$status" -eq 0 ] && return 0
    case $code in
        404) die "$5" ;;
        403 | 429) die "GitHub refused $6 (HTTP $code, its rate limit most likely); try again later" ;;
        [45][0-9][0-9]) die "GitHub answered HTTP $code for $6; try again later" ;;
    esac
    case $status in
        63) die "$6 is far too large" ;;
        28) die "downloading $6 timed out; check the network, then run this again" ;;
        *) die "couldn't download $6 (curl error $status); check the network, then run this again" ;;
    esac
}

# Takes the installer's own lock ($1): a flock on fd 9 (or, with an older lockf, held by a perl
# process of its own), held for as long as this script runs and let go when it ends, however it ends, as the updater's is (which looks for it the same way). 0 if taken,
# 1 if another install holds it, 2 if it can't be opened.
take_install_lock() {
    [ ! -L "$1" ] || return 2
    # Private, this user's: another user who could open it could hold it, and stop every install and
    # update. In a subshell: in some shells (dash) a failed redirection would end the script itself.
    ( umask 077; : >> "$1" ) 2>/dev/null || return 2
    # No ACL either: one could let another user open it, and holding it needs no more.
    [ -O "$1" ] && chmod 600 "$1" 2>/dev/null && chmod -N "$1" 2>/dev/null || return 2
    exec 9>>"$1"
    # Up to a second: the updater probing it holds it for a moment.
    status=0
    lockf -s -t 1 9 2>/dev/null || status=$?
    case $status in
        0) return 0 ;;
        75) return 1 ;;
        64) ;;
        *) return 2 ;;
    esac
    # A lockf older than macOS 26.4 has no descriptor form (a usage error, 64): a process of this
    # script's own holds the lock instead, for as long as the script runs. Perl's, not lockf's: lockf
    # resets TERM. It ignores every signal the script ignores in its critical part, in a process group
    # of its own, and says once it holds the lock.
    exec 9>&-
    # This run's own: another run starting at the same moment has its own, and its holder's word is
    # never taken for this one's.
    held="$1.held.$$"
    for n in 1 2; do
        rm -f "$held"
        # Up to a second for the lock, as lockf's -t 1; then held while this script is its parent (not
        # while a process ID lives, which another process could reuse).
        perl -MFcntl=:flock -e '
            setpgrp(0, 0);
            $SIG{$_} = "IGNORE" for qw(HUP INT QUIT TERM TSTP PIPE TTOU TTIN);
            open(my $lock, ">>", $ARGV[0]) or exit 2;
            my $tries = 0;
            until (flock($lock, LOCK_EX | LOCK_NB)) {
                exit 75 if ++$tries > 10;
                select(undef, undef, undef, 0.1);
            }
            open(my $said, ">", $ARGV[2]) or exit 2;
            print $said "held\n";
            close($said);
            select(undef, undef, undef, 0.5) while getppid() == $ARGV[1];
            unlink($ARGV[2]);
        ' "$1" "$$" "$held" </dev/null >/dev/null 2>&1 &
        holder=$!
        i=0
        while [ $i -lt 50 ]; do
            if [ -s "$held" ]; then
                rm -f "$held"
                return 0
            fi
            kill -0 "$holder" 2>/dev/null || break
            sleep 0.1
            i=$((i + 1))
        done
        # Still running without saying it holds the lock: something is wrong with it.
        if kill -0 "$holder" 2>/dev/null; then
            kill "$holder" 2>/dev/null || true
            kill -9 "$holder" 2>/dev/null || true
            return 2
        fi
        status=0
        wait "$holder" 2>/dev/null || status=$?
        [ "$status" -eq 75 ] || return 2
        sleep 0.3
    done
    return 1
}

# Whether systat is updating itself: its lock ($1), a flock held while an update is under way,
# can't be taken. lockf takes the same kind of lock, and keeps the file (-k). 0 if it is, 1 if not
# (or there's no lock), 2 if the lock can't be opened to tell.
updater_busy() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    # Held a moment later still: the updater probing the installer's lock holds its own meanwhile.
    for n in 1 2; do
        status=0
        lockf -k -s -t 0 "$1" true 2>/dev/null || status=$?
        case $status in
            0) return 1 ;;
            75) [ "$n" -eq 2 ] && return 0; sleep 0.2 ;;
            *) return 2 ;;
        esac
    done
}

# Whether systat's app is running for this user ($me), from any copy, or from exactly the one at $1
# (see app_pids). Compared as written, not as a pattern: a copy at ~/Applications/systat.app isn't the
# one at /Applications/systat.app.
app_running() {
    [ -n "$(app_pids "${1:-}")" ]
}

# The process IDs of systat's app running for this user ($me), from any copy, or from exactly the one at
# $1. The app is a process started by systat's executable (argv[0], ps's comm, made absolute by
# app_command: …/Contents/MacOS/systat) in a bundle whose identifier is systat's (or none left there),
# with none of systat's command-line modes among its arguments (is_cli_mode, as main.swift reads
# them): not systat --bench, say, nor something else given systat's path (a debugger: its argv[0] is
# its own), nor another app whose executable happens to be called systat. (A process ID that ends and
# is reused between this and a TERM could only be another of this user's.)
app_pids() {
    # Any command whose first word may be systat (./systat, from inside the bundle, or a bare systat
    # through a link), and any process whose executable is a systat one (started through a link with
    # another name): narrowed below.
    for pid in $( { pgrep -U "$me" -f 'systat( |$)' 2>/dev/null || :
                    lsof -b -a -u "$me" -d txt -Fpn 2>/dev/null \
                        | awk '/^p/ { p = substr($0, 2) } /^n.*\/Contents\/MacOS\/systat$/ { print p }' || :
                  } | sort -u ); do
        raw=$(ps -o command= -p "$pid" 2>/dev/null) || continue
        argv0=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
        # The app: argv[0] first, and after it no command-line mode (macOS's own arguments may follow).
        case "$raw" in "$argv0" | "$argv0 "*) ;; *) continue ;; esac
        is_cli_mode "${raw#"$argv0"}" && continue
        cmd=$(app_command "$pid") || continue
        case "$cmd" in */Contents/MacOS/systat) ;; *) continue ;; esac
        # Its bundle's identifier, if there is one to read: a systat whose bundle was moved, trashed or
        # half removed while it ran has no Info.plist at that path, and still counts.
        contents=${cmd%/MacOS/systat}
        if [ -e "$contents/Info.plist" ] || [ -L "$contents/Info.plist" ]; then
            [ "$(plutil -extract CFBundleIdentifier raw -o - "$contents/Info.plist" 2>/dev/null)" = dev.inggo.systat ] \
                || continue
        fi
        if [ -z "${1:-}" ] || [ "$cmd" = "$1/Contents/MacOS/systat" ]; then
            echo "$pid"
        fi
    done
}

# Whether the arguments $1 (as ps shows them after argv[0], joined by spaces: an argument holding a
# space reads as two) start one of systat's command-line modes, as main.swift reads them; with any
# others (macOS's own, say) it runs the app.
is_cli_mode() {
    set -f
    # shellcheck disable=SC2086 # split into words, never globbed
    set -- $1
    set +f
    case "${1:-}" in --version | -v | version) return 0 ;; esac
    for arg do
        case "$arg" in --help | -h | --check-update | --update | --sample | --bench | --iconset | --snapshot) return 0 ;; esac
    done
    return 1
}

# The path process $1 was started by (its argv[0]), made absolute: one started by a relative path
# (from a terminal) is resolved against that process's own working folder, not this script's, where
# anyone may have put a bundle at the same relative path; one started through a link (by a bare name
# on PATH, or a link's path) is the executable it runs.
app_command() {
    cmd=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
    case "$cmd" in
        /*) ;;
        */*)
            # -b: never blocking on a network volume that stopped answering.
            cwd=$(lsof -b -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p') || return 1
            case "$cwd" in /*) ;; *) return 1 ;; esac
            # Written plainly (no ./ or ../), as the copy at $dest is named: its folder, as cd -P
            # finds it from there, and its name; joined as written if that folder is gone (a bundle
            # moved or trashed while it ran, which still counts).
            if dir=$(cd "$cwd" 2>/dev/null && cd -P "$(dirname "$cmd")" 2>/dev/null && pwd -P); then
                cmd="${dir%/}/${cmd##*/}"
            else
                cmd="${cwd%/}/${cmd#./}"
            fi
            ;;
        *) cmd= ;;
    esac
    # Not systat's executable by that path (started through a link to it, by its path or by a bare
    # name on PATH): the executable it runs.
    case "$cmd" in
        */Contents/MacOS/systat) ;;
        *)
            cmd=$(lsof -b -a -p "$1" -d txt -Fn 2>/dev/null | sed -n '/^n/{s/^n//p;q;}') || return 1
            case "$cmd" in /*) ;; *) return 1 ;; esac
            ;;
    esac
    printf '%s\n' "$cmd"
}

# Whether systat's app runs from somewhere other than $dest (a process that ends meanwhile isn't one).
running_elsewhere() {
    for pid in $(app_pids); do
        cmd=$(app_command "$pid") || continue
        [ -n "$cmd" ] || continue
        [ "$cmd" = "$dest/Contents/MacOS/$app" ] || return 0
    done
    return 1
}

# Whether the volume holding $1 keeps ownership, as FolderTrust requires: on a drive set to ignore it
# every folder reports this user as its owner. Asked of the kernel (df names the mount) and of the
# system (diskutil), never read from mount's text, where a mount point can hold a line break and
# forge a line. A network share isn't a disk diskutil knows, so it fails too.
volume_trusted() {
    point=$(LC_ALL=C df -P "$1" 2>/dev/null | sed -n '2s/^[^%]*% *//p') || return 1
    [ -n "$point" ] || return 1
    info=$(diskutil info -plist "$point" 2>/dev/null) || return 1
    [ "$(printf '%s' "$info" | plutil -extract GlobalPermissionsEnabled raw -o - - 2>/dev/null)" = true ] || return 1
    # Nor a disk image: one is all another user can attach (at a folder of theirs), and its files hold
    # whatever owners they gave them, this user's included. (The updater asks who mounted it.)
    [ "$(printf '%s' "$info" | plutil -extract BusProtocol raw -o - - 2>/dev/null)" != "Disk Image" ]
}

# $2 narrowed to the very build at $1: the code directory hash of each of its architectures (which
# covers its Info.plist, and so its version). Fails if they can't be read.
pin_build() {
    archs=$(codesign -d -vvv "$1" 2>&1 | sed -n 's/^Format=.*Mach-O [a-z]* (\(.*\))$/\1/p')
    hashes=
    for arch in $archs; do
        case "$arch" in *[!a-z0-9_]*) return 1 ;; esac
        cdhash=$(codesign -d -vvv --arch "$arch" "$1" 2>&1 | sed -n 's/^CDHash=//p')
        case "$cdhash" in "" | *[!0-9a-f]*) return 1 ;; esac
        hashes="$hashes${hashes:+ or }cdhash H\"$cdhash\""
    done
    [ -n "$hashes" ] || return 1
    printf '%s and (%s)\n' "$2" "$hashes"
}

# Whether this terminal may change the app at $1 (macOS's App Management can stop it changing another
# app): a folder made and removed inside it, never cut short in between, as one left behind would
# break the app's seal. An app with no Contents can't be checked, and passes.
can_replace_app() {
    [ -d "$1/Contents" ] || return 0
    probe="$1/Contents/.systat-install-probe"
    rmdir "$probe" 2>/dev/null || true
    ignore_interruptions
    probed=no
    { mkdir "$probe" && rmdir "$probe"; } 2>/dev/null && probed=yes
    allow_interruptions
    [ "$probed" = yes ]
}

# Whether the copy at $1 is the build checked. A check that fails for some passing reason (codesign
# killed when memory is short, say) gets a second try a second later, as the relaunch helper's
# does: failing the staged copy's check after the quit installs nothing, and failing the check after
# the move takes the copy out of the way when the old one is already gone.
is_the_build_checked() {
    codesign --verify --deep --strict -R="$this_build" "$1" 2>/dev/null \
        || { sleep 1; codesign --verify --deep --strict -R="$this_build" "$1" 2>/dev/null; }
}
is_this_build() { is_the_build_checked "$dest"; }

# Takes what is at $dest out of the way when it isn't the build checked, so it can't start from the
# Dock or at login: into the work folder, or, if it can't be moved, with nothing in it executable
# (whatever its executable is called; no link followed). Says which, or fails.
reject_dest() {
    if [ ! -e "$work/rejected.app" ] && mv "$dest" "$work/rejected.app" 2>/dev/null; then
        rejected="was moved to $work/rejected.app"
        return 0
    fi
    if [ -d "$dest" ] && [ ! -L "$dest" ] \
        && find "$dest" -type f -perm +111 -exec chmod a-x {} + 2>/dev/null \
        && [ -z "$(find "$dest" -type f -perm +111 -print 2>/dev/null)" ]; then
        rejected="was disabled"
        return 0
    fi
    return 1
}

# Whether only this user can change $1 and every folder above it (root, or the admin group for a
# system folder like /Applications, aside), by permissions or ACL: the rule the updater applies to
# its own folders (FolderTrust). Anyone else could swap the work folder, or plant in it, and an
# inherited ACL that lets them write would pass on to every file of the new copy, which codesign
# doesn't look at. Deny entries take nothing away; an allow entry naming only this user gives
# nobody else anything.
only_trusted_can_change() {
    path=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
    me=$(id -u)
    myname=$(id -un)
    while :; do
        [ -d "$path" ] && [ ! -L "$path" ] || return 1
        owner=$(stat -f %u "$path") && group=$(stat -f %g "$path") && mode=$(stat -f %Lp "$path") || return 1
        case $owner in
            "$me") [ $((0$mode & 022)) -eq 0 ] || return 1 ;;
            0) [ $((0$mode & 002)) -eq 0 ] || return 1
                [ $((0$mode & 020)) -eq 0 ] || [ "$group" -eq 0 ] || [ "$group" -eq 80 ] || return 1 ;;
            *) return 1 ;;
        esac
        # The volume after the owner and mode, which refuse most folders that fail far more cheaply
        # (diskutil takes a fifth of a second; another user can plant thousands to be looked at).
        volume_trusted "$path" || return 1
        # An ACL that can't be read can't be vouched for: anything ls says on stderr fails it.
        acl=$(LC_ALL=C ls -led "$path" 2>&1) || return 1
        case $acl in *"ls: "*) return 1 ;; esac
        # Read to the end (no grep -q quitting early), so a caller's pipefail can't turn a match into
        # a failed pipeline, read as no match.
        changers=$(printf '%s\n' "$acl" | sed 1d | grep ' allow ' | grep -vF ": user:$myname " \
            | grep -E 'add_file|add_subdirectory|delete_child|delete|writesecurity|chown' || true)
        [ -z "$changers" ] || return 1
        [ "$path" = / ] && return 0
        path=$(dirname "$path")
    done
}

# Removes a work folder, ejecting an image an earlier run left mounted in it first.
clear_out() {
    # Only if it really is a mount point, judged as itself (no link followed, so no other volume is
    # ever ejected): a folder on a device of its own, not its parent's.
    if [ -d "$1/mount" ] && [ ! -L "$1/mount" ] && [ ! -L "$1" ] \
        && [ "$(stat -f %d "$1/mount" 2>/dev/null)" != "$(stat -f %d "$1" 2>/dev/null)" ]; then
        hdiutil detach -quiet "$1/mount" 2>/dev/null || hdiutil detach -quiet -force "$1/mount" 2>/dev/null || true
    fi
    rm -rf "$1" 2>/dev/null || true
}

main() {
    [ "$(uname -s)" = Darwin ] || die "systat is a macOS app"
    # The Mac's, not this terminal's: uname says x86_64 under Rosetta, on Apple silicon too.
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || die "systat needs a Mac with Apple silicon"
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 26 ] || die "systat needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))"
    # As root the app would end up owned by root, and could never update itself.
    [ "$(id -u)" -ne 0 ] || die "run the installer as yourself, without sudo"
    HOME=$(account_home) || die "couldn't find your home folder"
    export HOME
    # This user: only their own copies of systat are looked at or quit.
    me=$(id -u)

    if [ $# -gt 0 ]; then
        version=${1#v}
        is_version "$version" || die "not a version: $version"
    fi

    # Not in Caches, as the updater's isn't: a cleaner app empties that, and from removing the old copy
    # until the move, the new one here is the only one. In a folder only this user can change.
    support="$HOME/Library/Application Support"
    mkdir -p "$support" || die "couldn't make $support"
    volume_trusted "$support" \
        || die "$support is on a network share, a drive that ignores ownership, a disk image, or a volume macOS can't vouch for, where its files' owners can't be trusted; the installer works only on this Mac's own disks"
    only_trusted_can_change "$support" \
        || die "someone else can change $support or a folder above it (by permissions or ACL), as the updater won't accept either; make them yours alone, then run this again"
    # One install at a time: another would clear this one's work folder.
    lock="$support/systat-install.lock"
    [ -w "$support" ] || die "you can't write to $support; make it yours, then run this again"
    if take_install_lock "$lock"; then
        :
    elif [ $? -eq 1 ]; then
        die "another systat install is running; wait for it, then run this again"
    else
        die "couldn't open the lock $lock; make it yours (or remove it), then run this again"
    fi
    work="$support/systat-install"
    mount="$work/mount"
    cleanup() { clear_out "$work"; }
    # Ctrl-C (or Ctrl-\) ends the script, and EXIT cleans up: a trap that cleaned up and returned
    # would let the script carry on without its work folder.
    trap cleanup EXIT
    allow_interruptions
    trap '' PIPE
    # Not while systat updates itself: each would take the other's copy for one it can replace. Looked
    # for only once this installer holds its own lock, as the updater takes its own before looking for
    # this one: then at least one of two starting together sees the other. 0.1.1's lock, in Caches, too.
    for ulock in "$support/systat-update/lock" "$HOME/Library/Caches/systat-update/lock"; do
        if updater_busy "$ulock"; then
            die "systat is updating itself right now; wait for it to finish, then run this again"
        elif [ $? -eq 2 ]; then
            die "couldn't open systat's update lock $ulock to see whether an update is under way; make it yours (or remove it), then run this again"
        fi
    done
    # What an earlier run left, an image still mounted in it included, here or where earlier
    # installers worked.
    cleanup
    clear_out "$HOME/Library/Caches/systat-install"
    [ ! -e "$work" ] || die "couldn't clear out $work; eject or remove what's in it, then run this again"
    mkdir -m 700 "$work" || die "couldn't make $work"
    # Nothing in it inherits an ACL: one would pass on to every file of the new copy.
    chmod -N "$work" || die "couldn't clear the ACL of $work"

    if [ $# -eq 0 ]; then
        fetch "https://api.github.com/repos/$repo/releases/latest" "$work/release.json" 1048576 "$release_patience" \
            "GitHub has no release of $repo" "the latest release of $repo"
        # plutil's errors aren't printed: they quote what it couldn't read.
        version=$(plutil -extract tag_name raw -o - "$work/release.json" 2>/dev/null) \
            || die "the latest release of $repo isn't tagged with a version"
        version=${version#v}
        # Not printed: it comes from the release, and could hold anything a terminal acts on.
        is_version "$version" || die "the latest release of $repo isn't tagged with a version"
        refuse_downgrade "$version"
        latest=$version
        refuse_newer_running "nothing was installed"
    fi

    base="https://github.com/$repo/releases/download/v$version"
    dmg="$work/$app-$version.dmg"
    echo "Downloading systat $version"
    # Capped as the updater caps them: systat's image is about 1 MB.
    fetch "$base/$app-$version.dmg" "$dmg" 209715200 "$download_patience" \
        "there's no release v$version, or it has no $app-$version.dmg" "$app-$version.dmg"
    fetch "$base/$app-$version.dmg.sha256" "$dmg.sha256" 1024 "$download_patience" \
        "release v$version has no $app-$version.dmg.sha256" "$app-$version.dmg.sha256"
    [ "$(shasum -a 256 "$dmg" | awk '{print $1}')" = "$(tr -d '[:space:]' < "$dmg.sha256")" ] \
        || die "the download does not match the release checksum"

    # Mount only a notarized image. </dev/null: under `curl | sh` the script itself is stdin.
    # --check-notarization asks Apple online, as the updater's revocation check does: spctl says yes to
    # everything when Gatekeeper is turned off.
    codesign --verify --check-notarization -R="$signed_by_us" "$dmg" 2>/dev/null \
        || die "the disk image isn't signed and notarized by systat's developer"
    spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null \
        || die "Gatekeeper rejects the disk image (not notarized?)"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg" </dev/null \
        || die "the disk image couldn't be opened"
    # A real folder only: a link named systat.app could point at any app on this Mac.
    if [ -d "$mount/$app.app" ] && [ ! -L "$mount/$app.app" ]; then
        ditto --noacl "$mount/$app.app" "$work/$app.app" || die "couldn't copy $app.app out of the disk image"
    fi
    hdiutil detach -quiet "$mount" || hdiutil detach -quiet -force "$mount" || die "the disk image couldn't be ejected"
    [ -d "$work/$app.app" ] && [ ! -L "$work/$app.app" ] || die "the disk image holds no $app.app"
    # As the updater copies it: the seal doesn't cover permissions, and the updater refuses a copy with
    # a folder others can change.
    chmod -R -P go-w,ug-s "$work/$app.app" || die "couldn't set the permissions of the new copy"
    # And no ACL on anything in it (ditto --noacl copied none, and the work folder passes none on):
    # files and folders only, as chmod -N would follow a link.
    find "$work/$app.app" ! -type l -exec chmod -N {} + || die "couldn't clear the ACLs of the new copy"

    # Pinned first to this very build, by the code directory hash of each architecture (which covers
    # its Info.plist, and so its version), and every check made on that: whatever is in the work folder
    # or in place later must be the copy checked here.
    this_build=$(pin_build "$work/$app.app" "$is_systat") \
        || die "couldn't read the code directory hash of the app in release v$version"
    codesign --verify --deep --strict --check-notarization -R="$this_build" "$work/$app.app" 2>/dev/null \
        || die "the app isn't systat signed and notarized by its developer"
    spctl -a -t exec "$work/$app.app" 2>/dev/null || die "Gatekeeper rejects the app (not notarized?)"
    [ "$(plutil -extract CFBundleShortVersionString raw -o - "$work/$app.app/Contents/Info.plist" 2>/dev/null)" = "$version" ] \
        || die "the app in release v$version is not systat $version"

    # Checked before systat is quit: a copy this user can't replace would leave it quit for nothing.
    replaceable_or_die "ask an administrator to install systat"

    # From quitting systat until the new copy is in place, Ctrl-C, Ctrl-\ or a closed terminal must not stop
    # it halfway (as systat --update ignores them): systat would stay quit, or be gone.
    ignore_interruptions
    # Only this user's copy: another user's systat is theirs to quit.
    was_running=no
    elsewhere=no
    quit_and_wait "nothing was installed"

    # Checked again now that systat is quit, just before the old copy goes: something may have changed,
    # emptied or replaced the staged one meanwhile. If so, systat is left as it was, and opened again
    # if it was running.
    check_staged() {
        if [ ! -d "$work/$app.app" ] || [ -L "$work/$app.app" ] || ! is_the_build_checked "$work/$app.app"; then
            problem="the verified new copy in $work changed, was replaced or is gone, so nothing was installed"
            # Opened again only if it was running, and only if the copy in place works: one the updater
            # disabled must not be started.
            if [ "$was_running" = no ]; then
                if [ -e "$dest" ] || [ -L "$dest" ]; then
                    die "$problem; the copy at $dest was left as it was"
                fi
                die "$problem"
            fi
            if ! works; then
                # It was running, but no longer verifies, or can't start (disabled meanwhile, say).
                die "$problem; systat was quit, and $dest isn't a working copy to reopen, so run the installer again"
            fi
            if open "$dest" 2>/dev/null; then
                die "$problem; systat was opened again from $dest"
            fi
            die "$problem; systat was quit and couldn't be reopened from $dest, so open it yourself"
        fi
    }
    check_staged
    # Opened again meanwhile (by its login item, say): its bundle mustn't go from under it. Quit as
    # before (noting which copy ran, and reopening $dest's if another won't quit), and the staged copy
    # checked again after that wait.
    if app_running; then
        quit_and_wait "nothing was installed"
        check_staged
    fi
    # From here until the new copy is in place, the old one is gone and the new one is only in $work:
    # a failure must not clean $work away. (The lock goes with the script.)
    trap - EXIT
    # Folders opened up first: an earlier build may have closed one, which rm can't empty. u+rwX, not
    # u+rwx: removing a file needs only its folder, and if the removal fails, an executable the updater
    # disabled must stay unrunnable.
    chmod -R -P u+rwX "$dest" 2>/dev/null || true
    rm -rf "$dest" 2>/dev/null || true
    # Still there (macOS refused, say): mv into it would move the app inside it. What's left is
    # described, and opened again if systat was running and it still works.
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        problem="couldn't remove the old copy at $dest (if macOS blocked it, allow your terminal in System Settings > Privacy & Security > App Management); the verified new copy is at $work/$app.app"
        if ! works; then
            if [ "$was_running" = yes ]; then
                die "$problem; what is left at $dest may not work, so systat was quit and wasn't reopened"
            fi
            die "$problem; what is left at $dest may not work"
        fi
        if [ "$was_running" = no ]; then
            die "$problem; the old copy is still in place"
        fi
        if open "$dest" 2>/dev/null; then
            die "$problem; the old copy is still in place and was opened again"
        fi
        die "$problem; the old copy is still in place, but couldn't be opened, so open it yourself"
    fi
    # Across volumes mv copies, then removes the source: a copy that fails partway leaves part of one
    # at $dest, while one whose removal alone failed left the whole build checked there.
    moved=yes
    mv "$work/$app.app" "$dest" || moved=no
    if [ "$moved" = no ] && ! is_this_build; then
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            if reject_dest; then
                die "couldn't put systat in $dest; the copy there (incomplete, most likely) $rejected, and the verified new copy is at $work/$app.app"
            fi
            die "couldn't put systat in $dest, and couldn't take the copy there out of the way; delete it (sudo rm -rf \"$dest\"); the verified new copy is at $work/$app.app"
        fi
        die "couldn't put systat in $dest; the verified new copy is at $work/$app.app"
    fi
    # Whatever is there now that isn't the build checked must not start, from the Dock or at login.
    if ! is_this_build; then
        if reject_dest; then
            die "the copy now at $dest isn't the systat just checked, so it $rejected, not opened; run the installer again"
        fi
        die "the copy now at $dest isn't the systat just checked, and couldn't be taken out of the way; delete it (sudo rm -rf \"$dest\"), then run the installer again"
    fi
    cleanup
    # Any note an earlier update left is about what this install just replaced: a failure is shown once,
    # and every note is cleared (0.1.1's helper also wrote one after an update that worked).
    for note in "$HOME/Library/Application Support/systat-update/result" "$HOME/Library/Caches/systat-update/result"; do
        if [ -f "$note" ] && [ ! -L "$note" ]; then
            problem=$(head -c 4096 "$note" | plain)
            case "$problem" in
                # || true: with the terminal closed (its hang-up is ignored) the write fails, and set -e
                # would stop the install before it opens systat.
                "failed: "*) printf 'The last update had left this note, now dealt with: %s\n' "${problem#failed: }" || true ;;
            esac
            rm -f "$note" 2>/dev/null || true
        fi
    done
    open "$dest" || die "systat is installed at $dest, but couldn't be opened; open it yourself"
    if [ "$elsewhere" = yes ]; then
        echo "systat was$also running from somewhere other than $dest; that copy is no longer running, and the one at $dest opened in its place" || true
    fi
    echo "Installed $("$dest/Contents/MacOS/$app" --version) to $dest" || true
}

# A brace group is read whole before any of it runs: a download cut short anywhere in this line
# (even right after "main", which would drop the version asked for) is a syntax error, and runs nothing.
{ main "$@"; }
