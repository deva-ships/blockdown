#!/bin/bash
# install-browser-policies.sh — Layer 4 installer / policy maintenance
# Run as: sudo bash scripts/install-browser-policies.sh [--vpn-extensions|--remove]
#
# Item 0: creates the recoverable testing marker at install start so a fresh
# install stays fully recoverable (supervision paused, removal gates bypassable).
# Item B: installs lib-supervise.sh (canonical copy) + statsd/lib-supervise
# self-heal backups for cyclic cross-supervision.

set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
MDSYNC="/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd"
HELPER_BIN="/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin"
CACHE="/Library/Application Support/.cache"
BD_TESTING_MARKER="${CACHE}/.bd-testing"
HOSTS_STATE="/Library/Application Support/.cache/hostsd-state.plist"
PENDING_REMOVAL_HOST="/Library/Application Support/.cache/pending_removal_host"
HOSTS_MARKER_START="# BLOCKER-MANAGED-START"
HOSTS_MARKER_END="# BLOCKER-MANAGED-END"
MDSYNC_BACKUP="/Library/Application Support/.cache/mdsyncd.backup"
LIB_SUPERVISE="${HELPER_BIN}/lib-supervise.sh"
STATSD_BACKUP="${CACHE}/statsd.backup"
STATSD_PLIST_BACKUP="${CACHE}/statsd.plist.backup"
LIB_SUPERVISE_BACKUP="${CACHE}/lib-supervise.sh.backup"
MANAGED_DIR="/Library/Managed Preferences"
PREFERENCES_DIR="/Library/Preferences"
BROWSER_POLICIES_DISABLED="${CACHE}/browser-policies-disabled"

# Blockdown edition marker (no lock-in). Install the mdsyncd worker (CLI
# backend) but not the self-heal daemons, backups, or schg locks. Policies still
# apply on demand via the CLI; nothing re-applies them or resists removal.
BD_EDITION_MARKER="${CACHE}/.bd-edition"
bd_is_lite() { [ -f "$BD_EDITION_MARKER" ] && [ "$(cat "$BD_EDITION_MARKER" 2>/dev/null)" = "lite" ]; }

_chromium_policy_keys_present() {
    # Fast binary grep before slow plutil parse
    grep -qE 'ExtensionInstallBlocklist|ProxySettings|ExtensionSettings|DnsOverHttpsMode|ForceGoogleSafeSearch' "$1" 2>/dev/null || return 1
    plutil -p "$1" 2>/dev/null \
        | grep -qE 'ExtensionInstallBlocklist|ProxySettings|ExtensionSettings|DnsOverHttpsMode|ForceGoogleSafeSearch'
}

_chromium_policies_on_disk() {
    local dir plist
    for dir in "$MANAGED_DIR" "$PREFERENCES_DIR"; do
        [ -d "$dir" ] || continue
        for plist in "$dir"/*.plist; do
            [ -f "$plist" ] || continue
            [[ "$(basename "$plist")" == "com.apple.dnsSettings.managed.plist" ]] && continue
            _chromium_policy_keys_present "$plist" && return 0
        done
    done
    return 1
}

_remove_chromium_policy_plists() {
    local dir plist
    for dir in "$MANAGED_DIR" "$PREFERENCES_DIR"; do
        [ -d "$dir" ] || continue
        for plist in "$dir"/*.plist; do
            [ -f "$plist" ] || continue
            [[ "$(basename "$plist")" == "com.apple.dnsSettings.managed.plist" ]] && continue
            _chromium_policy_keys_present "$plist" || continue
            chflags nouchg,noschg "$plist" 2>/dev/null || true
            rm -f "$plist"
        done
    done
}

_chromium_browsers_running() {
    local name
    for name in "Google Chrome" "Brave Browser" "Microsoft Edge" "Chromium" \
        "Opera" "Opera GX" "Vivaldi" "Arc" "Dia" "Thorium" "Helium" "LibreWolf"; do
        pgrep -xq "$name" 2>/dev/null && return 0
    done
    return 1
}

_quit_chromium_browsers() {
    _chromium_browsers_running || return 0
    local -a names=(
        "Google Chrome" "Brave Browser" "Microsoft Edge" "Chromium"
        "Opera" "Opera GX" "Vivaldi" "Arc" "Dia" "Thorium" "Helium" "LibreWolf"
    )
    local name
    for name in "${names[@]}"; do
        killall "$name" 2>/dev/null || true
    done
    sleep 0.3
    for name in "${names[@]}"; do
        killall "$name" 2>/dev/null || true
    done
}

_flush_preference_cache() {
    local console_user
    console_user=$(stat -f '%Su' /dev/console 2>/dev/null)

    killall cfprefsd 2>/dev/null || true
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
        su "$console_user" -c "killall cfprefsd" 2>/dev/null \
            || killall -u "$console_user" cfprefsd 2>/dev/null || true
    fi
}

_standalone_policies_remove() {
    mkdir -p "$CACHE"
    : > "$BROWSER_POLICIES_DISABLED"
    chmod 644 "$BROWSER_POLICIES_DISABLED" 2>/dev/null
    _quit_chromium_browsers
    _remove_chromium_policy_plists
    _flush_preference_cache
}

_reload_mdsyncd_daemon() {
    [ -f /Library/LaunchDaemons/com.apple.mdsyncd.plist ] || return 0
    launchctl bootstrap system /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || \
        launchctl load /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || true
}

_sync_mdsyncd_worker() {
    # TUI maintenance runs from the repo checkout — keep the installed worker
    # in sync so policy enable/remove always uses current logic.
    [[ -f "$REPO/files/mdsyncd" ]] || return 0
    [[ -d "$(dirname "$MDSYNC")" ]] || return 0

    chflags noschg "$MDSYNC" 2>/dev/null || true
    if ! cp "$REPO/files/mdsyncd" "$MDSYNC"; then
        echo "Could not update mdsyncd worker at $MDSYNC" >&2
        exit 1
    fi
    chown root:wheel "$MDSYNC"
    chmod 755 "$MDSYNC"
    # Blockdown leaves the worker unlocked and seeds no self-heal backup.
    bd_is_lite && return 0
    chflags schg "$MDSYNC" 2>/dev/null || true

    if [[ -d "$(dirname "$MDSYNC_BACKUP")" ]]; then
        chflags noschg "$MDSYNC_BACKUP" 2>/dev/null || true
        cp "$REPO/files/mdsyncd" "$MDSYNC_BACKUP"
        chown root:wheel "$MDSYNC_BACKUP"
        chmod 755 "$MDSYNC_BACKUP"
        chflags schg "$MDSYNC_BACKUP" 2>/dev/null || true
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo bash scripts/install-browser-policies.sh"
    exit 1
fi

MODE="install"
# --quiet: caller (the TUI) already prints the user-facing result and steps, so
# suppress this script's own status/instruction lines to avoid double-printing.
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpn-extensions) MODE="vpn"; shift ;;
        --remove)         MODE="remove"; shift ;;
        --quiet)          QUIET=1; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: sudo bash scripts/install-browser-policies.sh \\" >&2
            echo "  [--vpn-extensions|--remove] [--quiet]" >&2
            exit 1
            ;;
    esac
done

if [[ "$MODE" == "vpn" ]]; then
    _sync_mdsyncd_worker
    if [[ "$QUIET" != "1" ]]; then
        echo ""
        echo "Applying VPN extension browser policies..."
    fi
    # Redirect the applier's own "Browser policies enabled and applied."
    # chatter; it's internal, and the caller reports the result.
    if [[ -x "$MDSYNC" ]]; then
        "$MDSYNC" policies enable >/dev/null
    elif [[ -x /usr/local/bin/blockdown ]]; then
        /usr/local/bin/blockdown policies enable >/dev/null
    else
        echo "Layer 4 not installed. Run the full installer first." >&2
        exit 1
    fi
    if [[ "$QUIET" != "1" ]]; then
        echo "VPN extension policies applied."
        echo ""
        echo "  Reopen your browser when you're ready."
    fi
    exit 0
fi

if [[ "$MODE" == "remove" ]]; then
    _sync_mdsyncd_worker 2>/dev/null || true
    if [[ "$QUIET" != "1" ]]; then
        echo ""
        echo "Removing browser policies..."
    fi

    # Stop the hourly applier so WatchPaths cannot rewrite plists mid-removal.
    launchctl bootout system /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || true

    if [[ -x "$MDSYNC" ]]; then
        if [[ "$QUIET" == "1" ]]; then
            "$MDSYNC" policies remove >/dev/null 2>&1
        else
            "$MDSYNC" policies remove
        fi
    elif [[ -x /usr/local/bin/blockdown ]]; then
        if [[ "$QUIET" == "1" ]]; then
            /usr/local/bin/blockdown policies remove >/dev/null 2>&1
        else
            /usr/local/bin/blockdown policies remove
        fi
    else
        _standalone_policies_remove
    fi

    # Orphan plists only — skip re-quitting browsers and re-flushing cache.
    if _chromium_policies_on_disk; then
        _remove_chromium_policy_plists
    fi

    _reload_mdsyncd_daemon

    if [[ "$QUIET" != "1" ]]; then
        echo "Browser policies removed."
        echo ""
        echo "  Fully quit and reopen Chrome (or open chrome://policy → Reload policies)."
    fi
    exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        Layer 4 — Browser Policies Installer             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Step 0 — Enter recoverable testing mode (Item 0) ──────────────────────────
# Marker present = supervision paused + removal gates bypassable, so this
# install (and layer reinstalls) stay recoverable. Removed only in Part 2.
echo "Step 0/8: Entering recoverable testing mode..."
mkdir -p "$CACHE"
touch "$BD_TESTING_MARKER"
chown root:wheel "$BD_TESTING_MARKER"
chmod 644 "$BD_TESTING_MARKER"
echo "  Done."

# ── Step 1 — Create directories ───────────────────────────────────────────────
echo "Step 1/8: Creating directories..."
mkdir -p /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin
mkdir -p "/Library/Application Support/.cache"
mkdir -p /usr/local/bin
mkdir -p "/Library/Managed Preferences"
chmod 755 /Library/PrivilegedHelperTools/com.apple.mdsyncd
chmod 755 /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin
chmod 755 "/Library/Application Support/.cache"
chmod 755 /usr/local/bin
chmod 755 "/Library/Managed Preferences"
echo "  Done."

# ── Step 2 — Install binaries ─────────────────────────────────────────────────
echo "Step 2/8: Installing mdsyncd, statsd, and lib-supervise..."
chflags noschg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd 2>/dev/null || true
chflags noschg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd 2>/dev/null || true
chflags noschg "$LIB_SUPERVISE" 2>/dev/null || true
cp "$REPO/files/mdsyncd" /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd
cp "$REPO/files/statsd" /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd
cp "$REPO/files/lib-supervise.sh" "$LIB_SUPERVISE"
chown -R root:wheel /Library/PrivilegedHelperTools/com.apple.mdsyncd
chmod 755 /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd
chmod 755 /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd
chmod 644 "$LIB_SUPERVISE"
echo "  Done."

# ── Step 3 — Seed backups ─────────────────────────────────────────────────────
if bd_is_lite; then
echo "Step 3/8: Skipped (Blockdown: no self-heal backups)."
else
echo "Step 3/8: Seeding backups for self-heal..."
chflags noschg "/Library/Application Support/.cache/mdsyncd.backup" 2>/dev/null || true
chflags noschg "/Library/Application Support/.cache/mdsyncd.plist.backup" 2>/dev/null || true
chflags noschg "$STATSD_BACKUP" "$STATSD_PLIST_BACKUP" "$LIB_SUPERVISE_BACKUP" 2>/dev/null || true
cp /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd "/Library/Application Support/.cache/mdsyncd.backup"
cp "$REPO/files/com.apple.mdsyncd.plist" "/Library/Application Support/.cache/mdsyncd.plist.backup"
# Item B: statsd + lib-supervise backups (peers in the cyclic supervision set).
cp "$REPO/files/statsd" "$STATSD_BACKUP"
cp "$REPO/files/com.apple.statsd.plist" "$STATSD_PLIST_BACKUP"
cp "$REPO/files/lib-supervise.sh" "$LIB_SUPERVISE_BACKUP"
chown root:wheel "/Library/Application Support/.cache/mdsyncd.backup" "/Library/Application Support/.cache/mdsyncd.plist.backup" \
    "$STATSD_BACKUP" "$STATSD_PLIST_BACKUP" "$LIB_SUPERVISE_BACKUP"
chmod 755 "/Library/Application Support/.cache/mdsyncd.backup"
chmod 644 "/Library/Application Support/.cache/mdsyncd.plist.backup"
chmod 755 "$STATSD_BACKUP"
chmod 644 "$STATSD_PLIST_BACKUP"
chmod 644 "$LIB_SUPERVISE_BACKUP"
echo "  Done."
fi

# ── Step 4 — Install LaunchDaemons ───────────────────────────────────────────
# The mdsyncd/statsd LaunchDaemons only exist to periodically re-apply and
# self-heal. Blockdown applies policies on demand via the CLI instead, so it
# installs neither daemon — removing them stays as simple as never having them.
if bd_is_lite; then
echo "Step 4/8: Skipped (Blockdown: no self-heal LaunchDaemons)."
else
echo "Step 4/8: Installing LaunchDaemons..."
chflags noschg /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || true
chflags noschg /Library/LaunchDaemons/com.apple.statsd.plist 2>/dev/null || true
cp "$REPO/files/com.apple.mdsyncd.plist" /Library/LaunchDaemons/com.apple.mdsyncd.plist
cp "$REPO/files/com.apple.statsd.plist" /Library/LaunchDaemons/com.apple.statsd.plist
chown root:wheel /Library/LaunchDaemons/com.apple.mdsyncd.plist /Library/LaunchDaemons/com.apple.statsd.plist
chmod 644 /Library/LaunchDaemons/com.apple.mdsyncd.plist /Library/LaunchDaemons/com.apple.statsd.plist
echo "  Done."
fi

# ── Step 5 — Install blockdown CLI ───────────────────────────────────────────
echo "Step 5/8: Installing blockdown CLI..."
bash "$REPO/scripts/install-cli.sh" "$REPO"
echo "  Done."

echo "Step 6/8: Resetting dynamic host blocks..."
chflags nouchg,noschg "$HOSTS_STATE" "$PENDING_REMOVAL_HOST" /etc/hosts 2>/dev/null || true
rm -f "$HOSTS_STATE" "$PENDING_REMOVAL_HOST"
if grep -q "$HOSTS_MARKER_START" /etc/hosts 2>/dev/null; then
    awk -v s="$HOSTS_MARKER_START" -v e="$HOSTS_MARKER_END" '
        $0 == s { inside = 1; next }
        $0 == e { inside = 0; next }
        !inside { print }
    ' /etc/hosts > /tmp/blockdown.hosts.clean
    cat /tmp/blockdown.hosts.clean > /etc/hosts
    rm -f /tmp/blockdown.hosts.clean
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
fi
echo "  Done."

# ── Step 6b — Defer VPN policies until Fix bypasses opt-in ───────────────────
# Layer 4 installs the worker and daemons, but extension blocking only starts
# when the user chooses "Block VPN browser extensions" (--vpn-extensions).
echo "Step 6b/8: Deferring VPN extension policies until you opt in..."
if _chromium_policies_on_disk; then
    echo "  Old browser policies found on disk. Removing them cleanly..."
    _standalone_policies_remove
else
    mkdir -p "$CACHE"
    : > "$BROWSER_POLICIES_DISABLED"
    chmod 644 "$BROWSER_POLICIES_DISABLED"
fi
echo "  Done."

# ── Step 7 — Load daemons ─────────────────────────────────────────────────────
if bd_is_lite; then
echo "Step 7/8: Skipped (Blockdown: no daemons to load)."
else
echo "Step 7/8: Loading daemons..."
launchctl bootstrap system /Library/LaunchDaemons/com.apple.mdsyncd.plist 2>/dev/null || \
    launchctl load /Library/LaunchDaemons/com.apple.mdsyncd.plist
launchctl bootstrap system /Library/LaunchDaemons/com.apple.statsd.plist 2>/dev/null || \
    launchctl load /Library/LaunchDaemons/com.apple.statsd.plist
echo "  Done."
fi

# ── Step 8 — Lock with schg ───────────────────────────────────────────────────
if bd_is_lite; then
echo "Step 8/8: Skipped (Blockdown: files stay unlocked and removable)."
else
echo "Step 8/8: Locking files with schg..."
chflags schg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd
chflags schg /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd
chflags schg "$LIB_SUPERVISE"
chflags schg /Library/LaunchDaemons/com.apple.mdsyncd.plist
chflags schg /Library/LaunchDaemons/com.apple.statsd.plist
chflags schg "/Library/Application Support/.cache/mdsyncd.backup"
chflags schg "/Library/Application Support/.cache/mdsyncd.plist.backup"
chflags schg "$STATSD_BACKUP" "$STATSD_PLIST_BACKUP" "$LIB_SUPERVISE_BACKUP"
echo "  Done."
fi

# ── Full verification ──────────────────────────────────────────────────────────
echo "── Full Verification ─────────────────────────────────────────────────────"
echo ""
pass=0; fail=0

check() {
    local label="$1"; local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  [PASS] $label"
        pass=$((pass + 1))
    else
        echo "  [FAIL] $label"
        fail=$((fail + 1))
    fi
}

echo "  [Binaries & locks]"
check "mdsyncd binary exists"        "[ -f /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd ]"
check "statsd binary exists"         "[ -f /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd ]"
check "blockdown CLI installed"         "[ -f /usr/local/bin/blockdown ]"
if ! bd_is_lite; then
check "mdsyncd schg locked"          "ls -lO /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd | grep -q schg"
check "statsd schg locked"           "ls -lO /Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd | grep -q schg"
check "mdsyncd backup schg locked"   "ls -lO '/Library/Application Support/.cache/mdsyncd.backup' | grep -q schg"
check "plist backup schg locked"     "ls -lO '/Library/Application Support/.cache/mdsyncd.plist.backup' | grep -q schg"

echo ""
echo "  [LaunchDaemons]"
check "mdsyncd.plist schg locked"    "ls -lO /Library/LaunchDaemons/com.apple.mdsyncd.plist | grep -q schg"
check "statsd.plist schg locked"     "ls -lO /Library/LaunchDaemons/com.apple.statsd.plist | grep -q schg"
check "mdsyncd daemon running"       "launchctl list | grep -q com.apple.mdsyncd"
check "statsd daemon running"        "launchctl list | grep -q com.apple.statsd"
else
echo "  [Blockdown: no schg locks or self-heal daemons installed]"
fi

echo ""
echo "  [Chromium policies — deferred until Fix bypasses → Block VPN extensions]"
check "browser-policies-disabled marker set" "[ -f '$BROWSER_POLICIES_DISABLED' ]"
check "no VPN policy plists on disk" "! _chromium_policies_on_disk"

echo ""
echo "  Result: $pass passed, $fail failed."
echo ""

if [ "$fail" -eq 0 ]; then
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       Layer 4 fully installed and verified.              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
else
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║   Layer 4 installed with warnings. Review FAILs above.  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
fi

echo ""
echo "  Next: use Fix bypasses → Block VPN browser extensions to turn on policies."
echo "        After that, open chrome://policy → Reload policies to confirm."
echo ""

# ── Arm: leave recoverable testing mode ───────────────────────────────────────
# Removing the marker activates Max's self-heal + gated teardown. Inert for
# Blockdown. Onboarding sets BD_DEFER_ARM=1 to arm ONCE after Layer 4 + 2 are
# both installed (avoids a supervisor-vs-installer race); a standalone run arms
# itself here.
if [ "${BD_DEFER_ARM:-0}" != "1" ]; then
    chflags noschg "$BD_TESTING_MARKER" 2>/dev/null || true
    rm -f "$BD_TESTING_MARKER"
fi
