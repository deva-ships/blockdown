#!/bin/bash
# lib-supervise.sh — cyclic daemon cross-supervision for Blockdown (Item B).
#
# SOURCED (never executed directly) by:
#   - killappsd (Layer 2 kill daemon) at the top of each 10s tick — fast restorer.
#   - mdsyncd   (Layer 1/2/4 worker) at the start of cmd_apply     — hourly + WatchPaths backstop.
#   - statsd    (secondary restorer) on each run.
#
# Goal: every Layer 1–4 daemon binary + plist is restored from a schg-locked
# backup by at least one peer, so booting-out or deleting any single daemon is
# self-healed within ~10s (killappsd tick) or the next mdsyncd/statsd run — no
# unwatched top of the supervision chain.
#
# Defines functions + constants only; there are NO top-level side effects on
# source (safe to `.` from any of the daemons above).

# Item 0 — testing-mode marker. Present = recoverable testing mode: supervise_all()
# no-ops so a layer reinstall (which holds this marker) doesn't fight the installer.
BD_TESTING_MARKER="/Library/Application Support/.cache/.bd-testing"
# Blockdown edition marker (no lock-in). Present = the self-heal layer was never
# meant to run, so supervise_all() no-ops exactly as it does under the testing marker.
BD_EDITION_MARKER="/Library/Application Support/.cache/.bd-edition"

BD_CACHE="/Library/Application Support/.cache"
BD_HELPER_BIN="/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin"

sup_is_testing_mode() {
    [ -f "$BD_TESTING_MARKER" ]
}

sup_is_lite() {
    [ -f "$BD_EDITION_MARKER" ] && [ "$(cat "$BD_EDITION_MARKER" 2>/dev/null)" = "lite" ]
}

# Ensure a launchd job is loaded; bootstrap (or legacy-load) from its plist if
# `launchctl print` reports the label absent.
ensure_loaded() {
    local label="$1" plist="$2"
    [ -f "$plist" ] || return 0
    if launchctl print "system/${label}" >/dev/null 2>&1; then
        return 0
    fi
    launchctl bootstrap system "$plist" 2>/dev/null \
        || launchctl load "$plist" 2>/dev/null \
        || true
}

# Validate a backup before trusting it. A corrupt backup that we blindly restored
# would produce a broken daemon that reloads forever; better to leave the
# (tampered) missing state visible than to loop on garbage.
_sup_backup_valid() {
    local backup="$1" kind="$2"
    [ -s "$backup" ] || return 1
    case "$kind" in
        script) bash -n "$backup" 2>/dev/null ;;
        plist)  plutil -lint "$backup" >/dev/null 2>&1 ;;
        *)      return 0 ;;
    esac
}

# Restore <file> from <backup> if missing (validated first), then (re-)assert
# perms + schg. Re-locking an already-present file closes the
# tamper -> restore -> tamper gap without needing the file to be deleted.
ensure_present() {
    local file="$1" backup="$2" mode="$3" kind="$4"
    if [ ! -f "$file" ]; then
        _sup_backup_valid "$backup" "$kind" || return 0
        mkdir -p "$(dirname "$file")" 2>/dev/null
        cp "$backup" "$file" 2>/dev/null || return 0
        chown root:wheel "$file" 2>/dev/null
        chmod "$mode" "$file" 2>/dev/null
    fi
    chflags schg "$file" 2>/dev/null || true
}

# Re-assert schg on a backup that exists. Backups are the source of truth and
# have nothing to be restored from, so we only keep them locked.
_sup_relock() {
    if [ -f "$1" ]; then
        chflags schg "$1" 2>/dev/null || true
    fi
}

supervise_all() {
    # Item 0: paused while the testing marker is present so layer reinstalls
    # (which set the marker) don't thrash against the installer. Also paused on a
    # Blockdown install, which never installs the self-heal layer this restores.
    { sup_is_testing_mode || sup_is_lite; } && return 0

    # --- Backups: source of truth; keep them locked. ---
    _sup_relock "${BD_CACHE}/mdsyncd.backup"
    _sup_relock "${BD_CACHE}/mdsyncd.plist.backup"
    _sup_relock "${BD_CACHE}/statsd.backup"
    _sup_relock "${BD_CACHE}/statsd.plist.backup"
    _sup_relock "${BD_CACHE}/killappsd.backup"
    _sup_relock "${BD_CACHE}/appblockerd.plist.backup"
    _sup_relock "${BD_CACHE}/dns-profile-watcher.backup"
    _sup_relock "${BD_CACHE}/dnsfilter.pf.plist.backup"
    _sup_relock "${BD_CACHE}/dnsfilter.profile-watcher.plist.backup"
    _sup_relock "${BD_CACHE}/lib-supervise.sh.backup"

    # --- Layer 1/2/4 core: mdsyncd worker + plist. ---
    ensure_present "${BD_HELPER_BIN}/mdsyncd" "${BD_CACHE}/mdsyncd.backup" 755 script
    ensure_present "/Library/LaunchDaemons/com.apple.mdsyncd.plist" "${BD_CACHE}/mdsyncd.plist.backup" 644 plist

    # lib-supervise itself (this file) — every peer keeps it present + locked.
    ensure_present "${BD_HELPER_BIN}/lib-supervise.sh" "${BD_CACHE}/lib-supervise.sh.backup" 644 script

    # statsd (secondary restorer + WatchPaths on the helper bin dir).
    ensure_present "${BD_HELPER_BIN}/statsd" "${BD_CACHE}/statsd.backup" 755 script
    ensure_present "/Library/LaunchDaemons/com.apple.statsd.plist" "${BD_CACHE}/statsd.plist.backup" 644 plist

    # Layer 2 kill daemon.
    ensure_present "/usr/local/bin/killappsd" "${BD_CACHE}/killappsd.backup" 755 script
    ensure_present "/Library/LaunchDaemons/com.apple.appblockerd.plist" "${BD_CACHE}/appblockerd.plist.backup" 644 plist

    # Layer 3 DNS: PF enforcer plist + profile self-healer (worker + plist).
    ensure_present "/Library/LaunchDaemons/com.dnsfilter.pf.plist" "${BD_CACHE}/dnsfilter.pf.plist.backup" 644 plist
    ensure_present "/usr/local/sbin/dns-profile-watcher" "${BD_CACHE}/dns-profile-watcher.backup" 755 script
    ensure_present "/Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist" "${BD_CACHE}/dnsfilter.profile-watcher.plist.backup" 644 plist

    # --- Ensure everything is loaded (dependency order: core first). ---
    ensure_loaded "com.apple.mdsyncd"              "/Library/LaunchDaemons/com.apple.mdsyncd.plist"
    ensure_loaded "com.apple.statsd"               "/Library/LaunchDaemons/com.apple.statsd.plist"
    ensure_loaded "com.apple.appblockerd"          "/Library/LaunchDaemons/com.apple.appblockerd.plist"
    ensure_loaded "com.dnsfilter.pf"               "/Library/LaunchDaemons/com.dnsfilter.pf.plist"
    ensure_loaded "com.dnsfilter.profile-watcher"  "/Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist"
}
