# Layer 2 — App Blocking

**Goal:** Prevent VPN-embedding browsers, Tor browsers, messaging apps (Telegram, Discord), Android emulators (BlueStacks, NoxPlayer, etc.), and Chromium-site-wrappers (WebCatalog, Flotato, etc.) from existing on this Mac or being launched from anywhere — Downloads, USB, another disk.

**Why it exists here:** Layer 4 only covers browser-managed policies. Apps that embed their own network stack (Opera's VPN, Brave's Tor, Tor Browser's bundled Tor, Telegram's built-in proxy) are unreachable from browser policy. Layer 2 blocks them by preventing installation and killing them if launched.

---

## Two lists, each with a distinct job

1. **Dynamic ban list (`data/banned-apps.txt` in the repo; live state in `bannedd.plist`) + kill daemon.** Read by `killappsd` every 10s. For each entry the daemon does a **regex** match against all running process command lines — pattern `<Name>( \([0-9]+\))?\.app/Contents/MacOS` — so both `<Name>.app` and auto-suffixed copies like `<Name> (1).app` get killed. Manageable via `sudo blockdown app add/remove` (or `sudo ban add/remove`) with a removal delay per your unlock method.
2. **Bundle-ID kill list (`data/banned-bundle-ids.txt` in the repo; live state in `banned-bundle-ids.list`).** Read by `killappsd` every 10s as a second pass. For every running `.app` process, reads its `Info.plist` via `defaults`, compares `CFBundleIdentifier` against this list, kills on match. **Catches manual renames** — e.g. `cp -R Opera.app Foo.app` followed by launch. Bundle ID can't be changed without re-signing, which is above the threat model's friction bar. `killappsd` also harvests bundle IDs from installed copies of banned apps (its harvest pass).

How they compose: when you block an app, `apply_app_blocks()` (in `mdsyncd`) expands the name into common variants and rewrites the kill daemon's process-match list. No placeholder files are created; enforcement is kill-on-launch. The regex path-kill catches whatever launches under a recognizable name (including macOS auto-suffix). The bundle-ID kill catches the renamed-to-arbitrary-name case; `killappsd` harvests bundle IDs of installed copies of banned apps on each tick, so that list maintains itself.

**Note:** The repo's `data/banned-apps.txt` and `data/banned-bundle-ids.txt` are reference/export templates. A fresh Layer 2 install starts with **no preloaded blocks** — you add apps via the TUI, onboarding, or `sudo blockdown app add`.

## What this layer installs

Run the installer:

```bash
sudo bash "$REPO/scripts/install-app-blocking.sh"
```

It installs:

1. `/usr/local/bin/killappsd` — kill daemon script (four passes: reconcile derived state, regex path-kill, bundle-ID kill, bundle-ID harvest).
2. `/Library/LaunchDaemons/com.apple.appblockerd.plist` — schedules killappsd every 10s.
3. `/usr/local/bin/blockdown`, `/usr/local/bin/ban`, `/usr/local/bin/pin` — CLI wrappers.
4. Empty dynamic state under `/Library/Application Support/.cache/` (`bannedd.plist`, `banned-processes.list`, `banned-bundle-ids.list`).

The `blockdown app` / `ban` CLI itself lives inside `mdsyncd`, which was already installed by Layer 4.

## Prerequisites

- Layer 4 complete and verified (mdsyncd / CLI).
- `files/killappsd` exists in the repo.
- `files/com.apple.appblockerd.plist` exists.

## Install steps (manual equivalent)

The installer script above performs these steps. For reference:

### Step 1 — Install kill daemon script

```bash
sudo mkdir -p /usr/local/bin
sudo cp $REPO/files/killappsd /usr/local/bin/killappsd
sudo chown root:wheel /usr/local/bin/killappsd
sudo chmod 755 /usr/local/bin/killappsd
```

### Step 2 — Install LaunchDaemon

```bash
sudo cp $REPO/files/com.apple.appblockerd.plist /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo chown root:wheel /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo chmod 644 /Library/LaunchDaemons/com.apple.appblockerd.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.apple.appblockerd.plist
```

### Step 2b — Install the CLI

```bash
sudo bash $REPO/scripts/install-cli.sh $REPO
```

### Step 2c — Reset dynamic app block state

Fresh install clears any prior ban state and starts empty:

```bash
sudo mkdir -p "/Library/Application Support/.cache/"
sudo rm -f "/Library/Application Support/.cache/bannedd.plist"
sudo rm -f "/Library/Application Support/.cache/banned-processes.list"
sudo rm -f "/Library/Application Support/.cache/banned-bundle-ids.list"
sudo touch "/Library/Application Support/.cache/banned-bundle-ids.list"
sudo chown root:wheel "/Library/Application Support/.cache/banned-bundle-ids.list"
sudo chmod 644 "/Library/Application Support/.cache/banned-bundle-ids.list"
```

### Step 3 — Apply (empty) block state

```bash
sudo blockdown app apply
```

### Step 4 — Lock the daemon plist and kill daemon

```bash
sudo chflags schg /usr/local/bin/killappsd
sudo chflags schg /Library/LaunchDaemons/com.apple.appblockerd.plist
```

### Step 5 — Block apps (post-install)

Add apps via the TUI (`./blockdown`), onboarding, or CLI:

```bash
sudo blockdown app add "Tor Browser"
sudo blockdown app add Telegram Discord
```

Each `app add` registers kill patterns immediately; a running instance dies within 10 seconds.

To seed from the repo template on a new Mac:

```bash
while IFS= read -r name; do
    [ -z "$name" ] && continue
    [[ "$name" == \#* ]] && continue          # skip comments
    sudo blockdown app add "$name"
done < $REPO/data/banned-apps.txt
```

**Note:** blocking matches on the app's display name (plus generated variants), so review names before blocking and use the exact Finder display name for anything ambiguous.

To also block manual renames, append bundle IDs to the live list (or copy from `data/banned-bundle-ids.txt`):

```bash
# Strip comment/blank lines from the template before seeding the live list.
grep -vE '^[[:space:]]*(#|$)' "$REPO/data/banned-bundle-ids.txt" \
    | sudo tee "/Library/Application Support/.cache/banned-bundle-ids.list" >/dev/null
sudo chown root:wheel "/Library/Application Support/.cache/banned-bundle-ids.list"
sudo chmod 644 "/Library/Application Support/.cache/banned-bundle-ids.list"
```

## Verification

```bash
sudo launchctl list | grep appblockerd
```

Expected: shows `com.apple.appblockerd` running.

```bash
sudo blockdown app list
```

Expected: lists apps you added.

Live test: block a browser, copy it from another Mac into `~/Downloads/`, and double-click it. Expected: it dies within 10 seconds (killappsd tick).

## Safeguards

- **Kill daemon script `schg`-locked** — modification requires `sudo chflags noschg` first.
- **Kill daemon plist `schg`-locked** — same.
- **Ban state files `schg`-locked** (`bannedd.plist`, `banned-processes.list`, `banned-bundle-ids.list`) — the daemons unlock, rewrite, and re-lock them.
- **Self-healing** — the kill daemon's reconcile pass converges all derived state to the banned-names list on every 10s tick, and the cyclic supervision in `lib-supervise.sh` restores missing daemon files from `schg`-locked backups.
- **Pending removal state files `schg`-locked** — prevents bypassing the removal delay by manually editing the timestamp.

## Upgrading from older installs (legacy quarantine)

Older Blockdown versions installed a separate static quarantine list (`quarantine-apps.txt`) — placeholders that blocked install paths but were never on the kill list. That mechanism has been removed.

To clean up leftover quarantine placeholders without a full uninstall:

```bash
sudo find /Applications -name "*.app" -flags +uchg -size 0 -exec chflags nouchg {} + -exec rm -rf {} + 2>/dev/null
```

Then block any apps you still care about via `sudo blockdown app add`.

## How to actually use this layer

### Add a new app to the block list

```bash
sudo blockdown app add WhatsApp
```

Immediate effect. Registers the kill patterns; a running instance dies within 10 seconds.

*(Note: `blockdown app add` uses path-based matching, which catches normal launches and macOS auto-renamed copies. It does **not** automatically add the app's Bundle ID to the secondary kill list. To also block manual renames, append its `CFBundleIdentifier` to `banned-bundle-ids.list`.)*

### Remove an app (removal delay per unlock method)

```bash
sudo blockdown app remove WhatsApp    # schedules removal
# ... wait per your unlock method ...
sudo blockdown app remove WhatsApp    # actually removes (dropped from name + bundle-ID lists)
```

```bash
sudo blockdown app list
sudo blockdown app status             # shows pending + remaining time (cooldown method)
```

### What's in the sample `data/banned-apps.txt` / `data/banned-bundle-ids.txt`

The shipped templates are a **Tier 1/2 browser bypass set** (21 apps + matching
bundle IDs) — browsers that embed VPN/Tor or can't be managed by Layer 4:

- **Opera family (7)** — built-in VPN
- **Brave family (4)** — built-in Tor
- **Tor / Mullvad / Epic (3)** — embedded circumvention network
- **Firefox family (7)** — unmanageable by Chromium policies

Browsers caught by Layer 4 alone (Vivaldi, Arc, Ungoogled Chromium) are **not**
in the template. Site-wrappers, emulators, and messaging apps are valid Layer 2
targets but also omitted — add them yourself if your threat model needs them.

### Why some apps belong in Layer 2 (full taxonomy)

- **Browsers with built-in VPN/Tor:** Brave (Tor), Opera / OperaGX (VPN), Vivaldi, Aloha, Mullvad, Tor, Epic.
- **Android emulators:** BlueStacks, NoxPlayer, MEmu, LDPlayer, Genymotion, MuMu Player, GameLoop. These can run Android apps that bypass macOS-level blocks entirely.
- **iOS app runners:** PlayCover. Same reason.
- **Messaging apps with bypass-heavy features:** Telegram (built-in proxy), Discord (can be used as a content-share platform).
- **Chromium site-wrappers:** WebCatalog, Flotato, Fluid, Coherence X, Unite, MenubarX, Pake, Epichrome. These wrap sites in a Chromium shell that often doesn't honor managed-policy (Layer 4). Blocking them preempts that bypass.
- **Social-specific browsers / workspaces:** Friendly Social, Sidekick, Biscuit, Ghost Browser, Franz, Ferdium, Rambox, Wavebox, Stack. Same bypass surface as generic wrappers, packaged as social products.
- **Native social clients:** Flume, Tweetbot, Grids, etc. — API-backed clients that never hit URL policy.

## Files and data

| Repo file/data | Role |
|---|---|
| `files/killappsd` | `/usr/local/bin/killappsd` |
| `files/ban` | `/usr/local/bin/ban` (alias) |
| `files/blockdown` | `/usr/local/bin/blockdown` |
| `files/com.apple.appblockerd.plist` | `/Library/LaunchDaemons/com.apple.appblockerd.plist` |
| `scripts/install-app-blocking.sh` | One-shot Layer 2 installer |
| `data/banned-apps.txt` | Reference template / uninstall export target — seed with `blockdown app add` |
| `data/banned-bundle-ids.txt` | Reference template for bundle-ID kill list |
