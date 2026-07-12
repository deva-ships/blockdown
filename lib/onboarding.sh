#!/bin/bash
# onboarding.sh — First-run setup: splash, edition, unlock method, then key OR cooldown.
#
# Edition controls system lock-in only (Blockdown vs Blockdown Max). Unlock method
# is shared:
#   key      — blocks stay until the key is entered. No timer. (Parental control.)
#   cooldown — blocks can be removed by anyone, but only after a wait. No key. (Self-control.)
#   none     — blocks can be removed instantly. No key, no timer.
# Only one of UNLOCK_KEY_HASH / COOLDOWN_SECONDS is ever set; UNLOCK_METHOD records which.

screen_onboarding() {
    _screen_splash
    screen_edition || exit 0
    # Both editions pick an unlock method. Edition only controls removal-
    # resistance (schg, self-heal, gated teardown) — not TUI friction.
    screen_unlock_method || exit 0
    config_set FIRST_RUN_COMPLETE true
}

# Screen 2 — Edition. Blockdown is the standard product; Max adds lock-in.
# Config EDITION values: lite = Blockdown, full = Blockdown Max (marker compat).
screen_edition() {
    clear

    local choice
    choice=$(ui_choose_desc "Which edition do you want?" \
        "Blockdown" "Simple to uninstall if needed. Best for general use." \
        "Blockdown Max" "Resists a quick teardown. Best when you need it to hold.") || return 1

    case "$choice" in
        "Blockdown Max") config_set EDITION full ;;
        *)               config_set EDITION lite ;;
    esac
    return 0
}

# Screen 1 — Splash
_screen_splash() {
    clear
    ui_logo_compact
    echo -e "  ${_C_BOLD}Screen Time for Mac, but it actually works.${_C_RESET}"
    echo ""
    echo -e "  ${_C_DIM}Block websites and apps across your whole Mac.${_C_RESET}"
    echo -e "  ${_C_DIM}Easy to set up, hard to remove by design.${_C_RESET}"
    ui_pause "Press return to get started. ↵"
}

# Unlock method selection — used during onboarding and from Settings.
# Optional $1: "settings" — skip first-run backend setup after applying the choice.
screen_unlock_method() {
    local from_settings="${1:-}"

    clear

    local method
    method=$(ui_choose_desc "How should blocks be removed?" \
        "Cooldown timer" "Removing a block takes a wait you set now. Best for self-control." \
        "Unlock key" "Blocks stay until your key is entered. Best for parental control." \
        "No restrictions" "Remove blocks anytime. Add a key or timer later in Settings.") || return 1

    case "$method" in
        "Unlock key")      _configure_unlock_key "$from_settings" || return 1 ;;
        "No restrictions") _configure_no_restrictions "$from_settings" || return 1 ;;
        *)                 _configure_cooldown "$from_settings" || return 1 ;;
    esac
    return 0
}

_clear_unlock_pending_state() {
    : > "${BLOCKDOWN_STATE_DIR}/pending-removal-host"
    : > "${BLOCKDOWN_STATE_DIR}/pending-removal-app"
    local f
    for f in "${BLOCKDOWN_STATE_DIR}"/pending-action-*; do
        [[ -f "$f" ]] && : > "$f"
    done
}

_clear_backend_pending_state() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    _mdsyncd_installed || return 0
    run_cmd sudo blockdown app cancel >/dev/null 2>&1 || true
    run_cmd sudo blockdown host cancel >/dev/null 2>&1 || true
}

# Screen 3A — Unlock key flow
_configure_unlock_key() {
    clear
    echo "  Blocks stay in place until this key is entered."
    echo -e "  ${_C_DIM}Keep it somewhere safe. Without it, blocks cannot be removed.${_C_RESET}"
    echo ""

    local key1 key2
    while true; do
        key1=$(ui_input "Enter unlock key" --password)
        if [[ -z "$key1" ]]; then
            ui_error "Key cannot be empty."
            continue
        fi
        if [[ ${#key1} -lt 4 ]]; then
            ui_error "Key must be at least 4 characters."
            continue
        fi
        key2=$(ui_input "Confirm unlock key" --password)
        if [[ "$key1" != "$key2" ]]; then
            ui_error "Keys don't match. Try again."
            continue
        fi
        break
    done

    config_set UNLOCK_METHOD key
    config_set UNLOCK_KEY_HASH "$(hash_key "$key1")"
    # Mutually exclusive: a key-mode install has no cooldown.
    config_set COOLDOWN_SECONDS 0
    _clear_unlock_pending_state
    if [[ "$1" == "settings" ]]; then
        ui_success "Unlock key saved."
        ui_pause
        return 0
    fi
    _show_onboard_complete
}

# Screen 3B — No restrictions
_configure_no_restrictions() {
    config_set UNLOCK_METHOD none
    config_set UNLOCK_KEY_HASH ""
    config_set COOLDOWN_SECONDS 0
    _clear_unlock_pending_state
    _clear_backend_pending_state
    if [[ "$1" == "settings" ]]; then
        ui_success "No restrictions enabled."
        ui_pause
        return 0
    fi
    _show_onboard_complete
}

# Screen 3C — Cooldown flow
_configure_cooldown() {
    local from_settings="${1:-}"
    clear
    echo "  Removing a block won't take effect right away."
    echo "  It stays active until the timer you set runs out."
    echo -e "  ${_C_DIM}You can make this longer later, but never shorter.${_C_RESET}"
    echo ""

    local duration_items=(
        "15 min"
        "30 min"
        "1 hour"
        "3 hours"
        "6 hours"
        "12 hours"
        "24 hours"
        "48 hours"
    )
    [[ "$from_settings" == "settings" ]] && duration_items+=("← Cancel")

    local choice
    if ! choice=$(ui_choose "How long should the wait be?" "${duration_items[@]}"); then
        [[ "$from_settings" == "settings" ]] && return 1
        exit 0
    fi

    if [[ "$choice" == "← Cancel" || -z "$choice" ]]; then
        return 1
    fi

    local seconds
    case "$choice" in
        "15 min")   seconds=900 ;;
        "30 min")   seconds=1800 ;;
        "1 hour")   seconds=3600 ;;
        "3 hours")  seconds=10800 ;;
        "6 hours")  seconds=21600 ;;
        "12 hours") seconds=43200 ;;
        "24 hours") seconds=86400 ;;
        "48 hours") seconds=172800 ;;
        *)          return 1 ;;
    esac

    config_set UNLOCK_METHOD cooldown
    config_set COOLDOWN_SECONDS "$seconds"
    # Mutually exclusive: a cooldown-mode install has no unlock key.
    config_set UNLOCK_KEY_HASH ""
    _clear_unlock_pending_state
    if [[ "$from_settings" == "settings" ]]; then
        ui_success "Cooldown timer set to $(format_duration_long "$seconds")."
        ui_pause
        return 0
    fi
    _show_onboard_complete
}

# Success message on the same page as setup — no extra screen transition.
_show_onboard_complete() {
    echo ""

    case "$(config_get UNLOCK_METHOD)" in
        cooldown)
            local seconds
            seconds=$(config_get COOLDOWN_SECONDS)
            seconds=${seconds:-86400}
            ui_success "Cooldown timer set to $(format_duration_long "$seconds")."
            ;;
        none)
            ui_success "No restrictions enabled."
            ;;
        *)
            ui_success "Unlock key saved."
            ;;
    esac

    echo ""
    case "$(config_get UNLOCK_METHOD)" in
        cooldown)
            echo "  You can make your cooldown timer longer in Settings."
            ;;
        none)
            echo "  You can add an unlock key or a cooldown timer later in Settings."
            ;;
        *)
            echo "  You can change your unlock key in Settings."
            ;;
    esac

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then

        ui_info "Dry run: setup skipped."
    else
        echo "  Finishing setup..."
        # set-edition must succeed: uninstall and the installers key off the
        # root-owned .bd-edition marker, not the user-writable config. Use
        # `bash` so a missing +x bit cannot silently skip the marker write.
        if ! run_cmd sudo bash "${BLOCKDOWN_SCRIPT_DIR}/set-edition.sh" "$(edition)"; then
            ui_error "Could not set the edition marker. Setup is incomplete."
            ui_pause
            return 1
        fi
        # BD_DEFER_ARM: install Layers 4 and 2 with the testing marker held so
        # supervision stays paused across both (an installer that armed at its own
        # end would let its self-heal fight the next layer's install). We arm once
        # below, after both layers are in.
        run_cmd sudo env BD_DEFER_ARM=1 bash "${BLOCKDOWN_SCRIPT_DIR}/install-browser-policies.sh" >/dev/null 2>&1 || true
        run_cmd sudo env BD_DEFER_ARM=1 bash "${BLOCKDOWN_SCRIPT_DIR}/install-app-blocking.sh" >/dev/null 2>&1 || true
        # Arm: leave recoverable testing mode now that all onboarding layers are
        # installed. For Blockdown Max this activates self-heal + the gated
        # teardown; for Blockdown the marker is inert, but we clear it either way
        # so it never lingers. (The web filter, set up later, manages its own.)
        run_cmd sudo chflags noschg "/Library/Application Support/.cache/.bd-testing" 2>/dev/null || true
        run_cmd sudo rm -f "/Library/Application Support/.cache/.bd-testing"
        ui_success "Setup complete."
    fi

    ui_pause
}
