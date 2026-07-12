#!/bin/bash
# =============================================================================
# dns-profile-watcher
#
# Re-queues installation of the DNS filter Configuration Profile whenever it
# is missing. Invoked every 60 seconds by launchd via
# /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist
#
# Only the profile ID embedded in the backup mobileconfig counts as installed.
# A different provider's profile (e.g. Cloudflare when Mullvad was chosen)
# does not satisfy this check — the self-healer will keep re-prompting until
# the correct profile is installed or Layer 3 is removed.
# =============================================================================

set -u

PROFILE_BACKUP="/Library/PrivilegedHelperTools/dns-filter.mobileconfig"

profile_is_installed() {
    local expected_id="$1"
    [[ -n "$expected_id" ]] || return 1
    profiles list -all 2>/dev/null | grep -qiF "$expected_id"
}

if [[ ! -f "$PROFILE_BACKUP" ]]; then
    logger -t dns-profile-watcher "Backup mobileconfig missing at $PROFILE_BACKUP"
    exit 0
fi

EXPECTED_PROFILE_ID=$(/usr/libexec/PlistBuddy -c "Print :PayloadIdentifier" "$PROFILE_BACKUP" 2>/dev/null || true)

if profile_is_installed "$EXPECTED_PROFILE_ID"; then
    exit 0
fi

CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "_mbsetupuser" ]]; then
    logger -t dns-profile-watcher "No interactive console user; deferring re-install prompt"
    exit 0
fi

CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
if [[ -z "$CONSOLE_UID" ]]; then
    exit 0
fi

logger -t dns-profile-watcher "DNS profile missing (expected: ${EXPECTED_PROFILE_ID:-unknown}); opening mobileconfig in ${CONSOLE_USER}'s session (uid=${CONSOLE_UID})"

launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" open "$PROFILE_BACKUP"

exit 0
