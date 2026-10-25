#!/bin/sh
# Install only while Clam is off: bootstrapping the daemon immediately resets
# disablesleep to 0. The same fixed command runs at each subsequent boot.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset ENV BASH_ENV CDPATH
umask 077

fail() {
    printf 'Clam helper: %s\n' "$*" >&2
    exit 1
}

[ "$(/usr/bin/uname -s)" = Darwin ] || fail 'This installer requires macOS.'
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Run this installer as root (sudo or administrator authorization).'

case $# in
    0) account=${SUDO_USER-} ;;
    2) [ "$1" = --user ] || fail 'Usage: install-helper.sh [--user USER]'; account=$2 ;;
    *) fail 'Usage: install-helper.sh [--user USER]' ;;
esac
# Restrict the account token to a safe, unambiguous sudoers short name.
case "$account" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_.-]*) fail 'Specify a local nonroot short account name with --user USER (or SUDO_USER).' ;;
esac
local_uid=$(/usr/bin/dscl . -read "/Users/$account" UniqueID) || fail "No local account named $account."
case "$local_uid" in
    'UniqueID: '*) local_uid=${local_uid#UniqueID: } ;;
    *) fail "Cannot determine the local UID for $account." ;;
esac
case "$local_uid" in
    ''|*[!0-9]*) fail "Invalid local UID for $account." ;;
esac
[ "$local_uid" -gt 0 ] || fail 'The root account is not a valid helper recipient.'
resolved_uid=$(/usr/bin/id -u "$account") || fail "Cannot resolve account $account."
[ "$local_uid" = "$resolved_uid" ] || fail 'Local and directory-service account identities differ.'

sudoers_path=/etc/sudoers.d/clam
daemon_path=/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist
service=system/com.jimbo23.clam.bootreset

safe_directory() {
    directory=$1
    [ ! -L "$directory" ] || fail "Refusing symlink directory: $directory"
    [ -d "$directory" ] || fail "Missing directory: $directory"
    directory_info=$(/usr/bin/stat -f '%u:%Lp' "$directory") || fail "Cannot inspect $directory."
    directory_owner=${directory_info%%:*}
    directory_mode=${directory_info#*:}
    [ "$directory_owner" = 0 ] || fail "Directory must be owned by root: $directory"
    [ "$((0$directory_mode & 022))" -eq 0 ] || fail "Directory must not be writable by group or others: $directory"
}

safe_directory /private/etc
safe_directory /Library
if [ ! -e /etc/sudoers.d ] && [ ! -L /etc/sudoers.d ]; then
    /usr/bin/install -d -o root -g wheel -m 0755 /etc/sudoers.d
fi
if [ ! -e /Library/LaunchDaemons ] && [ ! -L /Library/LaunchDaemons ]; then
    /usr/bin/install -d -o root -g wheel -m 0755 /Library/LaunchDaemons
fi
safe_directory /etc/sudoers.d
safe_directory /Library/LaunchDaemons
for destination in "$sudoers_path" "$daemon_path"; do
    [ ! -L "$destination" ] || fail "Refusing symlink destination: $destination"
    if [ -e "$destination" ]; then
        [ -f "$destination" ] || fail "Not a regular file: $destination"
    fi
done

# Use an exclusively created, root-private directory, never a caller's TMPDIR.
work=$(/usr/bin/mktemp -d /private/tmp/clam-helper.XXXXXX) || fail 'Cannot create secure working directory.'
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
        printf 'Clam helper: installation failed; restoring the previous installation.\n' >&2
        if /bin/launchctl print "$service" >/dev/null 2>&1; then
            /bin/launchctl bootout "$service" || rollback_failed=1
        fi
        if [ "$old_sudoers" -eq 1 ]; then
            /bin/cp -p "$work/previous-sudoers" "$sudoers_path" || rollback_failed=1
        else
            /bin/rm -f "$sudoers_path" || rollback_failed=1
        fi
        if [ "$old_daemon" -eq 1 ]; then
            /bin/cp -p "$work/previous-daemon" "$daemon_path" || rollback_failed=1
        else
            /bin/rm -f "$daemon_path" || rollback_failed=1
        fi
        /usr/sbin/visudo -c || rollback_failed=1
        if [ "$old_loaded" -eq 1 ] && [ "$old_daemon" -eq 1 ]; then
            /bin/launchctl bootstrap system "$daemon_path" || rollback_failed=1
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
    [ "$old_daemon" -eq 1 ] || fail 'The boot-reset job is loaded without its expected plist; boot it out before installing.'
fi

# A numeric UID cannot be mistaken for ALL, a User_Alias, or sudoers syntax.
printf '#%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$local_uid" > "$work/sudoers"
# Generate trusted constant content rather than elevating a bundled plist.
# Resources/com.jimbo23.clam.bootreset.plist mirrors this payload; installation
# therefore works from both repository scripts/ and app Contents/Resources/.
/bin/cat > "$work/daemon.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jimbo23.clam.bootreset</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/pmset</string>
        <string>-a</string>
        <string>disablesleep</string>
        <string>0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
/usr/sbin/visudo -c -f "$work/sudoers" || fail 'Candidate sudoers rule is invalid.'
/usr/sbin/visudo -c || fail 'Existing sudoers configuration is invalid; repair it before installation.'
/usr/bin/plutil -lint "$work/daemon.plist" || fail 'Generated daemon plist is invalid.'

mutated=1
if [ "$old_loaded" -eq 1 ]; then
    /bin/launchctl bootout "$service" || fail 'Cannot unload the previous boot-reset job.'
fi
/usr/bin/install -o root -g wheel -m 0440 "$work/sudoers" "$sudoers_path"
/usr/sbin/visudo -c -f "$sudoers_path" || fail 'Installed sudoers rule failed validation.'
/usr/sbin/visudo -c || fail 'Installed rule invalidated the full sudoers configuration.'
/usr/bin/install -o root -g wheel -m 0644 "$work/daemon.plist" "$daemon_path"
# Explicitly confirm the reset succeeds; bootstrap also invokes it at RunAtLoad.
/usr/bin/pmset -a disablesleep 0 || fail 'Cannot reset disablesleep to 0.'
/bin/launchctl bootstrap system "$daemon_path" || fail 'Cannot bootstrap the boot-reset daemon.'
committed=1
printf 'Clam helper installed for %s. disablesleep is now 0; the daemon resets it again at every boot.\n' "$account"
