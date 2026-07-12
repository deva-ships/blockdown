#!/bin/bash
# websites.sh — Website blocking via exact domains (/etc/hosts, Layer 1)

_website_host_domains() {
    if [[ "$DRY_RUN" == "true" ]]; then
        local f="${BLOCKDOWN_STATE_DIR}/blocked-hosts.txt"
        [[ -f "$f" ]] || return 0
        _website_display_items "$f"
    elif _mdsyncd_installed; then
        _blockdown_cli host list 2>/dev/null \
            | grep -vxF "No hosts blocked." \
            | awk 'NF {
                domain = $0
                sub(/^www\./, "", domain)
                if (!seen[domain]++) print domain
            }'
    fi
}

_website_host_contains() {
    local domain="${1#www.}"
    _website_host_domains | grep -Fxq "$domain" 2>/dev/null
}

screen_websites() {
    while true; do
        clear
        ui_section "Block websites"
        echo ""
        echo "  $(blocked_websites_label)"
        echo ""

        local menu_items=(
            "Block a website"
            "Unblock a website"
            "List blocked websites"
        )
        [[ "$(unlock_method)" == "cooldown" ]] && menu_items+=("Pending removals")
        menu_items+=("← Back")

        local choice
        choice=$(ui_choose "What would you like to do?" "${menu_items[@]}")

        case "$choice" in
            "Block a website")        _websites_add ;;
            "Unblock a website")      _websites_remove ;;
            "List blocked websites")  _websites_list ;;
            "Pending removals")       show_pending_status "host" ;;
            "← Back"|"")             return ;;
        esac
    done
}

_website_display_items() {
    local hosts_file="$1"
    [[ -f "$hosts_file" ]] || return 0

    awk 'NF {
        domain = $0
        sub(/^www\./, "", domain)
        if (!seen[domain]++) print domain
    }' "$hosts_file"
}

_websites_add() {
    clear
    local input
    input=$(ui_input "Enter domain(s) to block (e.g., reddit.com x.com facebook.com)")
    input=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$input" ]]; then
        ui_error "No domain entered."
        ui_pause
        return
    fi

    local to_add_hosts=()
    local domain

    for domain in $input; do
        domain="${domain#http://}"
        domain="${domain#https://}"
        domain="${domain%%/*}"
        domain="${domain%%/}"

        if ! validate_domain "$domain"; then
            ui_error "Invalid domain: $domain"
            ui_info "Use a full domain like reddit.com, not a bare keyword."
            continue
        fi

        if _website_host_contains "$domain"; then
            ui_warn "Already blocked: $domain"
            continue
        fi
        to_add_hosts+=("$domain")
    done

    if ((${#to_add_hosts[@]} == 0)); then
        ui_pause
        return
    fi

    local d
    local added=()
    local failed=()
    for d in "${to_add_hosts[@]}"; do
        if [[ "$DRY_RUN" == "true" ]]; then
            append_state_file "blocked-hosts.txt" "$d"
        fi
        # Suppress the CLI's own per-domain "Added:"/"Takes effect…" chatter;
        # we render a single consolidated summary below instead.
        if run_cmd sudo blockdown host add "$d" >/dev/null; then
            added+=("$d")
        else
            failed+=("$d")
        fi
    done

    if ((${#added[@]} == 1)); then
        ui_success "Blocked: ${added[0]}"
    elif ((${#added[@]} > 1)); then
        ui_success "Blocked $(pluralize "${#added[@]}" website):"
        for d in "${added[@]}"; do
            echo "  • $d"
        done
    fi

    if ((${#failed[@]} > 0)); then
        ui_error "Failed to block $(pluralize "${#failed[@]}" website):"
        for d in "${failed[@]}"; do
            echo "  • $d"
        done
    fi

    if ((${#added[@]} > 0)); then
        ui_info "Takes effect immediately in most apps. Browsers may take up to a minute to catch up."
    fi
    ui_pause
}

_websites_remove() {
    local items=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        items+=("$line")
    done < <(_website_host_domains)

    if [[ ${#items[@]} -eq 0 ]]; then
        clear
        ui_info "No websites are blocked."
        ui_pause
        return
    fi

    items+=("← Cancel")

    clear
    local selected
    selected=$(ui_filter "Select domain to unblock" --no-tips "${items[@]}")

    if [[ "$selected" == "← Cancel" ]] || [[ -z "$selected" ]]; then
        return
    fi

    selected=$(echo "$selected" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Returns 1 when a wait starts or the key is wrong; not an error (set -e).
    attempt_removal "host" "$selected" || true
    ui_pause
}

_websites_list() {
    clear
    ui_heading "Blocked websites"
    echo ""
    local host_items=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] && host_items+=("$line")
    done < <(_website_host_domains)

    if [[ ${#host_items[@]} -eq 0 ]]; then
        ui_info "No websites are blocked."
        ui_pause
        return
    fi

    local item
    for item in "${host_items[@]}"; do
        echo "  • $item"
    done
    ui_pause
}
