#!/bin/bash
# apps.sh — App blocking: add/remove/list apps

screen_apps() {
    while true; do
        clear
        ui_section "Block apps"
        echo ""
        echo "  $(blocked_apps_label)"
        echo ""

        local menu_items=(
            "Block a downloaded app"
            "Block any app"
            "Unblock an app"
            "List blocked apps"
        )
        # Pending removals only exist under the cooldown method.
        [[ "$(unlock_method)" == "cooldown" ]] && menu_items+=("Pending removals")
        menu_items+=("← Back")

        local choice
        choice=$(ui_choose "What would you like to do?" "${menu_items[@]}")

        case "$choice" in
            "Block a downloaded app") _apps_add_from_device ;;
            "Block any app")          _apps_add_by_name ;;
            "Unblock an app")         _apps_remove ;;
            "List blocked apps")      _apps_list ;;
            "Pending removals")       show_pending_status "app" ;;
            "← Back"|"")              return ;;
        esac
    done
}

# Resolve user input to an installed app name when possible (e.g. spotify -> Spotify).
_apps_resolve_name() {
    local input="${1%.app}"
    local -a dirs=(
        "/Applications"
        "$HOME/Applications"
        "$HOME/Downloads"
    )
    local dir app_path name

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r app_path; do
            [[ -n "$app_path" ]] || continue
            [[ -d "$app_path/Contents" ]] || continue
            [[ "$app_path" =~ \.app/.+\.app$ ]] && continue
            if [[ -f "$app_path" ]] && [[ ! -s "$app_path" ]]; then
                continue
            fi
            name="${app_path##*/}"
            name="${name%.app}"
            if _icase_equal "$name" "$input"; then
                echo "$name"
                return 0
            fi
        done < <(find "$dir" -maxdepth 5 -type d -name "*.app" 2>/dev/null)
    done

    echo "$input"
}

# Enumerate installable .app bundles on this Mac (Applications + Downloads).
_apps_scan_installed() {
    local -a dirs=(
        "/Applications"
        "$HOME/Applications"
        "$HOME/Downloads"
    )
    local dir app_path name blocked_list

    blocked_list=$(_app_list)

    for dir in "${dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r app_path; do
            [[ -n "$app_path" ]] || continue
            [[ -d "$app_path/Contents" ]] || continue
            # Skip helper bundles nested inside another .app (e.g. Electron helpers).
            [[ "$app_path" =~ \.app/.+\.app$ ]] && continue
            # Skip 0-byte Blockdown placeholder files.
            if [[ -f "$app_path" ]] && [[ ! -s "$app_path" ]]; then
                continue
            fi
            name="${app_path##*/}"
            name="${name%.app}"
            [[ -n "$name" ]] || continue
            app_is_blocked "$name" "$blocked_list" && continue
            printf '%s\n' "$name"
        done < <(find "$dir" -maxdepth 5 -type d -name "*.app" 2>/dev/null)
    done | sort -fu
}

_apps_add_from_device() {
    local items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(_apps_scan_installed)

    if [[ ${#items[@]} -eq 0 ]]; then
        clear
        ui_info "No apps found in Applications or Downloads."
        ui_info "Use \"Block any app\" to block by name instead."
        ui_pause
        return
    fi

    items+=("← Cancel")

    clear
    local selected
    selected=$(ui_filter "Block a downloaded app" --no-tips "${items[@]}")

    if [[ "$selected" == "← Cancel" ]] || [[ -z "$selected" ]]; then
        return
    fi

    _apps_apply_block "$selected"
}

# Split typed names on spaces; "..." or '...' keep multi-word names together.
# Prints one name per line (app display names never contain newlines).
_apps_parse_names() {
    local input=$1
    local i=0
    local len=${#input}
    local c word="" quote=""

    while ((i < len)); do
        c=${input:i:1}
        i=$((i + 1))
        if [[ -n $quote ]]; then
            if [[ $c == "$quote" ]]; then
                quote=
            else
                word+=$c
            fi
        elif [[ $c == \" || $c == \' ]]; then
            quote=$c
        elif [[ $c == [[:space:]] ]]; then
            if [[ -n $word ]]; then
                printf '%s\n' "$word"
                word=
            fi
        else
            word+=$c
        fi
    done
    [[ -n $word ]] && printf '%s\n' "$word"
}

_apps_add_by_name() {
    clear
    local input
    input=$(ui_input "Enter app name(s) to block (e.g., WhatsApp \"Opera Air\" Discord)" \
        --hint "Put quotes around multi-word names. If a block fails, use the" \
        --hint "exact name from Finder.")
    input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$input" ]]; then
        ui_error "No app name entered."
        ui_pause
        return
    fi

    local parsed=()
    local name
    while IFS= read -r name; do
        [[ -z $name ]] && continue
        parsed+=("$name")
    done < <(_apps_parse_names "$input")

    local to_add=()

    for name in "${parsed[@]}"; do
        name=$(_apps_resolve_name "$name")

        if app_is_blocked "$name"; then
            ui_warn "Already blocked: $name"
            continue
        fi

        to_add+=("$name")
    done

    if ((${#to_add[@]} == 0)); then
        ui_pause
        return
    fi

    _apps_apply_block "${to_add[@]}"
}

_apps_apply_block() {
    local -a to_add=("$@")

    if [[ "$DRY_RUN" == "true" ]]; then
        for name in "${to_add[@]}"; do
            append_state_file "banned-apps.txt" "$name"
        done
    fi
    # Suppress the CLI's own "Added:" listing; we render a single
    # consolidated summary below instead.
    if ! run_cmd sudo blockdown app add "${to_add[@]}" >/dev/null; then
        ui_error "Failed to block apps."
        ui_pause
        return
    fi

    if ((${#to_add[@]} == 1)); then
        ui_success "Blocked: ${to_add[0]}"
        ui_info "If it's open, it will close within 10 seconds."
    else
        ui_success "Blocked $(pluralize "${#to_add[@]}" app):"
        for name in "${to_add[@]}"; do
            echo "  • $name"
        done
        ui_info "If any of these are open, they will close within 10 seconds."
    fi
    ui_pause
}

_apps_remove() {
    local items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(_app_list)

    if [[ ${#items[@]} -eq 0 ]]; then
        clear
        ui_info "No apps are blocked."
        ui_pause
        return
    fi

    items+=("← Cancel")

    clear
    local selected
    selected=$(ui_filter "Select app to unblock" --no-tips "${items[@]}")

    if [[ "$selected" == "← Cancel" ]] || [[ -z "$selected" ]]; then
        return
    fi

    # Returns 1 when a wait starts or the key is wrong; not an error (set -e).
    attempt_removal "app" "$selected" || true
    ui_pause
}

_apps_list() {
    clear
    ui_heading "Blocked apps"
    echo ""
    local items=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && items+=("$line")
    done < <(_app_list)

    if [[ ${#items[@]} -eq 0 ]]; then
        ui_info "No apps are blocked."
        ui_pause
        return
    fi

    local item
    for item in "${items[@]}"; do
        echo "  • $item"
    done
    ui_pause
}
