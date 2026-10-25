#!/bin/sh
# Reset sleep before removing the boot reset and the two-command sudoers rule.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset ENV BASH_ENV CDPATH
umask 077

fail() {
    printf 'Clam helper: %s\n' "$*" >&2
    exit 1
}

[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'This uninstaller requires macOS.'
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Run this uninstaller as root (sudo).'
[ "$#" -eq 0 ] || fail 'Usage: uninstall-helper.sh'

sudoers_path=/etc/sudoers.d/clam
daemon_path=/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist
service=system/com.jimbo23.clam.bootreset

# Do not traverse unexpected writable or symlinked installation directories.
for directory in /private/etc /Library /etc/sudoers.d /Library/LaunchDaemons; do
    [ ! -L "$directory" ] || fail "Refusing symlink directory: $directory"
    if [ -e "$directory" ]; then
        [ -d "$directory" ] || fail "Not a directory: $directory"
        directory_info=$(/usr/bin/stat -f '%u:%Lp' "$directory") || fail "Cannot inspect $directory."
        directory_owner=${directory_info%%:*}
        directory_mode=${directory_info#*:}
        [ "$directory_owner" = 0 ] || fail "Directory must be owned by root: $directory"
        [ "$((0$directory_mode & 022))" -eq 0 ] || fail "Directory must not be writable by group or others: $directory"
    fi
done
for destination in "$sudoers_path" "$daemon_path"; do
    [ ! -L "$destination" ] || fail "Refusing symlink destination: $destination"
    if [ -e "$destination" ]; then
        [ -f "$destination" ] || fail "Not a regular file: $destination"
    fi
done

work=$(/usr/bin/mktemp -d /private/tmp/clam-uninstall.XXXXXX) || fail 'Cannot create secure working directory.'
mutated=0
committed=0
old_sudoers=0
old_daemon=0
old_loaded=0

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    rollback_failed=0
    if [ "$mutated" -eq 1 ] && [ "$committed" -eq 0 ]; then
        printf 'Clam helper: uninstall failed; restoring the previous installation.\n' >&2
        if [ "$old_sudoers" -eq 1 ]; then
            /bin/cp -p "$work/previous-sudoers" "$sudoers_path" || rollback_failed=1
        fi
        if [ "$old_daemon" -eq 1 ]; then
            /bin/cp -p "$work/previous-daemon" "$daemon_path" || rollback_failed=1
        fi
        /usr/sbin/visudo -c || rollback_failed=1
        if [ "$old_loaded" -eq 1 ] && [ "$old_daemon" -eq 1 ]; then
            if ! /bin/launchctl print "$service" >/dev/null 2>&1; then
                /bin/launchctl bootstrap system "$daemon_path" || rollback_failed=1
            fi
        fi
    fi
    if [ "$rollback_failed" -ne 0 ]; then
        printf 'Clam helper: rollback incomplete. Root-only recovery files remain at %s; inspect sudoers and %s.\n' "$work" "$daemon_path" >&2
        status=1
    else
        /bin/rm -rf "$work" || status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$sudoers_path" ]; then
    /bin/cp -p "$sudoers_path" "$work/previous-sudoers"
    old_sudoers=1
fi
if [ -f "$daemon_path" ]; then
    /bin/cp -p "$daemon_path" "$work/previous-daemon"
    old_daemon=1
fi
if /bin/launchctl print "$service" >/dev/null 2>&1; then
    old_loaded=1
fi

# Failure to restore sleep must leave the recovery daemon and permission intact.
/usr/bin/pmset -a disablesleep 0 || fail 'Cannot reset disablesleep to 0; helper files have not been removed.'
mutated=1
if [ "$old_loaded" -eq 1 ]; then
    /bin/launchctl bootout "$service" || fail 'Cannot unload the boot-reset job.'
fi
/bin/rm -f "$daemon_path" || fail 'Cannot remove the boot-reset plist.'
/bin/rm -f "$sudoers_path" || fail 'Cannot remove /etc/sudoers.d/clam.'
/usr/sbin/visudo -c || fail 'Full sudoers validation failed after removal.'
committed=1
printf 'Clam helper uninstalled. disablesleep is now 0.\n'
