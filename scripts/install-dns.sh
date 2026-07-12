#!/usr/bin/env bash
# =============================================================================
# install-dns.sh — Layer 3 DNS enforcement installer
#
# Installs the CleanBrowsing DNS Configuration Profile and PF anchor rules
# that enforce DNS filtering system-wide, regardless of browser or app.
#
# Item 0: creates the recoverable testing marker (.bd-testing) at install start.
# Item B: seeds schg-locked self-heal backups of the PF plist + profile watcher
#         (worker + plist) for cyclic cross-supervision.
#
# Usage: sudo ./scripts/install-dns.sh
# Requires: macOS 14+, must be run as root (sudo)
# =============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run with sudo." >&2
    echo "  sudo ./scripts/install-dns.sh" >&2
    exit 1
fi

# Capture the actual (non-root) user who invoked sudo for file ownership tasks
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
DNSRULED="/Library/PrivilegedHelperTools/com.apple.networkd-helper/bin/dnsruled"

# ── Where profiles live in System Settings (moved in macOS 15) ──────────────────
# macOS 13–14 (Ventura/Sonoma): Privacy & Security > Profiles.
# macOS 15+ (Sequoia/Tahoe): the pane was renamed and moved to General >
# Device Management. Pick the labels that match the running OS so the steps the
# user reads match what they actually see.
MACOS_MAJOR="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
if [[ "${MACOS_MAJOR:-0}" -ge 15 ]]; then
    PROFILE_PANE_TOP="General"
    PROFILE_PANE_SUB="Device Management"
else
    PROFILE_PANE_TOP="Privacy & Security"
    PROFILE_PANE_SUB="Profiles"
fi

# ── Progress output ───────────────────────────────────────────────────────────
# The user sees one "working" state and the final result. Every internal step
# is appended to a log file, and shown on screen only with --verbose.
VERBOSE="${BLOCKDOWN_VERBOSE:-0}"
LOG_DIR="/Library/Logs/Blockdown"
LOG_FILE="${LOG_DIR}/install-dns.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {  # internal step detail: log file always, screen only when verbose
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
    [[ "$VERBOSE" == "1" ]] && echo "  $*"
    return 0
}
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; }
cleanup_desktop_profile_copy() {
    local user="${1:-$REAL_USER}"
    [[ -n "$user" && "$user" != "root" ]] || return 0
    rm -f "/Users/${user}/Desktop/dns-filter.mobileconfig"
    rm -f "/Users/${user}/Desktop/blockdown-dns.mobileconfig"
}

list_network_services() {
    networksetup -listallnetworkservices 2>/dev/null \
        | tail -n +2 \
        | grep -v '^\*' \
        | grep -v '^An asterisk' || true
}

remove_layer1_dns() {
    log "Removing Layer 3 DNS enforcement."

    chflags noschg /etc/pf.anchors/dns-filter 2>/dev/null || true
    chflags noschg /Library/LaunchDaemons/com.dnsfilter.pf.plist 2>/dev/null || true
    chflags noschg /Library/PrivilegedHelperTools/dns-filter.mobileconfig 2>/dev/null || true
    chflags noschg /usr/local/sbin/dns-profile-watcher 2>/dev/null || true
    chflags noschg /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist 2>/dev/null || true

    launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist 2>/dev/null || true
    launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.pf.plist 2>/dev/null || true

    rm -f /etc/pf.anchors/dns-filter
    rm -f /Library/LaunchDaemons/com.dnsfilter.pf.plist
    rm -f /Library/PrivilegedHelperTools/dns-filter.mobileconfig
    rm -f /usr/local/sbin/dns-profile-watcher
    rm -f /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist

    sed -i '' '/rdr-anchor "dns-filter"/d' /etc/pf.conf 2>/dev/null || true
    sed -i '' '/^anchor "dns-filter"/d' /etc/pf.conf 2>/dev/null || true
    sed -i '' '/load anchor "dns-filter"/d' /etc/pf.conf 2>/dev/null || true

    pfctl -f /etc/pf.conf 2>/dev/null || true

    if grep -q "# BLOCKER-MANAGED-START" /etc/hosts 2>/dev/null; then
        chflags noschg /etc/hosts 2>/dev/null || true
        awk -v s="# BLOCKER-MANAGED-START" -v e="# BLOCKER-MANAGED-END" '
            $0 == s { inside = 1; next }
            $0 == e { inside = 0; next }
            !inside { print }
        ' /etc/hosts > /tmp/hosts.clean
        cat /tmp/hosts.clean > /etc/hosts
        rm -f /tmp/hosts.clean
    fi

    local existing_profiles profile_id service
    existing_profiles=$(profiles list -all 2>/dev/null | grep -oE '(com\.cleanbrowsing\.dns|io\.nextdns\.custom|com\.cloudflare\.dns|com\.adguard\.dns|com\.controld\.dns|net\.mullvad\.dns)\.[a-zA-Z0-9._-]+' | sort -u || true)
    if [[ -n "$existing_profiles" ]]; then
        while IFS= read -r profile_id; do
            [[ -n "$profile_id" ]] || continue
            profiles remove -identifier "$profile_id" 2>/dev/null || true
        done <<< "$existing_profiles"
    fi

    rm -f "/Users/${REAL_USER}/Library/Application Support/Blockdown/dns-filter.mobileconfig"
    rm -f "/Library/Application Support/Blockdown/dns-filter-open.path"

    # Defensive cleanup for a legacy AdGuard Home DNS stack, if one is still present
    # from an older install. Reset its upstream so it stops interfering.
    if [[ -x "$DNSRULED" ]]; then
        "$DNSRULED" dns filter "None" 2>/dev/null || true
    fi

    cleanup_desktop_profile_copy "${REAL_USER:-}"
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
    log "Removed."
}

log "Layer 3 web filter install started."

# ── Argument parsing ────────────────────────────────────────────────────────
FILTER_ARG=""
IS_REMOVE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            FILTER_ARG="$2"
            shift 2
            ;;
        --remove)
            IS_REMOVE=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ $IS_REMOVE -eq 1 ]]; then
    remove_layer1_dns
    exit 0
fi

# ── Filter selection ──────────────────────────────────────────────────────────
if [[ -n "$FILTER_ARG" ]]; then
    # Map TUI filter names to our internal choice numbers
    case "$FILTER_ARG" in
        "CleanBrowsing Adult")   FILTER_CHOICE=1 ;;
        "CleanBrowsing Family")  FILTER_CHOICE=2 ;;
        "Security Filter")       FILTER_CHOICE=3 ;;
        "Cloudflare Families")   FILTER_CHOICE=4 ;;
        "NextDNS Custom")        FILTER_CHOICE=5 ;;
        "AdGuard Standard")      FILTER_CHOICE=6 ;;
        "Control D Social")      FILTER_CHOICE=7 ;;
        "Mullvad Extended")      FILTER_CHOICE=8 ;;
        # Default fallbacks
        *)                       FILTER_CHOICE=1 ;;
    esac
else
    # Interactive menu mirrors the five filters offered by the TUI
    # ("Set up web filter"). Other upstreams remain reachable via --filter.
    echo "Select a web filter:"
    echo ""
    echo "  1) AdGuard Standard"
    echo "     Blocks ads, trackers, and phishing. Everything else stays open."
    echo ""
    echo "  2) Control D Social"
    echo "     Blocks TikTok, Instagram, Facebook, X, Reddit, Snapchat, Discord."
    echo ""
    echo "  3) Mullvad Extended"
    echo "     Blocks social media plus tracking scripts embedded in normal sites."
    echo ""
    echo "  4) CleanBrowsing Adult   (default)"
    echo "     Blocks adult content and enables SafeSearch. Reddit and X still work."
    echo ""
    echo "  5) CleanBrowsing Family  (strictest)"
    echo "     Blocks adult content, Reddit, and known filter-bypass methods."
    echo ""
    read -rp "Enter choice [1-5, default 4]: " MENU_CHOICE
    echo ""
    # Translate the menu position into the internal filter-choice numbers used below.
    case "${MENU_CHOICE:-4}" in
        1) FILTER_CHOICE=6 ;;   # AdGuard Standard
        2) FILTER_CHOICE=7 ;;   # Control D Social
        3) FILTER_CHOICE=8 ;;   # Mullvad Extended
        4) FILTER_CHOICE=1 ;;   # CleanBrowsing Adult
        5) FILTER_CHOICE=2 ;;   # CleanBrowsing Family
        *) FILTER_CHOICE=1 ;;
    esac
fi

case "${FILTER_CHOICE:-1}" in
    2)
        FILTER_NAME="CleanBrowsing Family Filter"
        FILTER_SLUG="family"
        CB_IPV4_PRIMARY="185.228.168.168"
        CB_IPV4_SECONDARY="185.228.169.168"
        CB_DOH_URL="https://doh.cleanbrowsing.org/doh/family-filter/"
        CB_PROFILE_ID="com.cleanbrowsing.dns.family"
        ;;
    3)
        FILTER_NAME="CleanBrowsing Security Filter"
        FILTER_SLUG="security"
        CB_IPV4_PRIMARY="185.228.168.9"
        CB_IPV4_SECONDARY="185.228.169.9"
        CB_DOH_URL="https://doh.cleanbrowsing.org/doh/security-filter/"
        CB_PROFILE_ID="com.cleanbrowsing.dns.security"
        ;;
    4)
        FILTER_NAME="Cloudflare Families"
        FILTER_SLUG="cloudflare"
        # 1.0.0.3 is listed first: some ISPs (e.g. Jio in India) black-hole the
        # 1.1.1.x range, and macOS gets stuck on an unreachable primary.
        CB_IPV4_PRIMARY="1.0.0.3"
        CB_IPV4_SECONDARY="1.1.1.3"
        CB_DOH_URL="https://family.cloudflare-dns.com/dns-query"
        CB_PROFILE_ID="com.cloudflare.dns.families"
        ;;
    5)
        read -rp "Enter your NextDNS Configuration ID (e.g., abcdef): " NEXTDNS_ID
        if [[ -z "$NEXTDNS_ID" ]]; then
            echo "Error: NextDNS ID is required." >&2
            exit 1
        fi
        FILTER_NAME="NextDNS Custom"
        FILTER_SLUG="nextdns"
        CB_IPV4_PRIMARY="45.90.28.0"
        CB_IPV4_SECONDARY="45.90.30.0"
        CB_DOH_URL="https://dns.nextdns.io/${NEXTDNS_ID}"
        CB_PROFILE_ID="io.nextdns.custom.profile"
        ;;
    6)
        FILTER_NAME="AdGuard Standard"
        FILTER_SLUG="adguard"
        CB_IPV4_PRIMARY="94.140.14.14"
        CB_IPV4_SECONDARY="94.140.15.15"
        CB_DOH_URL="https://dns.adguard-dns.com/dns-query"
        CB_PROFILE_ID="com.adguard.dns.standard"
        ;;
    7)
        FILTER_NAME="Control D Social"
        FILTER_SLUG="controld"
        CB_IPV4_PRIMARY="76.76.2.3"
        CB_IPV4_SECONDARY="76.76.10.3"
        CB_DOH_URL="https://freedns.controld.com/p3"
        CB_PROFILE_ID="com.controld.dns.social"
        ;;
    8)
        FILTER_NAME="Mullvad Extended"
        FILTER_SLUG="mullvad"
        CB_IPV4_PRIMARY="194.242.2.5"
        CB_IPV4_SECONDARY="194.242.2.5"
        CB_DOH_URL="https://extended.dns.mullvad.net/dns-query"
        CB_PROFILE_ID="net.mullvad.dns.extended"
        ;;
    *)
        FILTER_NAME="CleanBrowsing Adult Filter"
        FILTER_SLUG="adult"
        CB_IPV4_PRIMARY="185.228.168.10"
        CB_IPV4_SECONDARY="185.228.169.11"
        CB_DOH_URL="https://doh.cleanbrowsing.org/doh/adult-filter/"
        CB_PROFILE_ID="com.cleanbrowsing.dns.profile"
        ;;
esac

echo ""
echo "  Setting up the web filter (${FILTER_NAME})…"
log "Selected filter: ${FILTER_NAME}"

# ── Helper: unlock a file if it has the schg flag ────────────────────────────
unlock_if_locked() {
    local file="$1"
    if [[ -e "$file" ]]; then
        local flags
        flags=$(ls -lO "$file" 2>/dev/null | awk '{print $5}' || echo "")
        if echo "$flags" | grep -q "schg"; then
            log "Unlocking existing file: $file"
            chflags noschg "$file"
        fi
    fi
}

_sed_regex_escape() {
    printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'
}

carve_out_active_provider() {
    local ip escaped

    # Keep PF from blocking the active profile's own DoH endpoint. The anchor
    # blocks many public DoH providers by IP; when one is selected, its endpoint
    # must be removed from those block rules or the profile can strand DNS.
    for ip in "$CB_IPV4_PRIMARY" "$CB_IPV4_SECONDARY"; do
        [[ -n "$ip" ]] || continue
        escaped=$(_sed_regex_escape "$ip")
        sed -i '' "/^block drop/s/${escaped}, //g" "$ANCHOR_DEST"
        sed -i '' "/^block drop/s/, ${escaped}//g" "$ANCHOR_DEST"
    done

    case "$FILTER_SLUG" in
        nextdns)
            sed -i '' '/45\.90\.28\.0\/24/d' "$ANCHOR_DEST"
            sed -i '' '/45\.90\.30\.0\/24/d' "$ANCHOR_DEST"
            ;;
        cloudflare)
            sed -i '' '/104\.16\.132\.229/d' "$ANCHOR_DEST"
            sed -i '' '/162\.159\.61\.3/d' "$ANCHOR_DEST"
            ;;
        adguard)
            sed -i '' '/94\.140\.14\./d' "$ANCHOR_DEST"
            sed -i '' '/94\.140\.15\./d' "$ANCHOR_DEST"
            ;;
        controld)
            sed -i '' '/76\.76\.2\.11/d' "$ANCHOR_DEST"
            sed -i '' '/76\.76\.21\./d' "$ANCHOR_DEST"
            ;;
        mullvad)
            sed -i '' '/194\.242\.2\./d' "$ANCHOR_DEST"
            ;;
    esac
}

profile_is_installed() {
    profiles list -all 2>/dev/null | grep -qi "$CB_PROFILE_ID"
}

profile_pending_path() {
    echo "/Users/${REAL_USER}/Library/Application Support/Blockdown/dns-filter.mobileconfig"
}

profile_backup_path() {
    echo "/Library/PrivilegedHelperTools/dns-filter.mobileconfig"
}

profile_open_record_path() {
    echo "/Library/Application Support/Blockdown/dns-filter-open.path"
}

_profile_console_user() {
    local console_user="${REAL_USER:-}"
    local from_console
    from_console=$(stat -f%Su /dev/console 2>/dev/null || true)
    if [[ -n "$from_console" && "$from_console" != "root" && "$from_console" != "_mbsetupuser" ]]; then
        console_user="$from_console"
    fi
    if [[ -n "$console_user" && "$console_user" != "root" ]]; then
        echo "$console_user"
    fi
}

_ensure_profile_pending_dir() {
    local pending_dir pending_path user
    pending_path=$(profile_pending_path)
    pending_dir=$(dirname "$pending_path")
    user=$(_profile_console_user) || return 0
    mkdir -p "$pending_dir"
    chown "${user}:staff" "$pending_dir"
    chmod 755 "$pending_dir"
}

_write_dns_mobileconfig() {
    local dest="$1"
    sed \
        -e "s|185\.228\.168\.10|${CB_IPV4_PRIMARY}|g" \
        -e "s|185\.228\.169\.11|${CB_IPV4_SECONDARY}|g" \
        -e "s|https://doh\.cleanbrowsing\.org/doh/adult-filter/|${CB_DOH_URL}|g" \
        -e "s|CleanBrowsing Adult Filter DNS|${FILTER_NAME} DNS|g" \
        -e "s|CleanBrowsing DNS Filter|${FILTER_NAME}|g" \
        -e "s|Routes all DNS through CleanBrowsing Adult Filter|Routes all DNS through ${FILTER_NAME}|g" \
        -e "s|com\.cleanbrowsing\.dns\.profile|${CB_PROFILE_ID}|g" \
        -e "s|b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2|${INNER_UUID}|g" \
        -e "s|a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5|${OUTER_UUID}|g" \
        "${REPO}/files/dns-filter.mobileconfig" > "$dest"
}

_load_or_generate_profile_uuids() {
    local candidate
    for candidate in "$(profile_pending_path)" "$(profile_backup_path)"; do
        if [[ -f "$candidate" ]]; then
            OUTER_UUID=$(/usr/libexec/PlistBuddy -c "Print :PayloadUUID" "$candidate" 2>/dev/null || true)
            INNER_UUID=$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:0:PayloadUUID" "$candidate" 2>/dev/null || true)
            if [[ -n "$OUTER_UUID" && -n "$INNER_UUID" ]]; then
                log "Reusing profile UUIDs from ${candidate}."
                return 0
            fi
        fi
    done

    OUTER_UUID=$(uuidgen)
    INNER_UUID=$(uuidgen)
    log "Generated fresh profile UUIDs."
}

# Downloaded-but-not-installed profiles live in the user session that opened
# them. Root's `profiles remove -user …` still returns CPProfileManager -205.
_remove_downloaded_profile_at_path() {
    local profile_path="$1" removed=1 user uid basename_path
    [[ -n "$profile_path" && -f "$profile_path" ]] || return 0

    chflags noschg "$profile_path" 2>/dev/null || true
    basename_path=$(basename "$profile_path")

    _try_remove_profile() {
        local label="$1"
        shift
        local output
        if output=$("$@" 2>&1); then
            log "Removed downloaded profile via ${label}: ${profile_path}"
            removed=0
            return 0
        fi
        [[ -n "$output" ]] && printf '%s\n' "$output" >> "$LOG_FILE"
        return 1
    }

    user=$(_profile_console_user) || user=""
    if [[ -n "$user" ]]; then
        uid=$(id -u "$user" 2>/dev/null || true)
        _try_remove_profile "user:${user}" \
            sudo -u "$user" /usr/bin/profiles remove -type configuration -path "$profile_path" -forced || true
        _try_remove_profile "user:${user}:basename" \
            sudo -u "$user" /usr/bin/profiles remove -type configuration -path "$basename_path" -forced || true
        if [[ -n "${CB_PROFILE_ID:-}" ]]; then
            _try_remove_profile "user:${user}:identifier" \
                sudo -u "$user" /usr/bin/profiles remove -type configuration -identifier "$CB_PROFILE_ID" -forced || true
        fi
        if [[ -n "${OUTER_UUID:-}" ]]; then
            _try_remove_profile "user:${user}:uuid" \
                sudo -u "$user" /usr/bin/profiles remove -type configuration -uuid "$OUTER_UUID" -forced || true
        fi
        if [[ -n "$uid" ]]; then
            _try_remove_profile "asuser:${user}" \
                launchctl asuser "$uid" /usr/bin/profiles remove -type configuration -path "$profile_path" -forced || true
        fi
    fi

    _try_remove_profile "device:path" \
        /usr/bin/profiles remove -type configuration -path "$profile_path" -forced || true
    _try_remove_profile "device:basename" \
        /usr/bin/profiles remove -type configuration -path "$basename_path" -forced || true
    if [[ -n "${CB_PROFILE_ID:-}" ]]; then
        _try_remove_profile "device:identifier" \
            /usr/bin/profiles remove -type configuration -identifier "$CB_PROFILE_ID" -forced || true
    fi

    return "$removed"
}

# Drop a pending DNS profile queued from the install prompt.
clear_pending_dns_profile() {
    local pending_path backup_path open_record path removed_ok=1 user
    pending_path=$(profile_pending_path)
    backup_path=$(profile_backup_path)
    open_record=$(profile_open_record_path)

    _ensure_profile_pending_dir

    if [[ -f "$open_record" ]]; then
        path=$(sed -n '1p' "$open_record" 2>/dev/null || true)
        OUTER_UUID=$(sed -n '2p' "$open_record" 2>/dev/null || true)
        if [[ -n "$path" && -f "$path" ]] && _remove_downloaded_profile_at_path "$path"; then
            removed_ok=0
        fi
        if [[ -n "${OUTER_UUID:-}" ]]; then
            user=$(_profile_console_user) || user=""
            if [[ -n "$user" ]] && sudo -u "$user" /usr/bin/profiles remove -type configuration -uuid "$OUTER_UUID" -forced >> "$LOG_FILE" 2>&1; then
                log "Removed downloaded profile via saved UUID ${OUTER_UUID}."
                removed_ok=0
            fi
        fi
    fi

    if [[ -f "$pending_path" ]] && _remove_downloaded_profile_at_path "$pending_path"; then
        removed_ok=0
    fi
    if [[ -f "$backup_path" ]] && _remove_downloaded_profile_at_path "$backup_path"; then
        removed_ok=0
    fi

    if [[ "$removed_ok" -eq 0 ]]; then
        rm -f "$pending_path" "$backup_path" "$open_record"
        log "Cleared pending DNS profile files."
    else
        log "Downloaded DNS profile could not be cleared automatically; keeping pending file to avoid duplicates."
    fi

    cleanup_desktop_profile_copy "${REAL_USER:-}"
}

# Drop staged, pending, or installed DNS profiles during rollback.
clear_staged_dns_profile() {
    if [[ -n "${CB_PROFILE_ID:-}" ]]; then
        local user
        user=$(_profile_console_user) || user=""
        if [[ -n "$user" ]]; then
            sudo -u "$user" /usr/bin/profiles remove -type configuration -identifier "$CB_PROFILE_ID" -forced >> "$LOG_FILE" 2>&1 || true
        fi
        profiles remove -type configuration -identifier "$CB_PROFILE_ID" -forced >> "$LOG_FILE" 2>&1 || true
    fi

    clear_pending_dns_profile
}

system_dns_resolves() {
    dscacheutil -q host -a name google.com 2>/dev/null | awk '/^ip_address/ {found=1} END {exit !found}'
}

rollback_dns_enforcement() {
    log "Rolling back DNS enforcement so normal internet access is preserved."
    launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist 2>/dev/null || true
    launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.pf.plist 2>/dev/null || true
    chflags noschg /etc/pf.anchors/dns-filter 2>/dev/null || true
    chflags noschg /Library/LaunchDaemons/com.dnsfilter.pf.plist 2>/dev/null || true
    chflags noschg /usr/local/sbin/dns-profile-watcher 2>/dev/null || true
    chflags noschg /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist 2>/dev/null || true
    rm -f /etc/pf.anchors/dns-filter
    rm -f /Library/LaunchDaemons/com.dnsfilter.pf.plist
    rm -f /usr/local/sbin/dns-profile-watcher
    rm -f /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist
    sed -i '' '/rdr-anchor "dns-filter"/d' /etc/pf.conf 2>/dev/null || true
    sed -i '' '/^anchor "dns-filter"/d' /etc/pf.conf 2>/dev/null || true
    sed -i '' '/load anchor "dns-filter"/d' /etc/pf.conf 2>/dev/null || true
    pfctl -f /etc/pf.conf 2>/dev/null || true
    clear_staged_dns_profile
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
}

# ── Item 0 — Enter recoverable testing mode (transient install lock) ──────────
# Marker present = supervision paused + removal gates bypassable while DNS
# installs, so this standalone install can't be fought by already-armed Layers
# 2/3. It is cleared at exit (any path) by the EXIT trap below, which re-arms
# Max's self-heal + gated teardown (inert for Blockdown). On a failure exit the
# trap fires AFTER rollback, so supervision stays paused while DNS is torn down.
BD_TESTING_MARKER="/Library/Application Support/.cache/.bd-testing"
arm_leave_testing_mode() {
    chflags noschg "$BD_TESTING_MARKER" 2>/dev/null || true
    rm -f "$BD_TESTING_MARKER" 2>/dev/null || true
}
mkdir -p "/Library/Application Support/.cache" 2>/dev/null || true
touch "$BD_TESTING_MARKER" 2>/dev/null || true
chown root:wheel "$BD_TESTING_MARKER" 2>/dev/null || true
chmod 644 "$BD_TESTING_MARKER" 2>/dev/null || true
trap 'arm_leave_testing_mode' EXIT
log "Testing marker present: recoverable mode during install (cleared at exit)."

# Blockdown edition marker (no lock-in). Install the DoH profile + PF rules
# (the web filter still works) but not the profile self-healer, and lock nothing
# with schg. A Blockdown user can remove the profile in System Settings and it
# stays removed.
BD_EDITION_MARKER="/Library/Application Support/.cache/.bd-edition"
bd_is_lite() { [ -f "$BD_EDITION_MARKER" ] && [ "$(cat "$BD_EDITION_MARKER" 2>/dev/null)" = "lite" ]; }

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1: Install the PF anchor
# ═════════════════════════════════════════════════════════════════════════════
log "Step 1/7: Installing PF anchor."

ANCHOR_DEST="/etc/pf.anchors/dns-filter"
unlock_if_locked "$ANCHOR_DEST"

# Adult Filter IPs are the defaults in the source file; substitute for other filters
sed \
    -e "s|185\.228\.168\.10|${CB_IPV4_PRIMARY}|g" \
    -e "s|185\.228\.169\.11|${CB_IPV4_SECONDARY}|g" \
    "${REPO}/files/pf-anchor-dns-filter" > "$ANCHOR_DEST"

# If using NextDNS, remove the NextDNS block rules so DoH can connect
if [[ "$FILTER_SLUG" == "nextdns" ]]; then
    sed -i '' '/45\.90\.28\.0/d' "$ANCHOR_DEST"
    sed -i '' '/76\.76\.2\.11/d' "$ANCHOR_DEST"
fi

# If using Cloudflare Families, remove the Cloudflare block rules so DoH can connect
if [[ "$FILTER_SLUG" == "cloudflare" ]]; then
    # Remove 1.1.1.3 and 1.0.0.3 from the blocklist, but keep 1.1.1.1/1.0.0.1 blocked.
    # Restrict the seds to "block drop" lines: the port-53 pass rule also contains
    # these IPs (substituted above) and must keep both of them.
    sed -i '' '/^block drop/s/1\.0\.0\.3, //g' "$ANCHOR_DEST"
    sed -i '' '/^block drop/s/, 1\.1\.1\.3//g' "$ANCHOR_DEST"
    sed -i '' '/^block drop/s/1\.1\.1\.3, //g' "$ANCHOR_DEST"
    sed -i '' '/162\.159\.61\.3/d' "$ANCHOR_DEST"
fi

carve_out_active_provider

chown root:wheel "$ANCHOR_DEST"
chmod 644 "$ANCHOR_DEST"
log "Written: ${ANCHOR_DEST}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2: Patch /etc/pf.conf
# ═════════════════════════════════════════════════════════════════════════════
log "Step 2/7: Patching /etc/pf.conf."

PF_CONF="/etc/pf.conf"
PF_BACKUP="${PF_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$PF_CONF" "$PF_BACKUP"
log "Backup saved: ${PF_BACKUP}"

ANCHOR_LINES='anchor "dns-filter"
rdr-anchor "dns-filter"
load anchor "dns-filter" from "/etc/pf.anchors/dns-filter"'

if grep -q 'anchor "dns-filter"' "$PF_CONF"; then
    log "Anchor lines already present in ${PF_CONF}, skipping injection."
else
    # PF requires strict ordering: translation (rdr) before filtering (pass/block).
    # rdr-anchor "dns-filter" must go in the translation section.
    # anchor "dns-filter"     must go in the filtering section.
    # load anchor "dns-filter" must go after the com.apple load line.
    awk '
        /rdr-anchor "com\.apple\/\*"/ {
            print
            print "rdr-anchor \"dns-filter\""
            next
        }
        /^anchor "com\.apple\/\*"/ {
            print
            print "anchor \"dns-filter\""
            next
        }
        /load anchor "com\.apple"/ {
            print
            print "load anchor \"dns-filter\" from \"/etc/pf.anchors/dns-filter\""
            next
        }
        { print }
    ' "$PF_CONF" > /tmp/pf.conf.patched

    # Verify all three lines were actually inserted before committing
    if grep -q 'rdr-anchor "dns-filter"' /tmp/pf.conf.patched \
        && grep -q '^anchor "dns-filter"' /tmp/pf.conf.patched \
        && grep -q 'load anchor "dns-filter"' /tmp/pf.conf.patched; then
        cp /tmp/pf.conf.patched "$PF_CONF"
        log "Anchor lines injected in correct PF ordering."
    else
        rm /tmp/pf.conf.patched
        echo "" >&2
        fail "Couldn't set up the web filter: your Mac's firewall config is in an unexpected state."
        echo "  Nothing was changed. Details are in ${LOG_FILE}." >&2
        log "Error: expected anchor points not found in ${PF_CONF}."
        log "Add manually, in order:"
        log "  After rdr-anchor \"com.apple/*\": rdr-anchor \"dns-filter\""
        log "  After anchor \"com.apple/*\":     anchor \"dns-filter\""
        log "  After load anchor \"com.apple\":  load anchor \"dns-filter\" from \"/etc/pf.anchors/dns-filter\""
        exit 1
    fi
    rm -f /tmp/pf.conf.patched
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3: Install the PF LaunchDaemon
# ═════════════════════════════════════════════════════════════════════════════
log "Step 3/7: Staging PF LaunchDaemon."

PF_DAEMON_DEST="/Library/LaunchDaemons/com.dnsfilter.pf.plist"
DAEMON_DEST="$PF_DAEMON_DEST"  # legacy alias preserved for the next few steps
unlock_if_locked "$DAEMON_DEST"

# If already loaded, unload first to avoid bootstrap conflict
if launchctl list 2>/dev/null | grep -q "com.dnsfilter.pf"; then
    log "Unloading existing daemon."
    launchctl bootout system "$DAEMON_DEST" 2>/dev/null || launchctl unload "$DAEMON_DEST" 2>/dev/null || true
fi

cp "${REPO}/files/com.dnsfilter.pf.plist" "$DAEMON_DEST"
chown root:wheel "$DAEMON_DEST"
chmod 644 "$DAEMON_DEST"

log "Staged: ${DAEMON_DEST}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4: Defer PF activation
# ═════════════════════════════════════════════════════════════════════════════
# PF is intentionally staged but not loaded until after macOS confirms the DNS
# profile is installed and resolving. Loading PF first creates the cascade before
# the profile exists, which strands normal DNS during setup.
log "Step 4/7: Deferring PF enforcement until the DNS profile is active."
log "PF is staged but not loaded yet, so DNS keeps working during manual profile approval."

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5: Generate mobileconfig and prompt GUI install
# ═════════════════════════════════════════════════════════════════════════════
log "Step 5/7: Preparing DNS Configuration Profile."
cleanup_desktop_profile_copy "$REAL_USER"

# Check for any existing CleanBrowsing DNS profile that might conflict with the
# install (macOS NetworkExtension can refuse to "create the VPN service" if it
# sees a stale or partial DNS profile already registered).
EXISTING_PROFILES=$(profiles list 2>/dev/null | grep -i "cleanbrowsing\|com\.cleanbrowsing\.dns\|nextdns\|io\.nextdns\.custom\|cloudflare\|com\.cloudflare\.dns\|adguard\|controld\|mullvad" || true)
if [[ -n "$EXISTING_PROFILES" ]]; then
    echo ""
    echo "  An existing DNS profile is already installed:"
    echo "$EXISTING_PROFILES" | sed 's/^/    /'
    echo ""
    echo "  This can cause 'VPN Service could not be created' errors on re-install."
    if [[ -n "$FILTER_ARG" ]]; then
        REMOVE_EXISTING="y"
    else
        read -rp "  Remove the existing profile(s) and continue? [Y/n]: " REMOVE_EXISTING
    fi
    if [[ ! "$REMOVE_EXISTING" =~ ^[Nn] ]]; then
        # Extract identifiers and attempt removal
        echo "$EXISTING_PROFILES" | grep -oE '(com\.cleanbrowsing\.dns|io\.nextdns\.custom|com\.cloudflare\.dns|com\.adguard\.dns|com\.controld\.dns|net\.mullvad\.dns)\.[a-zA-Z0-9._-]+' | sort -u | while read -r PROFILE_ID; do
            log "Removing existing profile: $PROFILE_ID"
            profiles remove -identifier "$PROFILE_ID" >> "$LOG_FILE" 2>&1 || true
        done
        sleep 2
    fi
fi

# Clear any leftover download from a previous attempt before writing a new one.
_load_or_generate_profile_uuids
clear_pending_dns_profile
if [[ ! -f "$(profile_pending_path)" && ! -f "$(profile_backup_path)" ]]; then
    OUTER_UUID=$(uuidgen)
    INNER_UUID=$(uuidgen)
    log "Generated fresh profile UUIDs for a new install attempt."
fi

PROFILE_PENDING=$(profile_pending_path)
PROFILE_BACKUP=$(profile_backup_path)
PROFILE_OPEN_RECORD=$(profile_open_record_path)
mkdir -p "/Library/Application Support/Blockdown"
_ensure_profile_pending_dir

_write_dns_mobileconfig "$PROFILE_PENDING"
user=$(_profile_console_user)
if [[ -n "$user" ]]; then
    chown "${user}:staff" "$PROFILE_PENDING"
fi
chmod 644 "$PROFILE_PENDING"
printf '%s\n%s\n' "$PROFILE_PENDING" "$OUTER_UUID" > "$PROFILE_OPEN_RECORD"

# Open the pending profile in the user's session so macOS queues installation.
# The self-healer uses PROFILE_BACKUP after a successful install.
sudo -u "$REAL_USER" open "$PROFILE_PENDING"

echo ""
echo "  One step needs you: install the filter profile in System Settings."
echo ""
echo "  1. Open System Settings, then ${PROFILE_PANE_TOP}."
echo "  2. Scroll down and click ${PROFILE_PANE_SUB}."
echo "  3. Click the pending profile named:"
echo "       ${FILTER_NAME}"
echo "  4. Click Install and enter your Mac password."
echo ""
echo "  You'll know it worked when the pending notice clears and"
echo "  \"${FILTER_NAME}\" is listed as installed."
echo ""
read -rp "  Press return once the profile is installed. ↵ "
echo ""

# Flush DNS cache and restart mDNSResponder so the new DoH profile takes effect
# immediately. Without this, macOS may continue to use the previous resolver
# (DHCP-provided or VPN-provided) until the next network event.
log "Flushing DNS cache and restarting mDNSResponder."
dscacheutil -flushcache
killall -HUP mDNSResponder
sleep 2

if ! profile_is_installed; then
    echo "" >&2
    fail "The filter profile isn't installed yet."
    echo "  Nothing was locked in. Your internet access is unchanged." >&2
    log "Error: profile not installed after user step."
    rollback_dns_enforcement
    exit 1
fi

if ! system_dns_resolves; then
    echo "" >&2
    fail "The profile is installed, but the internet isn't responding yet."
    echo "  Nothing was locked in. Try again in a moment. Details: ${LOG_FILE}." >&2
    log "Error: profile installed but system DNS not resolving."
    rollback_dns_enforcement
    exit 1
fi

log "DNS profile is installed and system DNS resolves."
cleanup_desktop_profile_copy "$REAL_USER"

mkdir -p /Library/PrivilegedHelperTools
unlock_if_locked "$PROFILE_BACKUP"
cp "$PROFILE_PENDING" "$PROFILE_BACKUP"
chown root:wheel "$PROFILE_BACKUP"
chmod 644 "$PROFILE_BACKUP"
rm -f "$PROFILE_PENDING" "$PROFILE_OPEN_RECORD"
log "Promoted pending profile to ${PROFILE_BACKUP}."

log "Enabling PF DNS enforcement."
launchctl bootstrap system "$PF_DAEMON_DEST" 2>/dev/null \
    || launchctl load "$PF_DAEMON_DEST" 2>/dev/null \
    || true
sleep 1

if ! pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
    pfctl -E -f /etc/pf.conf
fi

ANCHOR_RULES=$(pfctl -a dns-filter -sr 2>&1 | wc -l | tr -d ' ')
if [[ "$ANCHOR_RULES" -lt 5 ]]; then
    pfctl -f /etc/pf.conf
    sleep 1
    ANCHOR_RULES=$(pfctl -a dns-filter -sr 2>&1 | wc -l | tr -d ' ')
fi

if [[ "$ANCHOR_RULES" -lt 5 ]]; then
    echo "" >&2
    fail "Couldn't turn on the web filter's firewall rules."
    echo "  Nothing was locked in. Details: ${LOG_FILE}." >&2
    log "Error: PF dns-filter anchor did not load."
    rollback_dns_enforcement
    exit 1
fi
log "PF enabled, dns-filter anchor loaded (${ANCHOR_RULES} rules)."

# ═════════════════════════════════════════════════════════════════════════════
# STEP 6: Install the profile self-healer (watcher script + LaunchDaemon)
# ═════════════════════════════════════════════════════════════════════════════
# macOS does NOT honor PayloadRemovalDisallowed=true for locally-installed
# (non-MDM) profiles. The `−` button in System Settings will remove the profile.
# To restore the "un-removable" property, we install a watcher daemon that
# checks every 60 seconds whether the profile is installed; if not, it opens
# the backup mobileconfig in the console user's session, surfacing macOS's
# standard System Settings approval prompt — the same UI you get from
# double-clicking a mobileconfig file. Real friction for any removal attempt.
WATCHER_SCRIPT_DEST="/usr/local/sbin/dns-profile-watcher"
WATCHER_DAEMON_DEST="/Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist"

if bd_is_lite; then
log "Step 6/7: Skipped (Blockdown: no profile self-healer; the profile is removable)."
else
log "Step 6/7: Installing profile self-healer."

mkdir -p /usr/local/sbin
unlock_if_locked "$WATCHER_SCRIPT_DEST"
unlock_if_locked "$WATCHER_DAEMON_DEST"

cp "${REPO}/files/dns-profile-watcher.sh" "$WATCHER_SCRIPT_DEST"
chown root:wheel "$WATCHER_SCRIPT_DEST"
chmod 755 "$WATCHER_SCRIPT_DEST"
log "Written: ${WATCHER_SCRIPT_DEST}"

# Bootout any existing watcher before bootstrapping a fresh one
if launchctl list 2>/dev/null | grep -q "com.dnsfilter.profile-watcher"; then
    log "Unloading existing watcher daemon."
    launchctl bootout system "$WATCHER_DAEMON_DEST" 2>/dev/null \
        || launchctl unload "$WATCHER_DAEMON_DEST" 2>/dev/null \
        || true
fi

cp "${REPO}/files/com.dnsfilter.profile-watcher.plist" "$WATCHER_DAEMON_DEST"
chown root:wheel "$WATCHER_DAEMON_DEST"
chmod 644 "$WATCHER_DAEMON_DEST"

launchctl bootstrap system "$WATCHER_DAEMON_DEST" 2>/dev/null \
    || launchctl load "$WATCHER_DAEMON_DEST" 2>/dev/null \
    || true
log "Loaded: ${WATCHER_DAEMON_DEST}"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7: Seed self-heal backups (Item B) and lock all files with schg
# ═════════════════════════════════════════════════════════════════════════════
log "Step 7/7: Seeding self-heal backups and locking files."

# Item B: back up the PF enforcer plist + profile self-healer (worker + plist)
# so the cyclic supervisor can restore them from a schg-locked copy. Sourced
# verbatim from the repo so backup seeding is independent of live-file locking.
CACHE_DIR="/Library/Application Support/.cache"
PF_PLIST_BACKUP="${CACHE_DIR}/dnsfilter.pf.plist.backup"
WATCHER_SCRIPT_BACKUP="${CACHE_DIR}/dns-profile-watcher.backup"
WATCHER_DAEMON_BACKUP="${CACHE_DIR}/dnsfilter.profile-watcher.plist.backup"
mkdir -p "$CACHE_DIR"
chflags noschg "$PF_PLIST_BACKUP" "$WATCHER_SCRIPT_BACKUP" "$WATCHER_DAEMON_BACKUP" 2>/dev/null || true
cp "${REPO}/files/com.dnsfilter.pf.plist" "$PF_PLIST_BACKUP"
cp "${REPO}/files/dns-profile-watcher.sh" "$WATCHER_SCRIPT_BACKUP"
cp "${REPO}/files/com.dnsfilter.profile-watcher.plist" "$WATCHER_DAEMON_BACKUP"
chown root:wheel "$PF_PLIST_BACKUP" "$WATCHER_SCRIPT_BACKUP" "$WATCHER_DAEMON_BACKUP"
chmod 644 "$PF_PLIST_BACKUP" "$WATCHER_DAEMON_BACKUP"
chmod 755 "$WATCHER_SCRIPT_BACKUP"

chflags schg "$ANCHOR_DEST"
chflags schg "$PF_DAEMON_DEST"
chflags schg "$PROFILE_BACKUP"
chflags schg "$WATCHER_SCRIPT_DEST"
chflags schg "$WATCHER_DAEMON_DEST"
chflags schg "$PF_PLIST_BACKUP" "$WATCHER_SCRIPT_BACKUP" "$WATCHER_DAEMON_BACKUP"
log "Locked: ${ANCHOR_DEST}"
log "Locked: ${PF_DAEMON_DEST}"
log "Locked: ${PROFILE_BACKUP}"
log "Locked: ${WATCHER_SCRIPT_DEST}"
log "Locked: ${WATCHER_DAEMON_DEST}"
log "Locked backups: ${PF_PLIST_BACKUP}, ${WATCHER_SCRIPT_BACKUP}, ${WATCHER_DAEMON_BACKUP}"
fi

# ═════════════════════════════════════════════════════════════════════════════
# VERIFICATION
# ═════════════════════════════════════════════════════════════════════════════
log "Running verification checks."

PASS=0
FAIL=0

# Check 1: Profile installed
if profile_is_installed; then
    log "[PASS] DNS profile is installed."
    PASS=$((PASS + 1))
else
    log "[FAIL] DNS profile not found."
    FAIL=$((FAIL + 1))
fi

# Check 2a: System resolver works at all (uses mDNSResponder, i.e. the DoH
# profile — NOT dig, which goes to the DHCP resolver on port 53 and is always
# blocked by PF regardless of whether the filter is healthy).
GOOGLE_RESULT=$(dscacheutil -q host -a name google.com 2>/dev/null | awk '/^ip_address/ {print $2; exit}')
if system_dns_resolves; then
    log "[PASS] google.com resolves (${GOOGLE_RESULT}); system DNS is working."
    PASS=$((PASS + 1))
else
    log "[FAIL] google.com does not resolve; the DoH profile is probably not active."
    FAIL=$((FAIL + 1))
fi

# Check 2b: Verify category behavior only for filters that should block adult sites.
if [[ "$FILTER_SLUG" =~ ^(adult|family|cloudflare)$ ]]; then
    FILTER_RESULT=$(dscacheutil -q host -a name pornhub.com 2>/dev/null | awk '/^ip_address/ {print $2; exit}')
    if [[ -z "$FILTER_RESULT" ]] || [[ "$FILTER_RESULT" == "0.0.0.0" ]]; then
        log "[PASS] pornhub.com is blocked; the filter is active."
        PASS=$((PASS + 1))
    else
        log "[FAIL] pornhub.com resolved to '${FILTER_RESULT}'; the filter may not be active."
        FAIL=$((FAIL + 1))
    fi
else
    log "[INFO] Adult-domain block check skipped for ${FILTER_NAME}."
fi

# Check 3 (informational only): scutil visibility. On many macOS versions,
# managed DoH settings do NOT appear in scutil --dns even when fully active,
# so this is not counted as a failure. Checks 2a/2b above test actual behavior.
if scutil --dns 2>/dev/null | grep -qi -e "cleanbrowsing" -e "nextdns" -e "cloudflare" -e "adguard" -e "controld" -e "mullvad" -e "45.90.28.0" -e "1.1.1.3" -e "1.0.0.3" -e "94.140.14.14" -e "76.76.2.3" -e "194.242.2.5"; then
    log "[INFO] Custom DNS is visible in scutil --dns."
else
    log "[INFO] Custom DNS not visible in scutil --dns (normal on macOS 14+)."
fi

# Check 4: Profile self-healer daemon is running (Max only — Blockdown installs none)
if bd_is_lite; then
    log "[INFO] Blockdown: profile self-healer not installed; the profile is removable."
elif launchctl list 2>/dev/null | grep -q "com.dnsfilter.profile-watcher"; then
    log "[PASS] Profile self-healer daemon is running."
    PASS=$((PASS + 1))
else
    log "[FAIL] Profile self-healer daemon is NOT running; removals will not be re-queued."
    FAIL=$((FAIL + 1))
fi

log "Result: ${PASS} passed, ${FAIL} failed."

echo ""
if [[ $FAIL -eq 0 ]]; then
    ok "Web filter is active. ${FILTER_NAME} is now filtering your whole Mac."
    echo ""
    exit 0
fi

# Something failed: roll back so the internet is never stranded, then guide.
fail "The web filter didn't come up cleanly, so it was rolled back."
echo "  Your internet is working and nothing was locked in."
echo ""
echo "  Common fixes:"
echo "    1. Disconnect any VPN. It can override the filter."
echo "    2. Run: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
echo "    3. Wait a few seconds, then set up the web filter again."
echo "    4. If it still fails, restart your Mac and try once more."
echo ""
echo "  Full details are in ${LOG_FILE}."
echo ""
rollback_dns_enforcement
exit 1
