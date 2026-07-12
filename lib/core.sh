#!/bin/bash
# core.sh — Dry-run infrastructure, path switching, command wrappers

BLOCKDOWN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLOCKDOWN_DATA_DIR="${BLOCKDOWN_ROOT}/data"

# Hidden libexec teardown bundle (Blockdown Max). Holds the gated teardown
# (reconcile) and the one-time token writer (mint-teardown-token), installed by
# install-cli.sh. Not on PATH. Blockdown (non-Max) never installs it.
BLOCKDOWN_LIBEXEC="/usr/local/libexec/.bd"

# Directory holding the maintenance/install scripts the TUI shells out to.
# The TUI always runs from the clone, so this is simply the repo's scripts/.
BLOCKDOWN_SCRIPT_DIR="${BLOCKDOWN_ROOT}/scripts"

if [[ "$DRY_RUN" == "true" ]]; then
    # --dns-state previews point this at a dedicated, per-state directory.
    BLOCKDOWN_STATE_DIR="${BLOCKDOWN_DRY_RUN_DIR:-/tmp/blockdown-dry-run}"
else
    # TUI config and pending timers — user-writable, no sudo required to launch.
    BLOCKDOWN_STATE_DIR="${HOME}/Library/Application Support/Blockdown"
fi

BLOCKDOWN_CONFIG="${BLOCKDOWN_STATE_DIR}/blockdown.conf"

HAS_GUM=false
GUM_BIN=""
if [[ -x "${BLOCKDOWN_ROOT}/bin/gum" ]]; then
    GUM_BIN="${BLOCKDOWN_ROOT}/bin/gum"
    HAS_GUM=true
elif command -v gum &>/dev/null; then
    GUM_BIN="gum"
    HAS_GUM=true
fi

# Avoid `set -e` exits when TERM is unset or `clear` cannot talk to the terminal.
# Every screen starts one blank line below the top edge; this is the single
# source of that margin (ui_section / ui_logo_compact must not add their own).
clear() {
    command clear 2>/dev/null || printf '\033[H\033[2J'
    echo ""
}

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would execute: $*"
        _dry_run_log "$*"
        return 0
    fi
    "$@"
}

_dry_run_log() {
    echo "$*" >> "${BLOCKDOWN_STATE_DIR}/cmd-log.txt"
}

write_state_file() {
    local name="$1" content="$2"
    printf '%s\n' "$content" > "${BLOCKDOWN_STATE_DIR}/${name}"
}

read_state_file() {
    local name="$1"
    local path="${BLOCKDOWN_STATE_DIR}/${name}"
    [[ -f "$path" ]] && cat "$path"
}

append_state_file() {
    local name="$1" line="$2"
    echo "$line" >> "${BLOCKDOWN_STATE_DIR}/${name}"
}

remove_from_state_file() {
    local name="$1" line="$2"
    local path="${BLOCKDOWN_STATE_DIR}/${name}"
    [[ -f "$path" ]] || return 0
    local tmp="${path}.tmp"
    grep -vxF "$line" "$path" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$path"
}

state_file_contains() {
    local name="$1" line="$2"
    local path="${BLOCKDOWN_STATE_DIR}/${name}"
    [[ -f "$path" ]] && grep -qxF "$line" "$path" 2>/dev/null
}

validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

# Collapse www. pairs so counts match what the TUI shows.
_host_dedup_count() {
    awk 'NF {
        domain = $0
        sub(/^www\./, "", domain)
        if (!seen[domain]++) count++
    } END { print count + 0 }'
}

_blockdown_cli() {
    if command -v blockdown &>/dev/null; then
        blockdown "$@"
    elif command -v pin &>/dev/null; then
        # Legacy installs before blockdown CLI was installed.
        case "$1" in
            app)  shift; pin ban "$@" ;;
            host) shift; pin host "$@" ;;
        esac
    elif _mdsyncd_installed; then
        # Dev / PATH edge cases: mdsyncd is installed but the CLI wrapper is not on PATH.
        local mdsync="/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd"
        case "$1" in
            app)  shift; "$mdsync" ban "$@" ;;
            host) shift; "$mdsync" host "$@" ;;
        esac
    fi
}

_mdsyncd_installed() {
    [[ -x "/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd" ]]
}

# Newline-separated banned app names (production reads CLI; dry-run reads local file).
_app_list() {
    if [[ "$DRY_RUN" == "true" ]]; then
        local f="${BLOCKDOWN_STATE_DIR}/banned-apps.txt"
        [[ -f "$f" ]] || return 0
        grep -v '^[[:space:]]*$' "$f" 2>/dev/null || true
    elif _mdsyncd_installed; then
        _blockdown_cli app list 2>/dev/null | grep -vxF "No apps banned." || true
    fi
}

app_block_count() {
    local n
    if [[ "$DRY_RUN" == "true" ]]; then
        count_lines "${BLOCKDOWN_STATE_DIR}/banned-apps.txt"
    elif _mdsyncd_installed; then
        n=$(_app_list | grep -c . 2>/dev/null || true)
        echo "${n:-0}"
    else
        echo "0"
    fi
}

_icase_equal() {
    [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]]
}

# Optional second arg: preloaded newline-separated banned names (avoids re-querying
# the CLI for every installed app during a device scan).
app_is_blocked() {
    local name="${1%.app}"
    local blocked_list="${2-}"

    if [[ -z "$blocked_list" ]]; then
        blocked_list=$(_app_list)
    fi
    [[ -n "$blocked_list" ]] || return 1
    printf '%s\n' "$blocked_list" | grep -Fixq -- "$name"
}

# Run blockdown remove after TUI friction gate. Prints user feedback.
# Returns 0 when removed, 1 when scheduled/pending/error.
# Sets REMOVAL_RESULT to: removed|scheduled|pending|error
_blockdown_remove() {
    local type="$1"
    shift
    local items=("$@")
    local item output confirmed_flag=() last_output=""

    REMOVAL_RESULT=removed

    # TUI friction gate already ran; --confirmed tells mdsyncd to skip its own timer.
    if [[ "$DRY_RUN" != "true" ]]; then
        confirmed_flag=(--confirmed)
    fi

    for item in "${items[@]}"; do
        [[ -n "$item" ]] || continue

        if [[ "$DRY_RUN" == "true" ]]; then
            case "$type" in
                host)
                    local canonical="${item#www.}"
                    remove_from_state_file "blocked-hosts.txt" "$canonical"
                    remove_from_state_file "blocked-hosts.txt" "www.${canonical}"
                    if _website_host_contains "$canonical"; then
                        REMOVAL_RESULT=error
                        ui_error "Removal did not take effect. ${canonical} is still blocked."
                        return 1
                    fi
                    ;;
                app)
                    remove_from_state_file "banned-apps.txt" "$item"
                    ;;
            esac
            continue
        fi

        output=$(sudo blockdown "$type" remove "${confirmed_flag[@]}" "$item" 2>&1) || true
        last_output="$output"

        if echo "$output" | grep -qE '^Removed:'; then
            REMOVAL_RESULT=removed
            if [[ "$type" == "host" ]]; then
                local canonical="${item#www.}"
                if _website_host_contains "$canonical"; then
                    REMOVAL_RESULT=error
                    ui_error "Removal did not take effect. ${canonical} is still blocked."
                    return 1
                fi
            fi
        elif echo "$output" | grep -q 'Removal scheduled'; then
            REMOVAL_RESULT=scheduled
        elif echo "$output" | grep -q 'Removal of .* is pending'; then
            REMOVAL_RESULT=pending
        elif echo "$output" | grep -qE '^(Not blocked|Not in banned list)'; then
            REMOVAL_RESULT=error
            ui_error "$output"
            return 1
        else
            REMOVAL_RESULT=error
            [[ -n "$output" ]] && ui_error "$output"
            return 1
        fi
    done

    case "$REMOVAL_RESULT" in
        removed)
            if ((${#items[@]} == 1)); then
                ui_success "Removed: ${items[0]}"
            else
                ui_success "Removed ${#items[@]} items."
            fi
            return 0
            ;;
        scheduled)
            ui_warn "Removal scheduled: ${items[0]}"
            ui_info "Come back after the wait to finish removal."
            return 1
            ;;
        pending)
            local remaining=""
            remaining=$(echo "$last_output" | grep '^Time remaining:' | head -1 | sed 's/^Time remaining: //')
            if [[ -n "$remaining" ]]; then
                ui_warn "Removal still pending: ${items[0]}. ${remaining} remaining."
            else
                ui_warn "Removal still pending: ${items[0]}"
            fi
            ui_info "Try again when the wait is over."
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

host_block_count() {
    local n
    if [[ "$DRY_RUN" == "true" ]]; then
        local f="${BLOCKDOWN_STATE_DIR}/blocked-hosts.txt"
        if [[ ! -f "$f" ]] || [[ ! -s "$f" ]]; then
            echo "0"
            return 0
        fi
        n=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | _host_dedup_count)
        echo "${n:-0}"
    elif _mdsyncd_installed; then
        n=$(_blockdown_cli host list 2>/dev/null \
            | grep -vxF "No hosts blocked." \
            | _host_dedup_count)
        echo "${n:-0}"
    else
        echo "0"
    fi
}

hash_key() {
    echo -n "$1" | shasum -a 256 | cut -d' ' -f1
}

# Which edition is installed: "lite" = Blockdown, "full" = Blockdown Max.
# Blockdown omits removal-resistance (schg, self-heal, gated teardown). Blocking
# and TUI unlock methods are identical. Absent/unset config reads as Max.
edition() {
    [[ "$(config_get EDITION)" == "lite" ]] && echo "lite" || echo "full"
}

is_lite() { [[ "$(edition)" == "lite" ]]; }

# Which unlock method this install uses: "key", "cooldown", or "none".
# Falls back to inferring from config for any install predating UNLOCK_METHOD.
unlock_method() {
    local m
    m=$(config_get UNLOCK_METHOD)
    if [[ -n "$m" ]]; then
        echo "$m"
        return
    fi
    if [[ -n "$(config_get UNLOCK_KEY_HASH)" ]]; then
        echo "key"
    else
        echo "cooldown"
    fi
}

# Compact form for status lines and countdowns ("1d", "12h", "1h 30m", "15m").
# Zero units are dropped so it never reads "1d 0h".
format_duration() {
    local seconds="$1"
    local days=$(( seconds / 86400 ))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    local out=""
    (( days > 0 ))    && out+="${days}d "
    (( hours > 0 ))   && out+="${hours}h "
    (( minutes > 0 )) && out+="${minutes}m "
    out="${out% }"
    [[ -z "$out" ]] && out="0m"
    echo "$out"
}

# Long form for prose ("24 hours", "1 hour", "15 minutes"). Used in sentences,
# where the compact form reads awkwardly. Matches the cooldown menu labels.
format_duration_long() {
    local seconds="$1"
    if (( seconds % 3600 == 0 )); then
        local hours=$(( seconds / 3600 ))
        (( hours == 1 )) && echo "1 hour" || echo "${hours} hours"
    else
        local minutes=$(( seconds / 60 ))
        (( minutes == 1 )) && echo "1 minute" || echo "${minutes} minutes"
    fi
}

# "1 website" / "2 websites" — count with a correctly pluralized noun.
pluralize() {
    local n="$1" noun="$2"
    (( n == 1 )) && echo "${n} ${noun}" || echo "${n} ${noun}s"
}

count_lines() {
    local file="$1"
    if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
        echo "0"
        return 0
    fi
    grep -c . "$file" 2>/dev/null || echo "0"
}

blocked_websites_label() {
    local host_count
    host_count=$(host_block_count)
    echo "$(pluralize "$host_count" website) blocked"
}

blocked_apps_label() {
    local app_count
    app_count=$(app_block_count)
    echo "$(pluralize "$app_count" app) blocked"
}
