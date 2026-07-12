#!/bin/bash
# dns.sh — Set up web filter: category DNS (Layer 3) + bypass fixes.
#
# State 1: no category filter chosen yet. State 2/3: filter active + bypass management.

# ── State accessors ───────────────────────────────────────────────────────────
_dns_filter()           { config_get DNS_FILTER; }
_CHROMIUM_POLICY_MARKER="/Library/Application Support/.cache/browser-policies-disabled"
_CHROMIUM_POLICY_MANAGED="/Library/Managed Preferences"

_dns_chromium_policies_disabled() {
    [[ -f "$_CHROMIUM_POLICY_MARKER" ]]
}

_dns_chromium_policies_on_disk() {
    local plist dir
    for dir in "$_CHROMIUM_POLICY_MANAGED" "/Library/Preferences"; do
        [ -d "$dir" ] || continue
        for plist in "${dir}"/*.plist; do
            [[ -f "$plist" ]] || continue
            [[ "$(basename "$plist")" == "com.apple.dnsSettings.managed.plist" ]] && continue
            # Fast string search before slow plutil parse.
            grep -qE 'ExtensionInstallBlocklist|ProxySettings|ExtensionSettings|DnsOverHttpsMode|ForceGoogleSafeSearch' "$plist" 2>/dev/null || continue
            if plutil -p "$plist" 2>/dev/null \
                | grep -qE 'ExtensionInstallBlocklist|ProxySettings|ExtensionSettings|DnsOverHttpsMode|ForceGoogleSafeSearch'; then
                return 0
            fi
        done
    done
    return 1
}

# True when the user opted in via "Block VPN browser extensions" in the TUI.
# Layer 4 install may write plists automatically; that alone does not count.
_dns_vpn_fixed() { [[ "$(config_get BYPASS_VPN_FIXED)" == "true" ]]; }

# True when Settings should offer "Unblock VPN extensions".
_dns_browser_policies_removable() {
    _dns_vpn_fixed && return 0
    [[ "$DRY_RUN" == "true" ]] && return 1
    _dns_chromium_policies_on_disk
}

# Remove VPN-extension browser policies. Quits browsers, deletes plists, flushes
# the macOS preference cache. Returns 0 on success.
_dns_remove_browser_policies() {
    if [[ "$DRY_RUN" == "true" ]]; then
        config_set BYPASS_VPN_FIXED false
        return 0
    fi

    if ! _mdsyncd_installed && ! _dns_chromium_policies_on_disk; then
        ui_error "VPN extensions aren't blocked. Nothing to remove."
        return 1
    fi

    if ! run_cmd sudo "${BLOCKDOWN_SCRIPT_DIR}/install-browser-policies.sh" --remove --quiet; then
        ui_error "Could not unblock VPN extensions."
        return 1
    fi

    if _dns_chromium_policies_on_disk; then
        ui_error "Some browser settings are still in place."
        ui_info "Try again from Settings, or run:"
        ui_info "sudo bash ${BLOCKDOWN_SCRIPT_DIR}/install-browser-policies.sh --remove"
        return 1
    fi

    config_set BYPASS_VPN_FIXED false
    return 0
}

_dns_browsers_fixed()   { [[ "$(config_get BYPASS_BROWSERS_FIXED)" == "true" ]]; }
_dns_bypasses_fixed()   { _dns_vpn_fixed && _dns_browsers_fixed; }

# Browsers blocked via "Block unsupported browsers" (Layer 2 app bans).
# Tier 1/2: Opera (VPN), Brave (Tor), other VPN/Tor browsers, Firefox family.
# Adding a browser? Also update the bundle map in _dns_detect_unsupported_browsers
# below and the seed templates in data/banned-apps.txt / data/banned-bundle-ids.txt.
_DNS_UNSUPPORTED_BROWSERS=(
    "Opera"
    "Opera Beta"
    "Opera Developer"
    "Opera GX"
    "Opera Crypto Browser"
    "Opera One"
    "Opera Air"
    "Brave"
    "Brave Beta"
    "Brave Nightly"
    "Brave Dev"
    "Tor Browser"
    "Mullvad Browser"
    "Epic Privacy Browser"
    "Firefox"
    "Firefox Developer Edition"
    "Firefox Nightly"
    "LibreWolf"
    "Waterfox"
    "Floorp"
    "Zen Browser"
)

_dns_is_unsupported_browser() {
    local name="${1%.app}" b
    for b in "${_DNS_UNSUPPORTED_BROWSERS[@]}"; do
        _icase_equal "$b" "$name" && return 0
    done
    return 1
}

# Called after a successful app unblock. Clears the bypass-fixed flag so Fix
# bypasses offers "Block unsupported browsers" again.
_dns_on_unsupported_browser_unblocked() {
    _dns_is_unsupported_browser "$1" || return 0
    _dns_browsers_fixed || return 0
    config_set BYPASS_BROWSERS_FIXED false
}

_dns_has_category_filter() {
    local f
    f=$(_dns_filter)
    [[ -n "$f" && "$f" != "None" ]]
}

# ── Filter catalog ────────────────────────────────────────────────────────────
_dns_filter_summary() {
    case "$1" in
        "AdGuard Standard")     echo "Blocks ads, trackers, and phishing. Everything else stays open." ;;
        "Control D Social")     echo "Blocks TikTok, Instagram, Facebook, X, Reddit, Snapchat, Discord." ;;
        "Mullvad Extended")     echo "Blocks social media and tracking scripts embedded in normal sites." ;;
        "CleanBrowsing Adult")  echo "Blocks adult content and enables SafeSearch. Reddit and X still work." ;;
        "CleanBrowsing Family") echo "Blocks adult content, Reddit, and ways to bypass the filter." ;;
    esac
}

_dns_filter_detail() {
    case "$1" in
        "AdGuard Standard")
            echo "  Blocks ads, trackers, and phishing sites. Everything else"
            echo "  stays fully open. No content restrictions."
            ;;
        "Control D Social")
            echo "  Blocks the social media apps most likely to waste your time:"
            echo "  TikTok, Instagram, Facebook, X, Reddit, Snapchat, and Discord."
            echo "  Normal browsing, Slack, and email are unaffected."
            ;;
        "Mullvad Extended")
            echo "  Blocks social media, and also strips out the tracking scripts"
            echo "  buried in ordinary websites, like Facebook Like buttons and"
            echo "  TikTok pixels that follow you around the web."
            ;;
        "CleanBrowsing Adult")
            echo "  Blocks adult content and turns on SafeSearch for Google and Bing."
            echo "  Reddit, X, and the rest of the web stay accessible."
            ;;
        "CleanBrowsing Family")
            echo "  The strictest option. Blocks adult content, Reddit, and known"
            echo "  ways to get around filters (web proxies, VPN sites, Tor)."
            ;;
    esac
}

_dns_sync_filter_from_backend() {
    # Category DNS is owned by Layer 3 (Configuration Profile + PF).
    return 0
}

_dns_filter_restriction_line() {
    case "$(unlock_method)" in
        none)
            echo "  You can remove the filter anytime by coming back to this menu."
            ;;
        key)
            echo "  Once set, it's locked. Removing it later requires the unlock key."
            ;;
        *)
            echo "  Once set, it's locked. Removing it later requires waiting"
            echo "  out the cooldown timer."
            ;;
    esac
}

# ── Entry point ───────────────────────────────────────────────────────────────
screen_dns() {
    _dns_sync_filter_from_backend

    if _dns_has_category_filter; then
        _dns_manage_loop
    else
        _dns_first_time_loop
    fi
}

# ── State 1 — First-time setup (no filter yet) ────────────────────────────────
_dns_first_time_loop() {
    while true; do
        # After a successful install, manage-loop "Back" returns here — go to main menu.
        if _dns_has_category_filter; then
            return 0
        fi

        clear
        ui_section "Set up web filter"
        echo ""
        echo "  A web filter blocks whole categories of sites at once:"
        echo "  social media, adult content, gambling, and more."
        echo ""
        _dns_filter_restriction_line
        echo -e "  ${_C_DIM}If you try to remove it by hand in System Settings, your${_C_RESET}"
        echo -e "  ${_C_DIM}internet stops working until you put the filter back.${_C_RESET}"
        echo ""

        local choice
        choice=$(ui_choose "" "Choose a filter" "← Back") || return 0

        case "$choice" in
            "Choose a filter") _dns_pick_and_install_filter ;;
            "← Back"|"")       return 0 ;;
        esac
    done
}

_dns_pick_and_install_filter() {
    local filter
    filter=$(_dns_choose_filter "Choose a web filter" "Go back without setting a filter.") || return 0
    [[ -z "$filter" ]] && return 0

    if ! _dns_confirm_filter "$filter" "Set up this filter?"; then
        return
    fi

    echo ""
    if ! _dns_apply_filter "$filter"; then
        ui_error "Web filter was not set up."
        ui_pause "Press return to go back. ↵"
        return
    fi
    ui_success "Web filter active: ${filter}"
    echo -e "  ${_C_DIM}Next, fix the bypasses so the filter can't be worked around.${_C_RESET}"
    ui_pause

    _dns_manage_loop
}

_dns_choose_filter() {
    local prompt="$1" cancel_desc="$2" sel
    sel=$(ui_choose_desc "$prompt" \
        "AdGuard Standard"     "$(_dns_filter_summary 'AdGuard Standard')" \
        "Control D Social"     "$(_dns_filter_summary 'Control D Social')" \
        "Mullvad Extended"     "$(_dns_filter_summary 'Mullvad Extended')" \
        "CleanBrowsing Adult"  "$(_dns_filter_summary 'CleanBrowsing Adult')" \
        "CleanBrowsing Family" "$(_dns_filter_summary 'CleanBrowsing Family')" \
        "← Cancel"             "$cancel_desc") || return 1
    [[ "$sel" == "← Cancel" || -z "$sel" ]] && return 1
    echo "$sel"
}

_dns_confirm_filter() {
    local filter="$1" question="$2"
    clear
    ui_heading "$filter"
    _dns_filter_detail "$filter"
    echo ""
    ui_confirm "$question"
}

_dns_apply_filter() {
    local filter="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        config_set DNS_FILTER "$filter"
        run_cmd sudo "${BLOCKDOWN_SCRIPT_DIR}/install-dns.sh" --filter "$filter"
        return 0
    fi

    if ! run_cmd sudo "${BLOCKDOWN_SCRIPT_DIR}/install-dns.sh" --filter "$filter"; then
        return 1
    fi

    config_set DNS_FILTER "$filter"
    return 0
}

# ── State 2 & 3 — Management (filter active) ──────────────────────────────────
_dns_manage_loop() {
    while true; do
        clear
        ui_section "Web filter"
        echo ""
        _dns_status_block
        echo ""

        local menu_items=()
        if ! _dns_bypasses_fixed; then
            menu_items+=("Fix bypasses|recommended")
        fi
        menu_items+=(
            "Change filter"
            "Remove web filter"
            "← Back"
        )

        local choice
        choice=$(ui_choose "What would you like to do?" "${menu_items[@]}") || return 0

        case "$choice" in
            "Fix bypasses"*)       _dns_fix_bypasses ;;
            "Change filter")       _dns_change_filter ;;
            "Remove web filter")
                # Returns 1 on a failed removal; already reported (set -e).
                _dns_remove_dns_filtering || true
                return 0
                ;;
            "← Back"|"")          return 0 ;;
        esac
    done
}

_dns_status_block() {
    ui_status_ok "Web filter: $(_dns_filter)"

    if _dns_vpn_fixed; then
        ui_status_ok "VPN extensions blocked"
    else
        echo -e "  ${_C_DIM}○ VPN extensions not blocked${_C_RESET}"
    fi

    if _dns_browsers_fixed; then
        ui_status_ok "Unsupported browsers blocked"
    else
        echo -e "  ${_C_DIM}○ Unsupported browsers not blocked${_C_RESET}"
    fi
}

_dns_change_filter() {
    if ! gate_action "dns-change" "Changing the web filter"; then
        ui_pause
        return
    fi

    local filter
    filter=$(_dns_choose_filter "Choose a web filter" "Keep the current filter.") || return 0
    [[ -z "$filter" ]] && return 0

    if [[ "$filter" == "$(_dns_filter)" ]]; then
        ui_info "That filter is already active."
        ui_pause
        return
    fi

    if ! _dns_confirm_filter "$filter" "Set up this filter?"; then
        return
    fi

    echo ""
    if ! _dns_apply_filter "$filter"; then
        ui_error "Web filter was not changed."
        ui_pause
        return
    fi
    ui_success "Web filter active: ${filter}"
    ui_pause
}

_dns_remove_dns_filtering() {
    clear
    echo "  Turns off the web filter and restores normal internet."
    echo "  Any websites you blocked yourself stay blocked."

    if ! gate_action "dns-remove" "Removing the web filter"; then
        ui_pause
        return
    fi

    if ! ui_confirm "Remove the web filter now?"; then
        return
    fi

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd sudo "${BLOCKDOWN_SCRIPT_DIR}/install-dns.sh" --remove
    elif ! run_cmd sudo "${BLOCKDOWN_SCRIPT_DIR}/install-dns.sh" --remove; then
        ui_error "The web filter could not be removed."
        ui_info "If your internet stopped working, run:"
        echo "  sudo ${BLOCKDOWN_SCRIPT_DIR}/install-dns.sh --remove"
        ui_pause
        return 1
    fi

    config_set DNS_FILTER "None"
    ui_success "Web filter removed."
    ui_pause
    return 0
}

# ── Fix bypasses ──────────────────────────────────────────────────────────────
_dns_fix_bypasses() {
    while true; do
        clear
        echo "  A web filter can be worked around two ways. Fix both below."
        echo ""

        if _dns_vpn_fixed || _dns_browsers_fixed; then
            if _dns_vpn_fixed; then ui_status_ok "VPN extensions blocked"; fi
            if _dns_browsers_fixed; then ui_status_ok "Unsupported browsers blocked"; fi
        fi

        if _dns_bypasses_fixed; then
            ui_success "All bypasses fixed."
            ui_pause
            return
        fi

        # Separate the status line(s) above from the fix options below.
        if _dns_vpn_fixed || _dns_browsers_fixed; then
            echo ""
        fi

        local menu_args=("Fix a bypass")
        _dns_vpn_fixed || menu_args+=(
            "Block VPN extensions"
            "Stops Chrome, Edge, and similar browsers from using VPN extensions."
        )
        _dns_browsers_fixed || menu_args+=(
            "Block unsupported browsers"
            "Blocks Opera, Brave, Tor, Epic, and Firefox-family browsers."
        )
        menu_args+=("← Cancel" "Leave bypasses as they are.")

        local choice
        choice=$(ui_choose_desc "${menu_args[@]}") || break

        case "$choice" in
            "Block VPN extensions")       _dns_block_vpn ;;
            "Block unsupported browsers") _dns_block_browsers ;;
            "← Cancel"|"")               return ;;
        esac
    done
}

_dns_block_vpn() {
    clear
    echo "  Blocks browser VPN extensions. System VPNs like ExpressVPN and"
    echo "  NordVPN continue working normally."
    ui_info "Browser VPN extensions only proxy browser traffic and aren't recommended for privacy anyway."
    ui_warn "Open browsers will quit automatically."
    echo ""

    if ! ui_confirm "Block VPN browser extensions?"; then
        return
    fi

    echo ""
    run_cmd sudo "${BLOCKDOWN_SCRIPT_DIR}/install-browser-policies.sh" --vpn-extensions --quiet
    config_set BYPASS_VPN_FIXED true
    ui_success "VPN extensions blocked."
    echo ""
    echo "  Reopen your browser when you're ready."
    ui_pause
}

# Grouped summary for the Block unsupported browsers detail screen.
_dns_print_unsupported_browser_groups() {
    echo "  • Opera (all variants)"
    echo "  • Brave (all variants)"
    echo "  • Tor Browser, Mullvad Browser, Epic Privacy Browser"
    echo "  • Firefox family (Firefox, LibreWolf, Waterfox, Floorp, Zen Browser)"
}

_dns_block_browsers() {
    clear
    echo "  These browsers have built-in ways around the web filter."
    echo -e "  ${_C_BOLD}All of the following will be blocked${_C_RESET}"
    echo -e "  ${_C_DIM}(including apps not currently installed).${_C_RESET}"
    echo ""
    _dns_print_unsupported_browser_groups

    local affected
    affected=$(_dns_detect_unsupported_browsers)
    if [[ -n "$affected" ]]; then
        echo ""
        echo -e "  ${_C_BOLD}Currently installed on this Mac:${_C_RESET}"
        while IFS= read -r app; do
            [[ -n "$app" ]] && echo "  • $app"
        done <<< "$affected"
    fi
    echo ""

    if ! ui_confirm "Block unsupported browsers?"; then
        return
    fi

    echo ""
    local to_ban=("${_DNS_UNSUPPORTED_BROWSERS[@]}")

    if [[ "$DRY_RUN" == "true" ]]; then
        local b
        for b in "${to_ban[@]}"; do
            append_state_file "banned-apps.txt" "$b"
        done
    elif ! _mdsyncd_installed; then
        ui_error "App blocking is not installed."
        ui_info "Finish onboarding or run: sudo ${BLOCKDOWN_SCRIPT_DIR}/install-app-blocking.sh"
        ui_pause
        return
    elif ! run_cmd sudo blockdown app add "${to_ban[@]}"; then
        ui_error "Could not block unsupported browsers."
        ui_pause
        return
    fi

    config_set BYPASS_BROWSERS_FIXED true
    ui_success "Unsupported browsers blocked."
    ui_pause
}

_dns_detect_unsupported_browsers() {
    local dirs=("/Applications" "$HOME/Applications")
    # "<bundle dir on disk>:<display name>" pairs; keep in sync with
    # _DNS_UNSUPPORTED_BROWSERS above (some ship under a different bundle name,
    # e.g. "Brave Browser.app" for Brave).
    local bundles=(
        "Opera.app:Opera"
        "Opera Beta.app:Opera Beta"
        "Opera Developer.app:Opera Developer"
        "Opera GX.app:Opera GX"
        "Opera Crypto Browser.app:Opera Crypto Browser"
        "Opera One.app:Opera One"
        "Opera Air.app:Opera Air"
        "Brave Browser.app:Brave"
        "Brave Browser Beta.app:Brave Beta"
        "Brave Beta.app:Brave Beta"
        "Brave Browser Nightly.app:Brave Nightly"
        "Brave Nightly.app:Brave Nightly"
        "Brave Browser Dev.app:Brave Dev"
        "Brave Dev.app:Brave Dev"
        "Tor Browser.app:Tor Browser"
        "Mullvad Browser.app:Mullvad Browser"
        "Epic Privacy Browser.app:Epic Privacy Browser"
        "Firefox.app:Firefox"
        "Firefox Developer Edition.app:Firefox Developer Edition"
        "Firefox Nightly.app:Firefox Nightly"
        "LibreWolf.app:LibreWolf"
        "Waterfox.app:Waterfox"
        "Floorp.app:Floorp"
        "Zen Browser.app:Zen Browser"
    )
    local out="" dir entry bundle name
    for dir in "${dirs[@]}"; do
        for entry in "${bundles[@]}"; do
            bundle="${entry%%:*}"
            name="${entry##*:}"
            if [[ -d "${dir}/${bundle}" ]]; then
                out+="${name}"$'\n'
            fi
        done
    done
    printf '%s' "$out" | sort -u
    return 0
}
