#!/bin/bash
# install-app-blocking.sh — Layer 2 (app blocking) installer.
#
# Item 0: creates the recoverable testing marker at install start.
# Item A: schg-locks banned-bundle-ids.list (bannedd.plist + banned-processes.list
#         are locked automatically by mdsyncd helpers on first `blockdown app apply`).
# Item B: seeds killappsd + appblockerd.plist self-heal backups for cyclic supervision.
# Item C: seeds the powered-on tick counter (.uptime-ticks) used by the removal gate.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="/Library/Application Support/.cache"
BD_TESTING_MARKER="${CACHE}/.bd-testing"
BANNED_CONFIG="/Library/Application Support/.cache/bannedd.plist"
BANNED_PROCESSES="/Library/Application Support/.cache/banned-processes.list"
BANNED_BUNDLES="/Library/Application Support/.cache/banned-bundle-ids.list"
PENDING_REMOVAL_APP="/Library/Application Support/.cache/pending_removal_app"
UPTIME_TICKS_FILE="${CACHE}/.uptime-ticks"
KILLAPPSD_BACKUP="${CACHE}/killappsd.backup"
APPBLOCKERD_PLIST_BACKUP="${CACHE}/appblockerd.plist.backup"

# Blockdown edition marker (no lock-in). Present = install the kill daemon
# (blocking still works) but skip schg locks and self-heal backups.
BD_EDITION_MARKER="${CACHE}/.bd-edition"
bd_is_lite() { [ -f "$BD_EDITION_MARKER" ] && [ "$(cat "$BD_EDITION_MARKER" 2>/dev/null)" = "lite" ]; }

echo "Step 0 — Enter recoverable testing mode (Item 0)"
sudo mkdir -p "$CACHE"
sudo touch "$BD_TESTING_MARKER"
sudo chown root:wheel "$BD_TESTING_MARKER"
sudo chmod 644 "$BD_TESTING_MARKER"

echo "Step 1 — Install kill daemon script"
sudo mkdir -p /usr/local/bin
# Unlock first so re-installs can overwrite. On a fresh install the file is
# absent (no-op); on a re-install it is schg-locked from Step 4 of a prior run,
# and cp would silently fail (no set -e) without this. Step 4 re-locks it.
sudo chflags noschg /usr/local/bin/killappsd 2>/dev/null || true
sudo cp "$REPO/files/killappsd" /usr/local/bin/killappsd
sudo chown root:wheel /usr/local/bin/killappsd
sudo chmod 755 /usr/local/bin/killappsd

echo "Step 2 — Install LaunchDaemon"
# Same rationale: unlock before overwrite so re-installs are idempotent.
sudo chflags noschg /Library/LaunchDaemons/com.apple.appblockerd.plist 2>/dev/null || true
sudo cp "$REPO/files/com.apple.appblockerd.plist" /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo chown root:wheel /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo chmod 644 /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.apple.appblockerd.plist

echo "Step 2b — Install the blockdown CLI"
sudo bash "$REPO/scripts/install-cli.sh" "$REPO"

echo "Step 2c — Reset dynamic app block state"
sudo mkdir -p "/Library/Application Support/.cache/"
sudo chflags nouchg,noschg "$BANNED_CONFIG" "$BANNED_PROCESSES" "$BANNED_BUNDLES" "$PENDING_REMOVAL_APP" 2>/dev/null || true
sudo rm -f "$BANNED_CONFIG" "$BANNED_PROCESSES" "$BANNED_BUNDLES" "$PENDING_REMOVAL_APP"
sudo touch "$BANNED_BUNDLES"
sudo chown root:wheel "$BANNED_BUNDLES"
sudo chmod 644 "$BANNED_BUNDLES"
[[ -f "$BANNED_CONFIG" ]] && sudo chmod 644 "$BANNED_CONFIG"

if bd_is_lite; then
    echo "Step 2d: Skipped (Blockdown: no self-heal backups)"
else
echo "Step 2d — Seed self-heal backups (Item B)"
sudo chflags noschg "$KILLAPPSD_BACKUP" "$APPBLOCKERD_PLIST_BACKUP" 2>/dev/null || true
sudo cp "$REPO/files/killappsd" "$KILLAPPSD_BACKUP"
sudo cp "$REPO/files/com.apple.appblockerd.plist" "$APPBLOCKERD_PLIST_BACKUP"
sudo chown root:wheel "$KILLAPPSD_BACKUP" "$APPBLOCKERD_PLIST_BACKUP"
sudo chmod 755 "$KILLAPPSD_BACKUP"
sudo chmod 644 "$APPBLOCKERD_PLIST_BACKUP"
fi

echo "Step 2e — Seed powered-on tick counter (Item C)"
sudo chflags noschg "$UPTIME_TICKS_FILE" 2>/dev/null || true
echo 0 | sudo tee "$UPTIME_TICKS_FILE" >/dev/null
sudo chown root:wheel "$UPTIME_TICKS_FILE"
sudo chmod 644 "$UPTIME_TICKS_FILE"

echo "Step 3 — Start with no preloaded app blocks"
sudo blockdown app apply >/dev/null 2>&1 || true

if bd_is_lite; then
    echo "Step 4: Skipped (Blockdown: files stay unlocked and removable)"
else
echo "Step 4 — Lock the daemon, kill daemon, and self-heal state (Items A/B/C)"
sudo chflags schg /usr/local/bin/killappsd
sudo chflags schg /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo chflags schg "$BANNED_BUNDLES"
sudo chflags schg "$UPTIME_TICKS_FILE"
sudo chflags schg "$KILLAPPSD_BACKUP" "$APPBLOCKERD_PLIST_BACKUP"
fi

echo "Verification:"
sudo launchctl list | grep appblockerd
sudo blockdown app list | wc -l
echo "Layer 2 installed successfully."

# ── Arm: leave recoverable testing mode ───────────────────────────────────────
# Removing the marker activates Max's self-heal + gated teardown. For Blockdown
# it is inert (supervision no-ops on the edition marker), but we clear it so the
# marker never lingers. Onboarding sets BD_DEFER_ARM=1 and arms ONCE after all
# layers are in, to avoid a supervisor-vs-installer race; a standalone run arms
# itself here.
if [ "${BD_DEFER_ARM:-0}" != "1" ]; then
    sudo chflags noschg "$BD_TESTING_MARKER" 2>/dev/null || true
    sudo rm -f "$BD_TESTING_MARKER"
fi
