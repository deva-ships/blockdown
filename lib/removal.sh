#!/bin/bash
# removal.sh — Block removal. Branches on the configured unlock method:
#   key      — removal requires the unlock key. No timer, no pending state.
#   cooldown — removal requires waiting out the timer. No key bypass.
#   none     — removal happens immediately. No key, no timer.

verify_unlock_key() {
    local input
    input=$(ui_input "Enter unlock key" --password)
    local input_hash
    input_hash=$(hash_key "$input")
    local stored_hash
    stored_hash=$(config_get UNLOCK_KEY_HASH)
    [[ -n "$stored_hash" && "$input_hash" == "$stored_hash" ]]
}

# attempt_removal "host"|"app" "<item>"
# Returns 0 if removal completed, 1 otherwise.
attempt_removal() {
    local type="$1"
    local item="$2"

    case "$(unlock_method)" in
        key)      _attempt_removal_key "$type" "$item" ;;
        none)     _attempt_removal_none "$type" "$item" ;;
        *)        _attempt_removal_cooldown "$type" "$item" ;;
    esac
}

# --- Key method: blocks come off only with the key. ---
_attempt_removal_key() {
    local type="$1"
    local item="$2"

    ui_warn "Removing this block requires your unlock key."
    echo ""

    if verify_unlock_key; then
        _do_removal "$type" "$item"
        return $?
    fi

    ui_error "Incorrect key. This block stays in place."
    return 1
}

_attempt_removal_none() {
    local type="$1"
    local item="$2"
    _do_removal "$type" "$item"
}

# --- Cooldown method: blocks come off only after waiting out the timer. ---
_attempt_removal_cooldown() {
    local type="$1"
    local item="$2"

    local cooldown
    cooldown=$(config_get COOLDOWN_SECONDS)
    cooldown=${cooldown:-86400}

    local pending_file="${BLOCKDOWN_STATE_DIR}/pending-removal-${type}"

    # Check for existing pending removal
    if [[ -f "$pending_file" ]] && [[ -s "$pending_file" ]]; then
        local pending_item pending_ts
        pending_item=$(head -n 1 "$pending_file" 2>/dev/null)
        pending_ts=$(sed -n '2p' "$pending_file" 2>/dev/null)

        # Validate the pending file
        if [[ -n "$pending_item" ]] && [[ "$pending_ts" =~ ^[0-9]+$ ]]; then
            if [[ "$pending_item" == "$item" ]]; then
                local now remaining
                now=$(date +%s)
                remaining=$(( pending_ts + cooldown - now ))

                if [[ $remaining -le 0 ]]; then
                    _do_removal "$type" "$item"
                    : > "$pending_file"
                    return $?
                else
                    ui_warn "Already counting down. $(format_duration $remaining) left."
                    echo ""
                    local choice
                    choice=$(ui_choose "What would you like to do?" \
                        "Keep waiting" \
                        "Cancel removal")

                    case "$choice" in
                        "Cancel removal")
                            : > "$pending_file"
                            ui_success "Cancelled. $item stays blocked."
                            return 1
                            ;;
                        *)
                            return 1
                            ;;
                    esac
                fi
            else
                ui_warn "Another block is already on the timer: $pending_item"
                ui_info "Only one can count down at a time."
                echo ""
                if ui_confirm "Cancel that timer and start this one instead?"; then
                    : > "$pending_file"
                    ui_success "Switched. $pending_item stays blocked."
                    # Recurse to handle the new request
                    _attempt_removal_cooldown "$type" "$item"
                    return $?
                fi
                return 1
            fi
        fi
    fi

    # No pending removal — start the timer immediately.
    local human_cooldown
    human_cooldown=$(format_duration_long "$cooldown")
    ui_warn "Removing this starts a wait of ${human_cooldown}."
    echo ""

    echo "$item" > "$pending_file"
    date +%s >> "$pending_file"
    ui_success "Wait started. This stays blocked until then."
    ui_info "Come back after that and select it again to finish removal."
    return 1
}

# gate_action <key> <action-label>
# Generic "requires password or cooldown" gate for one-off actions that aren't
# tied to a host/app list (e.g. changing/removing the DNS filter, removing
# browser policies). Returns 0 when the action is cleared to proceed.
#   key      — verify the unlock key once.
#   cooldown — start a per-<key> timer; only clears once it has elapsed.
# On success it emits one trailing blank line so the caller's next prompt or
# menu is separated from the gate output — callers should not add their own
# `echo ""` before or after the gate.
gate_action() {
    local key="$1"
    local label="$2"

    case "$(unlock_method)" in
        none)
            echo ""
            return 0
            ;;
        key)
            ui_warn "${label} requires your unlock key."
            echo ""
            if verify_unlock_key; then
                echo ""
                return 0
            fi
            ui_error "Incorrect key. Nothing changed."
            return 1
            ;;
        *)
            _gate_action_cooldown "$key" "$label"
            ;;
    esac
}

_gate_action_cooldown() {
    local key="$1"
    local label="$2"

    local cooldown
    cooldown=$(config_get COOLDOWN_SECONDS)
    cooldown=${cooldown:-86400}

    local pending_file="${BLOCKDOWN_STATE_DIR}/pending-action-${key}"

    if [[ -f "$pending_file" ]] && [[ -s "$pending_file" ]]; then
        local pending_ts
        pending_ts=$(sed -n '2p' "$pending_file" 2>/dev/null)

        if [[ "$pending_ts" =~ ^[0-9]+$ ]]; then
            local now remaining
            now=$(date +%s)
            remaining=$(( pending_ts + cooldown - now ))

            if [[ $remaining -le 0 ]]; then
                : > "$pending_file"
                echo ""
                return 0
            fi

            ui_warn "${label} is on a timer. $(format_duration $remaining) left."
            echo ""
            local choice
            choice=$(ui_choose "What would you like to do?" \
                "Keep waiting" \
                "Cancel")
            if [[ "$choice" == "Cancel" ]]; then
                : > "$pending_file"
                ui_success "Cancelled. Nothing changed."
            fi
            return 1
        fi
    fi

    local human_cooldown
    human_cooldown=$(format_duration_long "$cooldown")
    ui_warn "${label} starts a wait of ${human_cooldown}."
    printf '%s\n' "$label" > "$pending_file"
    date +%s >> "$pending_file"
    ui_success "Wait started. Come back after that to finish."
    return 1
}

_do_removal() {
    local type="$1"
    local item="$2"

    case "$type" in
        host)
            local canonical="${item#www.}"
            _blockdown_remove host "$canonical"
            ;;
        app)
            _blockdown_remove app "$item"
            local rc=$?
            if [[ $rc -eq 0 ]]; then
                _dns_on_unsupported_browser_unblocked "$item"
            fi
            return $rc
            ;;
    esac
}

_show_backend_pending() {
    local type="$1"
    local status_out line

    [[ "$DRY_RUN" == "true" ]] && return 1
    [[ "$type" != "host" && "$type" != "app" ]] && return 1
    _mdsyncd_installed || return 1

    status_out=$(_blockdown_cli "$type" status 2>/dev/null || true)
    while IFS= read -r line; do
        if [[ "$line" == Pending\ removal:* ]]; then
            echo "  • $line"
            return 0
        fi
        if [[ "$line" == Pending\ removal\ of* ]]; then
            echo "  • $line"
            return 0
        fi
    done <<< "$status_out"
    return 1
}

# Show pending removal status for a type (cooldown method + backend state).
show_pending_status() {
    local type="$1"
    local pending_file="${BLOCKDOWN_STATE_DIR}/pending-removal-${type}"
    local has_any=false

    clear
    ui_heading "Pending removals"
    echo ""

    if [[ "$(unlock_method)" == "cooldown" ]] \
        && [[ -f "$pending_file" ]] && [[ -s "$pending_file" ]]; then
        local pending_item pending_ts cooldown now remaining
        pending_item=$(head -n 1 "$pending_file" 2>/dev/null)
        pending_ts=$(sed -n '2p' "$pending_file" 2>/dev/null)

        if [[ -n "$pending_item" ]] && [[ "$pending_ts" =~ ^[0-9]+$ ]]; then
            cooldown=$(config_get COOLDOWN_SECONDS)
            cooldown=${cooldown:-86400}
            now=$(date +%s)
            remaining=$(( pending_ts + cooldown - now ))

            if [[ $remaining -le 0 ]]; then
                ui_warn "$pending_item is ready to remove."
                ui_info "Select it from Unblock to finish."
            else
                ui_warn "$pending_item: $(format_duration $remaining) left."
            fi
            has_any=true
        fi
    fi

    if _show_backend_pending "$type"; then
        has_any=true
    fi

    if [[ "$has_any" != "true" ]]; then
        ui_info "No pending removals."
    fi
    ui_pause
}
