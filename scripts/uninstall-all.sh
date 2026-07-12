#!/bin/bash
# uninstall-all.sh — Reverts all Blockdown daemon/blocking changes.
#
# Installed (Part 2 item D) as the hidden gated teardown at
# /usr/local/libexec/.bd/reconcile. It is NOT a public command: it runs only via
# the TUI (Settings → Uninstall), which mints a short-lived token first. In a dev
# clone (testing marker present) it may still be run directly:
#     sudo bash scripts/uninstall-all.sh
#
# Authorization: the testing marker OR a fresh, root-owned teardown token.

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo (or via the Blockdown TUI: Settings → Uninstall)."
    exit 1
fi

CACHE="/Library/Application Support/.cache"
# Item 0 — testing-mode marker. Present = recoverable testing mode: teardown is
# permitted without a token, and supervision is already paused.
BD_TESTING_MARKER="${CACHE}/.bd-testing"
# Part 2 — one-time teardown token minted by mint-teardown-token after the TUI's
# gate_action clears. Consumed (deleted) below before any destructive step.
BD_TEARDOWN_TOKEN="${CACHE}/.bd-teardown-token"
UPTIME_TICKS_FILE="${CACHE}/.uptime-ticks"
BLOCKDOWN_LIBEXEC="/usr/local/libexec/.bd"
# Blockdown edition marker (no lock-in). No gated teardown — nothing was
# locked and nothing self-heals — so the plain script authorizes itself on this marker.
BD_EDITION_MARKER="${CACHE}/.bd-edition"
bd_is_testing_mode() { [ -f "$BD_TESTING_MARKER" ]; }
bd_is_lite() { [ -f "$BD_EDITION_MARKER" ] && [ "$(cat "$BD_EDITION_MARKER" 2>/dev/null)" = "lite" ]; }

# ── Part 2 item D — authorization gate ────────────────────────────────────────
# Post-go-live (marker removed, supervision live) teardown requires a fresh token
# that is owned by root, mode 600, and not yet expired. The marker path stays an
# accepted authorization for recoverable dev/testing installs.
teardown_authorized() {
    bd_is_testing_mode && return 0
    bd_is_lite && return 0
    [ -f "$BD_TEARDOWN_TOKEN" ] || return 1
    local owner mode expiry now
    owner=$(stat -f '%Su:%Sg' "$BD_TEARDOWN_TOKEN" 2>/dev/null || echo "")
    mode=$(stat -f '%Lp' "$BD_TEARDOWN_TOKEN" 2>/dev/null || echo "")
    [ "$owner" = "root:wheel" ] || return 1
    [ "$mode" = "600" ] || return 1
    expiry=$(sed -n '2p' "$BD_TEARDOWN_TOKEN" 2>/dev/null || echo "")
    case "$expiry" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s)
    [ "$now" -lt "$expiry" ]
}

if ! teardown_authorized; then
    echo "  ✗ Teardown not authorized." >&2
    echo "    Open the Blockdown TUI and choose Settings → Uninstall." >&2
    exit 1
fi

# Consume the token immediately (single-use): a failed teardown must not leave a
# reusable token behind. The marker path has nothing to consume.
if [ -f "$BD_TEARDOWN_TOKEN" ]; then
    chflags noschg "$BD_TEARDOWN_TOKEN" 2>/dev/null || true
    rm -f "$BD_TEARDOWN_TOKEN"
fi

# ── Pause supervision FIRST (most dangerous step) ─────────────────────────────
# Once the testing marker is gone, killappsd re-heals every ~10s and statsd
# re-heals on its WatchPaths trigger — which deleting a watched file itself fires.
# A teardown that just unlock→bootout→rm loses that race. So before ANY unlock or
# removal: (1) recreate the testing marker, which the LIVE (schg-locked) daemons
# already honor (supervise_all no-ops, statsd exits early); (2) bootout the three
# supervisors so none can re-heal mid-run. Only then proceed. The final cleanup
# below removes the marker again once every supervisor is gone.
pause_supervision() {
    mkdir -p "$CACHE" 2>/dev/null || true
    touch "$BD_TESTING_MARKER" 2>/dev/null || true
    chown root:wheel "$BD_TESTING_MARKER" 2>/dev/null || true
    chmod 644 "$BD_TESTING_MARKER" 2>/dev/null || true
    # bootout does not require the plist to be unlocked; schg blocks writes, not reads.
    launchctl bootout system /Library/LaunchDaemons/com.apple.appblockerd.plist 2>/dev/null || true
    launchctl bootout system /Library/LaunchDaemons/com.apple.statsd.plist 2>/dev/null || true
    launchctl bootout system /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || true
}
pause_supervision

# Fail-loud guard. From here until teardown completes, an abnormal exit (a failed
# command under `set -e`, Ctrl-C, SIGTERM, power loss mid-run) leaves the recreated
# testing marker in place. While that marker exists, supervision is paused and the
# removal gates are bypassed — i.e. the stack is DISARMED but may still be installed.
# That must never be silent: warn, and tell the user exactly how to finish or re-arm.
# The trap is cleared once teardown has definitively completed.
_teardown_interrupted() {
    local rc=$?
    echo "" >&2
    echo "  ✗ Blockdown teardown was INTERRUPTED before it finished (exit ${rc})." >&2
    if [ -f "$BD_TESTING_MARKER" ]; then
        echo "    The recovery marker is still present, so the stack is DISARMED:" >&2
        echo "    self-heal is paused and removal gates are bypassed." >&2
    fi
    echo "" >&2
    echo "    To FINISH removing Blockdown, re-run the uninstall" >&2
    echo "    (TUI: Settings → Uninstall) — it is safe to run again." >&2
    echo "    To RE-ARM the stack instead, remove the marker:" >&2
    echo "      sudo chflags noschg '$BD_TESTING_MARKER'; sudo rm -f '$BD_TESTING_MARKER'" >&2
    echo "    See OVERVIEW.md §8 for the manual teardown/recovery runbook." >&2
    echo "" >&2
    # Halt: on a signal (Ctrl-C/SIGTERM) the trap would otherwise resume teardown.
    # Exit non-zero so an interrupt actually stops here.
    [ "${rc:-0}" -ne 0 ] 2>/dev/null && exit "$rc"
    exit 1
}
trap '_teardown_interrupted' ERR INT TERM

# Resolve the human user behind sudo so the per-user config dir removal below
# actually fires. Without this REAL_USER is unset and a bare-CLI uninstall
# (`sudo blockdown uninstall`, outside the TUI) leaves the user's
# ~/Library/Application Support/Blockdown (unlock key, cooldown, first-run flag)
# behind. Mirrors the derivation in install-dns.sh.
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-}")}"

# ── Progress output ───────────────────────────────────────────────────────────
# The user sees one working state and a final result. Every internal step is
# appended to a log file, and shown on screen only with --verbose.
VERBOSE="${BLOCKDOWN_VERBOSE:-0}"
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1
LOG_DIR="/Library/Logs/Blockdown"
LOG_FILE="${LOG_DIR}/uninstall.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true; [[ "$VERBOSE" == "1" ]] && echo "  $*"; return 0; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; }

# Export the live block lists before teardown for a possible reinstall. These are
# the user's *personal* blocks, so they must NOT be written into the tracked repo
# data/ dir (that would clobber the shipped generic templates and stage personal
# data for commit). Always export to a system backup location outside the clone.
BACKUP_ROOT="/Library/Application Support/.cache/uninstall-backup"
DATA_DIR="${BACKUP_ROOT}"
mkdir -p "$DATA_DIR"
log "Exporting current block lists to ${BACKUP_ROOT} (never into the repo)."

list_network_services() {
    networksetup -listallnetworkservices 2>/dev/null \
        | tail -n +2 \
        | grep -v '^\*' \
        | grep -v '^An asterisk' || true
}

csv_is_only_localhost_dns() {
    local servers="$1"
    [[ -n "$servers" ]] || return 1
    ! printf '%s\n' "$servers" | tr ',' '\n' | grep -qvE '^(127\.0\.0\.1|::1)$'
}

clear_localhost_dns_routes() {
    local service servers
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        servers=$(networksetup -getdnsservers "$service" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        if csv_is_only_localhost_dns "$servers"; then
            log "Clearing stale localhost DNS on ${service}."
            networksetup -setdnsservers "$service" Empty 2>/dev/null || true
        fi
    done <<< "$(list_network_services)"
}

echo ""
echo "  Removing Blockdown from your Mac…"
log "Blockdown uninstall started."

log "Step 1: Exporting current blocks before removal."
if command -v blockdown >/dev/null; then
    log "Exporting app block list."
    BANNED_OUT=$(blockdown app list || true)
    if [[ ! "$BANNED_OUT" =~ "No apps banned." ]]; then
        echo "$BANNED_OUT" > "${DATA_DIR}/banned-apps.txt"
    fi
    log "Exporting host block list."
    PIN_OUT=$(blockdown host list || true)
    if [[ ! "$PIN_OUT" =~ "No hosts pinned." ]] && [[ ! "$PIN_OUT" =~ "No hosts found" ]] && [[ ! "$PIN_OUT" =~ "No hosts blocked." ]]; then
        echo "$PIN_OUT" > "${DATA_DIR}/hosts-domains.txt"
    fi
elif command -v ban >/dev/null; then
    log "Exporting app block list (legacy ban CLI)."
    BANNED_OUT=$(ban list || true)
    if [[ ! "$BANNED_OUT" =~ "No apps banned." ]]; then
        echo "$BANNED_OUT" > "${DATA_DIR}/banned-apps.txt"
    fi
    if command -v pin >/dev/null; then
        log "Exporting host block list (legacy pin CLI)."
        PIN_OUT=$(pin host list || true)
        if [[ ! "$PIN_OUT" =~ "No hosts pinned." ]] && [[ ! "$PIN_OUT" =~ "No hosts found" ]] && [[ ! "$PIN_OUT" =~ "No hosts blocked." ]]; then
            echo "$PIN_OUT" > "${DATA_DIR}/hosts-domains.txt"
        fi
    fi
fi

log "Step 2: Removing app blocking."
if [ -f /Library/LaunchDaemons/com.apple.appblockerd.plist ]; then
    chflags noschg /Library/LaunchDaemons/com.apple.appblockerd.plist 2>/dev/null || true
    launchctl bootout system /Library/LaunchDaemons/com.apple.appblockerd.plist 2>/dev/null || true
    rm -f /Library/LaunchDaemons/com.apple.appblockerd.plist
fi

if [ -f /usr/local/bin/killappsd ]; then
    chflags noschg /usr/local/bin/killappsd 2>/dev/null || true
    rm -f /usr/local/bin/killappsd
fi

rm -f /usr/local/bin/ban /usr/local/bin/pin /usr/local/bin/blockdown
rm -rf /usr/local/lib/blockdown

# Part 2 item D — hidden libexec teardown bundle (Max: reconcile + mint-teardown-token).
# Unlock every schg entry, then remove it. Removing the running reconcile's own
# file is safe: the inode persists until this process exits.
log "Removing hidden teardown bundle."
if [ -d "$BLOCKDOWN_LIBEXEC" ]; then
    find "$BLOCKDOWN_LIBEXEC" -exec chflags noschg {} + 2>/dev/null || true
    chflags noschg "$BLOCKDOWN_LIBEXEC" 2>/dev/null || true
    rm -rf "$BLOCKDOWN_LIBEXEC"
fi
# Prune the /usr/local/libexec parent only if we left it empty.
rmdir /usr/local/libexec 2>/dev/null || true
chflags nouchg,noschg "/Library/Application Support/.cache/banned-bundle-ids.list" 2>/dev/null || true
chflags nouchg,noschg "/Library/Application Support/.cache/banned-processes.list" 2>/dev/null || true
chflags nouchg,noschg "/Library/Application Support/.cache/bannedd.plist" 2>/dev/null || true
rm -f "/Library/Application Support/.cache/banned-bundle-ids.list"
rm -f "/Library/Application Support/.cache/banned-processes.list"
rm -f "/Library/Application Support/.cache/bannedd.plist"

log "Removing app placeholders."
find /Applications -name "*.app" -flags +uchg -exec chflags nouchg {} + -exec rm -rf {} + 2>/dev/null || true
find /Applications -name "* (*).app" -flags +uchg -exec chflags nouchg {} + -exec rm -rf {} + 2>/dev/null || true

log "Step 3: Removing browser policies."
chflags noschg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd 2>/dev/null || true
chflags noschg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd 2>/dev/null || true
chflags noschg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/lib-supervise.sh 2>/dev/null || true
chflags noschg /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || true
chflags noschg /Library/LaunchDaemons/com.apple.statsd.plist 2>/dev/null || true
chflags noschg "/Library/Application Support/.cache/mdsyncd.backup" 2>/dev/null || true
chflags noschg "/Library/Application Support/.cache/mdsyncd.plist.backup" 2>/dev/null || true
chflags nouchg,noschg "/Library/Application Support/.cache/hostsd-state.plist" 2>/dev/null || true
chflags nouchg,noschg "/Library/Application Support/.cache/hostsd.plist" 2>/dev/null || true

launchctl bootout system /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || true
launchctl bootout system /Library/LaunchDaemons/com.apple.statsd.plist 2>/dev/null || true

rm -rf /Library/PrivilegedHelperTools/com.apple.mdsyncd
rm -f /Library/LaunchDaemons/com.apple.mdsyncd.plist
rm -f /Library/LaunchDaemons/com.apple.statsd.plist
rm -f "/Library/Application Support/.cache/mdsyncd.backup"
rm -f "/Library/Application Support/.cache/mdsyncd.plist.backup"
rm -f "/Library/Application Support/.cache/hostsd-state.plist"
rm -f "/Library/Application Support/.cache/hostsd.plist"

log "Removing hardening self-heal backups, tick counter, and testing marker."
for f in \
    "/Library/Application Support/.cache/statsd.backup" \
    "/Library/Application Support/.cache/statsd.plist.backup" \
    "/Library/Application Support/.cache/killappsd.backup" \
    "/Library/Application Support/.cache/appblockerd.plist.backup" \
    "/Library/Application Support/.cache/dns-profile-watcher.backup" \
    "/Library/Application Support/.cache/dnsfilter.pf.plist.backup" \
    "/Library/Application Support/.cache/dnsfilter.profile-watcher.plist.backup" \
    "/Library/Application Support/.cache/lib-supervise.sh.backup" \
    "/Library/Application Support/.cache/pending_removal_app" \
    "/Library/Application Support/.cache/pending_removal_host" \
    "$UPTIME_TICKS_FILE" \
    "$BD_EDITION_MARKER" \
    "$BD_TESTING_MARKER"; do
    chflags nouchg,noschg "$f" 2>/dev/null || true
    rm -f "$f"
done

log "Removing Chromium browser policy plists."
for dir in "/Library/Managed Preferences" "/Library/Preferences"; do
    [ -d "$dir" ] || continue
    for plist in "$dir"/*.plist; do
        [ -f "$plist" ] || continue
        [[ "$(basename "$plist")" == "com.apple.dnsSettings.managed.plist" ]] && continue
        # Fast binary grep before slow plutil parse
        grep -qE 'ExtensionInstallBlocklist|ProxySettings|ExtensionSettings|DnsOverHttpsMode|ForceGoogleSafeSearch' "$plist" 2>/dev/null || continue
        plutil -p "$plist" 2>/dev/null \
            | grep -qE 'ExtensionInstallBlocklist|ProxySettings|ExtensionSettings|DnsOverHttpsMode|ForceGoogleSafeSearch' || continue
        chflags nouchg,noschg "$plist" 2>/dev/null || true
        rm -f "$plist"
    done
done
touch "/Library/Application Support/.cache/browser-policies-disabled"
chmod 644 "/Library/Application Support/.cache/browser-policies-disabled" 2>/dev/null || true
killall cfprefsd 2>/dev/null || true

log "Removing Blockdown session state."
rm -rf "/Library/Application Support/.cache/blockdown"
rm -rf "/Library/Application Support/.cache/lockdown"
if [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
    rm -rf "/Users/${REAL_USER}/Library/Application Support/Blockdown"
fi

log "Step 4: Removing a legacy AdGuard Home DNS stack (if present from an older install)."
launchctl bootout system /Library/LaunchDaemons/com.apple.dnsruled-healer.plist 2>/dev/null || true
launchctl bootout system /Library/LaunchDaemons/com.apple.dnsruled.plist 2>/dev/null || true
launchctl bootout system /Library/LaunchDaemons/com.apple.networkd-helper.plist 2>/dev/null || true
for f in /Library/LaunchDaemons/com.apple.dnsruled-healer.plist \
    /Library/LaunchDaemons/com.apple.dnsruled.plist \
    /Library/LaunchDaemons/com.apple.networkd-helper.plist; do
    chflags noschg "$f" 2>/dev/null || true
    rm -f "$f"
done
chflags noschg /Applications/.networkd-helper/AdGuardHome 2>/dev/null || true
chflags noschg /Applications/.networkd-helper/AdGuardHome.yaml 2>/dev/null || true
rm -rf /Library/PrivilegedHelperTools/com.apple.networkd-helper
rm -rf /Applications/.networkd-helper
rm -rf "/Library/Application Support/.cache/networkd-helper"
rm -f "/Library/Application Support/.cache/dnsruled-state.plist"
rm -f "/Library/Application Support/.cache/dnsruled-testing"
rm -f "/Library/Application Support/.cache/browser-policies-disabled"
rm -f /etc/resolver/blockdown /etc/resolver/lockdown
clear_localhost_dns_routes

log "Step 5: Removing the web filter."
chflags noschg /etc/pf.anchors/dns-filter 2>/dev/null || true
chflags noschg /Library/LaunchDaemons/com.dnsfilter.pf.plist 2>/dev/null || true
chflags noschg /Library/PrivilegedHelperTools/dns-filter.mobileconfig 2>/dev/null || true
chflags noschg /usr/local/sbin/dns-profile-watcher 2>/dev/null || true
chflags noschg /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist 2>/dev/null || true

launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist 2>/dev/null || true
launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.pf.plist 2>/dev/null || true

rm -f /etc/pf.anchors/dns-filter
rm -f /Library/LaunchDaemons/com.dnsfilter.pf.plist
rm -f /Library/PrivilegedHelperTools/dns-filter.mobileconfig
rm -f /usr/local/sbin/dns-profile-watcher
rm -f /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist

log "Restoring /etc/pf.conf."
# Instead of assuming the backup is 100% correct, we just strip our added lines to be safe
sed -i '' '/rdr-anchor "dns-filter"/d' /etc/pf.conf
sed -i '' '/^anchor "dns-filter"/d' /etc/pf.conf
sed -i '' '/load anchor "dns-filter"/d' /etc/pf.conf

    pfctl -f /etc/pf.conf 2>/dev/null || true

    # Strip managed block from /etc/hosts
    log "Restoring /etc/hosts."
    if grep -q "# BLOCKER-MANAGED-START" /etc/hosts 2>/dev/null; then
        chflags noschg /etc/hosts 2>/dev/null || true
        awk -v s="# BLOCKER-MANAGED-START" -v e="# BLOCKER-MANAGED-END" '
            $0 == s { inside = 1; next }
            $0 == e { inside = 0; next }
            !inside { print }
        ' /etc/hosts > /tmp/hosts.clean
        cat /tmp/hosts.clean > /etc/hosts
        rm -f /tmp/hosts.clean
    fi

    log "Removing configuration profiles."
    EXISTING_PROFILES=$(profiles list 2>/dev/null | grep -oE '(com\.cleanbrowsing\.dns|io\.nextdns\.custom|com\.cloudflare\.dns|com\.adguard\.dns|com\.controld\.dns|net\.mullvad\.dns)\.[a-zA-Z0-9._-]+' | sort -u || true)
    if [ -n "$EXISTING_PROFILES" ]; then
    echo "$EXISTING_PROFILES" | while read -r PROFILE_ID; do
        log "Removing profile: $PROFILE_ID"
        profiles remove -identifier "$PROFILE_ID" 2>/dev/null || true
    done
fi

dscacheutil -flushcache
killall -HUP mDNSResponder

# Teardown reached the end successfully — disarm the fail-loud interrupt guard so
# a clean exit doesn't print the interrupted-teardown warning.
trap - ERR INT TERM

log "Uninstall complete."
echo ""
ok "Blockdown has been fully removed."
echo "  Your websites and apps are unblocked and your internet is back to normal."
