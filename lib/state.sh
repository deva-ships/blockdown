#!/bin/bash
# state.sh — Config read/write and dry-run state seeding

config_get() {
    local key="$1"
    [[ -f "$BLOCKDOWN_CONFIG" ]] || return 0
    # Must not fail under `set -e` / pipefail when the key is absent.
    grep "^${key}=" "$BLOCKDOWN_CONFIG" 2>/dev/null | head -1 | cut -d= -f2- || true
}

config_set() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$BLOCKDOWN_CONFIG")"
    local tmp="${BLOCKDOWN_CONFIG}.tmp"
    if [[ -f "$BLOCKDOWN_CONFIG" ]]; then
        grep -v "^${key}=" "$BLOCKDOWN_CONFIG" > "$tmp" 2>/dev/null || true
    else
        : > "$tmp"
    fi
    echo "${key}=${value}" >> "$tmp"
    mv -f "$tmp" "$BLOCKDOWN_CONFIG"
}

_migrate_legacy_state_paths() {
    if [[ "$DRY_RUN" == "true" ]]; then
        local old="/tmp/lockdown-dry-run"
        local new="/tmp/blockdown-dry-run"
        if [[ -d "$old" && ! -d "$new" && -z "${BLOCKDOWN_DRY_RUN_DIR:-}" ]]; then
            mv "$old" "$new"
        fi
        for n in 1 2 3; do
            old="/tmp/lockdown-dns-state-${n}"
            new="/tmp/blockdown-dns-state-${n}"
            if [[ -d "$old" && ! -d "$new" ]]; then
                mv "$old" "$new"
            fi
        done
        return
    fi

    local user_dir="${HOME}/Library/Application Support/Blockdown"
    local legacy_system="/Library/Application Support/.cache/blockdown"
    local legacy_lockdown="/Library/Application Support/.cache/lockdown"

    # Migrate older system-wide TUI state into the per-user directory.
    if [[ ! -d "$user_dir" ]]; then
        mkdir -p "$(dirname "$user_dir")"
        if [[ -d "$legacy_system" ]]; then
            cp -R "$legacy_system" "$user_dir"
        elif [[ -d "$legacy_lockdown" ]]; then
            cp -R "$legacy_lockdown" "$user_dir"
        fi
    fi

    if [[ -f "${user_dir}/lockdown.conf" && ! -f "${user_dir}/blockdown.conf" ]]; then
        mv "${user_dir}/lockdown.conf" "${user_dir}/blockdown.conf"
    fi
}

init_state() {
    _migrate_legacy_state_paths
    mkdir -p "$BLOCKDOWN_STATE_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        _seed_dry_run_state
        _ensure_dry_run_state_files
    else
        _repair_banned_plist_permissions
    fi
}

# Older installs wrote bannedd.plist as root-only (600), so the TUI could not list apps.
_repair_banned_plist_permissions() {
    local plist="/Library/Application Support/.cache/bannedd.plist"
    [[ -f "$plist" && ! -r "$plist" ]] || return 0
    run_cmd sudo chmod 644 "$plist" 2>/dev/null || true
}

_ensure_dry_run_state_files() {
    # Older dry-run directories may predate newer state files. Create any
    # missing ones without clobbering the user's dry-run choices.
    [[ -f "${BLOCKDOWN_STATE_DIR}/blocked-hosts.txt" ]] || : > "${BLOCKDOWN_STATE_DIR}/blocked-hosts.txt"
    [[ -f "${BLOCKDOWN_STATE_DIR}/banned-apps.txt" ]] || : > "${BLOCKDOWN_STATE_DIR}/banned-apps.txt"
    [[ -f "${BLOCKDOWN_STATE_DIR}/pending-removal-host" ]] || : > "${BLOCKDOWN_STATE_DIR}/pending-removal-host"
    [[ -f "${BLOCKDOWN_STATE_DIR}/pending-removal-app" ]] || : > "${BLOCKDOWN_STATE_DIR}/pending-removal-app"
    [[ -f "${BLOCKDOWN_STATE_DIR}/cmd-log.txt" ]] || : > "${BLOCKDOWN_STATE_DIR}/cmd-log.txt"
}

_seed_dry_run_state() {
    # Only seed if the state dir is empty (first run or after reset).
    # Dry-run starts from zero — no pre-loaded blocklists. Real installs
    # populate hosts/apps via install scripts, not this preview state.
    if [[ -f "${BLOCKDOWN_STATE_DIR}/blocked-hosts.txt" ]]; then
        return
    fi

    : > "${BLOCKDOWN_STATE_DIR}/blocked-hosts.txt"
    : > "${BLOCKDOWN_STATE_DIR}/banned-apps.txt"
    : > "${BLOCKDOWN_STATE_DIR}/pending-removal-host"
    : > "${BLOCKDOWN_STATE_DIR}/pending-removal-app"
    : > "${BLOCKDOWN_STATE_DIR}/cmd-log.txt"
}

reset_dry_run_state() {
    rm -rf "$BLOCKDOWN_STATE_DIR"
    mkdir -p "$BLOCKDOWN_STATE_DIR"
    _seed_dry_run_state
    # Clear config so onboarding runs again
    : > "$BLOCKDOWN_CONFIG"
}

# Seed one of the three DNS-workflow states into a freshly-wiped state dir.
# Used by the `--dns-state=N` preview launcher. Onboarding is pre-completed
# (cooldown method) so the preview lands directly on the main menu.
#   1 = DNS not set up      + bypasses not fixed
#   2 = DNS set up          + bypasses not fixed
#   3 = DNS set up          + bypasses fixed
seed_dns_state() {
    local state="$1"

    rm -rf "$BLOCKDOWN_STATE_DIR"
    mkdir -p "$BLOCKDOWN_STATE_DIR"
    _seed_dry_run_state

    config_set FIRST_RUN_COMPLETE true
    config_set UNLOCK_METHOD cooldown
    config_set COOLDOWN_SECONDS 86400
    config_set UNLOCK_KEY_HASH ""

    case "$state" in
        1)
            config_set DNS_FILTER ""
            config_set BYPASS_VPN_FIXED false
            config_set BYPASS_BROWSERS_FIXED false
            ;;
        2)
            config_set DNS_FILTER "CleanBrowsing Adult"
            config_set BYPASS_VPN_FIXED false
            config_set BYPASS_BROWSERS_FIXED false
            ;;
        3)
            config_set DNS_FILTER "CleanBrowsing Adult"
            config_set BYPASS_VPN_FIXED true
            config_set BYPASS_BROWSERS_FIXED true
            ;;
    esac
}
