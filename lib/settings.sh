#!/bin/bash
# settings.sh — Update key, timer, and related settings

screen_settings() {
    while true; do
        clear
        ui_section "Settings"
        echo ""
        # Unlock method is edition-independent: Blockdown and Max both gate TUI
        # removals. Edition only controls system lock-in (schg / self-heal).
        # Key/cooldown are sticky — change only via uninstall + reinstall.
        # "Set unlock method" is only for none (no restrictions).
        local menu_items=()
        if [[ "$(unlock_method)" == "none" ]]; then
            menu_items+=("Set unlock method")
        elif [[ "$(unlock_method)" == "key" ]]; then
            menu_items+=("Update unlock key")
        elif [[ "$(unlock_method)" == "cooldown" ]]; then
            menu_items+=("Update cooldown timer")
        fi

        # After Fix bypasses opt-in, or when Layer 4 left policy plists on disk.
        if _dns_browser_policies_removable; then
            menu_items+=("Unblock VPN extensions")
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            menu_items+=("Reset dry-run state")
        fi
        menu_items+=("Uninstall")
        menu_items+=("← Back")

        local choice
        if ! choice=$(ui_choose "What would you like to do?" "${menu_items[@]}"); then
            continue
        fi

        case "$choice" in
            "Set unlock method")
                _settings_set_unlock_method && return
                ;;
            "Update unlock key")      _settings_update_key ;;
            "Update cooldown timer")  _settings_update_timer ;;
            "Unblock VPN extensions") _settings_remove_policies ;;
            "Reset dry-run state")    _settings_reset_dry_run ;;
            "Uninstall")              _settings_uninstall ;;
            "← Back"|"")             return ;;
        esac
    done
}

_settings_set_unlock_method() {
    # Only reachable when unlock_method is none (menu gated above).
    screen_unlock_method settings
}

_settings_update_key() {
    clear
    echo "  To change your unlock key, enter the current one first."
    echo ""

    if ! verify_unlock_key; then
        ui_error "Incorrect key. Unlock key unchanged."
        ui_pause
        return
    fi

    echo ""
    local key1 key2
    while true; do
        key1=$(ui_input "Enter new unlock key" --password)
        if [[ -z "$key1" ]]; then
            ui_error "Key cannot be empty."
            continue
        fi
        if [[ ${#key1} -lt 4 ]]; then
            ui_error "Key must be at least 4 characters."
            continue
        fi
        key2=$(ui_input "Confirm new unlock key" --password)
        if [[ "$key1" != "$key2" ]]; then
            ui_error "Keys don't match. Try again."
            continue
        fi
        break
    done

    local key_hash
    key_hash=$(hash_key "$key1")
    config_set UNLOCK_KEY_HASH "$key_hash"
    ui_success "Unlock key updated."
    ui_pause
}

_settings_update_timer() {
    clear

    local current_seconds
    current_seconds=$(config_get COOLDOWN_SECONDS)
    current_seconds=${current_seconds:-86400}
    local current_human
    current_human=$(format_duration_long "$current_seconds")

    echo "  Current cooldown timer: ${current_human}"
    ui_info "You can make it longer, but never shorter."
    echo ""

    local choice
    if ! choice=$(ui_choose "How long should the wait be?" \
        "15 min" \
        "30 min" \
        "1 hour" \
        "3 hours" \
        "6 hours" \
        "12 hours" \
        "24 hours" \
        "48 hours" \
        "← Cancel"); then
        return
    fi

    [[ "$choice" == "← Cancel" || -z "$choice" ]] && return

    local new_seconds
    case "$choice" in
        "15 min")   new_seconds=900 ;;
        "30 min")   new_seconds=1800 ;;
        "1 hour")   new_seconds=3600 ;;
        "3 hours")  new_seconds=10800 ;;
        "6 hours")  new_seconds=21600 ;;
        "12 hours") new_seconds=43200 ;;
        "24 hours") new_seconds=86400 ;;
        "48 hours") new_seconds=172800 ;;
        *)          return ;;
    esac

    # Cooldown mode has no unlock key, so a decrease can't be gated behind one.
    # The timer is increase-only — the friction can only ever grow.
    if [[ $new_seconds -lt $current_seconds ]]; then
        ui_error "You can only make the timer longer, never shorter."
        ui_pause
        return
    fi

    config_set COOLDOWN_SECONDS "$new_seconds"
    ui_success "Cooldown timer set to $(format_duration_long $new_seconds)."
    ui_pause
}

_settings_remove_policies() {
    clear
    echo "  Lets Chrome, Edge, and other browsers use VPN extensions again."
    ui_info "Unsupported browsers stay blocked. To unblock one, use Block apps."
    ui_warn "Open browsers will quit automatically."

    if ! gate_action "policies" "Unblocking VPN extensions"; then
        ui_pause
        return
    fi

    if ! ui_confirm "Unblock VPN extensions now?"; then
        return
    fi

    echo ""
    if _dns_remove_browser_policies; then
        ui_success "VPN extensions unblocked."
        echo ""
        echo "  Reopen your browser when you're ready."
    fi
    ui_pause
}

_settings_reset_dry_run() {
    clear

    echo "  This clears everything and re-seeds from data files."
    if ! ui_confirm "Reset all dry-run state?"; then
        return
    fi

    reset_dry_run_state
    ui_success "Dry-run state reset. Onboarding will run on next launch."
    ui_info "Exiting now. Run './blockdown --dry-run' again."
    exit 0
}

_settings_uninstall() {
    clear
    echo "  This removes Blockdown from your Mac completely: the web filter,"
    echo "  blocked websites and apps, and everything else it set up."

    if ! gate_action "uninstall" "Uninstalling Blockdown"; then
        ui_pause
        return
    fi

    if ! ui_confirm "Uninstall Blockdown now?"; then
        return
    fi

    echo ""
    # Part 2 item D — teardown runs through the hidden libexec bundle: mint a
    # short-lived token, then invoke reconcile (which validates + consumes it).
    # We never call `sudo blockdown uninstall` directly. Falls back to running the
    # reconcile script straight from a dev clone when the bundle isn't installed
    # (testing marker is present in that case, so reconcile authorizes anyway).
    #
    # Blockdown (no lock-in) authorization is the root-owned .bd-edition marker —
    # not user config. Config can say Blockdown while the marker is missing (failed
    # onboarding write); trusting config alone would skip the token and then fail
    # inside reconcile, or worse, let a config edit bypass a Max gate.
    local mint="${BLOCKDOWN_LIBEXEC}/mint-teardown-token"
    local reconcile="${BLOCKDOWN_LIBEXEC}/reconcile"
    local edition_marker="/Library/Application Support/.cache/.bd-edition"
    local system_lite=false
    if [[ -f "$edition_marker" && "$(cat "$edition_marker" 2>/dev/null)" == "lite" ]]; then
        system_lite=true
    fi
    if [[ "$(edition)" == "lite" && "$system_lite" != "true" && "$DRY_RUN" != "true" ]]; then
        ui_error "Blockdown was selected but the system edition marker is missing."
        ui_info "Fix with: sudo bash ${BLOCKDOWN_SCRIPT_DIR}/set-edition.sh blockdown"
        ui_info "Then try Uninstall again."
        ui_pause
        return
    fi
    if [[ "$system_lite" == "true" && "$DRY_RUN" != "true" ]]; then
        # Blockdown has no gated teardown — uninstall-all.sh authorizes itself on
        # the edition marker, so run it straight with no token to mint.
        sudo bash "${BLOCKDOWN_SCRIPT_DIR}/uninstall-all.sh"
    elif [[ "$DRY_RUN" == "true" ]]; then
        run_cmd sudo "$mint"
        run_cmd sudo "$reconcile"
    elif [[ -x "$reconcile" && -x "$mint" ]]; then
        sudo "$mint"
        sudo "$reconcile"
    else
        sudo bash "${BLOCKDOWN_SCRIPT_DIR}/uninstall-all.sh"
    fi
    rm -rf "$BLOCKDOWN_STATE_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        ui_success "Uninstall complete (dry run, nothing changed on your Mac)."
        ui_info "Exiting now. Run './blockdown --dry-run' again."
    else
        ui_success "Uninstall complete."
        ui_info "Exiting now. Run './blockdown' to start from scratch."
    fi
    exit 0
}
