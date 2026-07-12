# Layer 4 — Browser Policies

**Goal:** Every Chromium-family browser (Chrome, Edge, Brave, Vivaldi, Opera, Arc, Dia, Chromium, Thorium, ungoogled-Chromium, Helium, Kagi, and other installed Chromium forks detected by framework name / `chrome_100_percent.pak`) has enforced managed policies that block VPN extensions, disable browser-level DoH, and force SafeSearch. URL-path and wildcard pattern blocking is out of scope (whole domains only), and Layer 4 explicitly clears any `URLBlocklist` key. Coverage is delivered by the `mdsyncd` worker writing managed-preferences plists every hour. Firefox and its forks cannot be robustly managed by system policies without leaving user-level bypasses or unmanageable loopholes, so they are completely banned at Layer 2 instead.

**What this is:** Not a fourth blocking surface in the same sense as Layers 1–3 (those block websites, apps, and categories). Layer 4 is bypass hardening for Chromium browsers: it stops VPN/proxy extensions and browser-level DoH from punching through the web filter. The same installer also drops the shared `mdsyncd` worker that Layers 1 and 2 use as their CLI/backend.

**Why it exists here:** Layer 3 is bypassable from inside a browser that runs its own DoH resolver or tunnels DNS through a VPN extension. Layer 4 prevents those extensions from existing and disables the browser DoH feature outright.

---

## What this layer installs

1. **`mdsyncd`** — a bash worker at `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd` that writes managed-preferences plists for every Chromium browser. Also hosts the `blockdown host` (Layer 1) and `blockdown app` (Layer 2) backends.
2. **`statsd`** — a self-healer at the same directory. Restores `mdsyncd` if deleted. Runs every 30 minutes.
3. **Two LaunchDaemon plists** — `com.apple.mdsyncd.plist` (runs `mdsyncd apply` hourly + on WatchPaths) and `com.apple.statsd.plist` (runs `statsd` every 30 minutes).
4. **Two backup files** in `/Library/Application Support/.cache/` that statsd restores from.
5. **The `blockdown` CLI** at `/usr/local/bin/blockdown` (with legacy `pin`/`ban` aliases) — thin shims that exec `mdsyncd`.

## What policies get written

For each Chromium bundle detected in `/Applications/` or listed in `CHROMIUM_BUNDLES`:

- `ProxySettings = {ProxyMode: "direct"}` — blocks VPN extensions using `chrome.proxy`.
- `ExtensionSettings = {"*": {blocked_permissions: ["proxy"]}}` — strips the `proxy` permission from all extensions globally.
- `ExtensionInstallBlocklist` — 25 known VPN extension IDs (NordVPN, ExpressVPN, Hoxx, Windscribe, Browsec, ZenMate, etc.).
- `DnsOverHttpsMode = off` — prevents browser-level DoH bypass of system DNS.
- `ForceGoogleSafeSearch = true` — SafeSearch locked on.
- `ExtensionInstallForcelist` explicitly cleared every run (so stale forced extensions from prior installations get cleaned up).

## Prerequisites

- `files/mdsyncd` exists in the repo (the worker script).
- `files/statsd` exists.
- `files/com.apple.mdsyncd.plist` and `files/com.apple.statsd.plist` exist.
- `files/pin` exists (thin wrapper).

Manual installs usually run Layer 4 before Layers 1–2 because those layers need `mdsyncd` and the CLI. Layer 3 (web filter) is independent and can install in any order.

## Install steps

To install the full Layer 4 stack (directories, binaries, backups, and daemons):

```bash
sudo ./scripts/install-browser-policies.sh
```

The script will automatically execute steps 1-7.

### What the installer does behind the scenes:
1. **Creates directories** at `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin`, `/Library/Application Support/.cache`, and `/Library/Managed Preferences`.
2. **Installs binaries** (`mdsyncd` and `statsd`) with correct `root:wheel` ownership.
3. **Seeds backups** of the worker and plist for the self-healer.
4. **Installs LaunchDaemons** (`com.apple.mdsyncd.plist` and `com.apple.statsd.plist`).
5. **Installs the `blockdown` CLI** (with `pin`/`ban` aliases) to `/usr/local/bin`.
6. **Defers VPN-extension policies**: the installer sets a `browser-policies-disabled` marker, so no policy plists are written until you opt in via **Set up web filter → Fix bypasses → Block VPN extensions** in the TUI (or `sudo bash scripts/install-browser-policies.sh --vpn-extensions`).
7. **Loads daemons.**
8. **Locks the chain** using `schg` flags.

## Verification

The `install-browser-policies.sh` script runs a full verification suite automatically at the end. You can also manually verify:

## Safeguards

- **Worker binary `schg`-locked.** Modification requires `chflags noschg`.
- **LaunchDaemon plist `schg`-locked.** Same.
- **Self-healer binary and plist `schg`-locked.** Same.
- **Daemon unloading protection** — `statsd` actively checks if `mdsyncd` is loaded in `launchctl`, and if not, forces it to load. This prevents a user from bypassing the system by simply unloading the daemon.
- **Backup files `schg`-locked.** Someone can't simultaneously delete the worker and its backup without a multi-file unlock.
- **Managed preferences plists NOT schg-locked** — they get rewritten every time `apply_policies` runs, so transient tampering self-heals within the hour (or within seconds if `/Applications/` or `/Library/Managed Preferences/` changes trigger WatchPaths).

## CLI surface added by this layer

```
sudo blockdown apply             # Force re-apply all policies now
```

The `blockdown host *` commands for Layer 1 and the `blockdown app *` commands for Layer 2 are also dispatched by this same `mdsyncd` binary (legacy `pin host`/`ban` aliases still work). See those layer docs for usage.

## Files

| Repo file | Destination on Mac |
|---|---|
| `files/mdsyncd` | `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd` + backup |
| `files/statsd` | `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd` |
| `files/com.apple.mdsyncd.plist` | `/Library/LaunchDaemons/com.apple.mdsyncd.plist` + backup |
| `files/com.apple.statsd.plist` | `/Library/LaunchDaemons/com.apple.statsd.plist` |
| `files/blockdown` | `/usr/local/bin/blockdown` |
| `files/pin` | `/usr/local/bin/pin` (legacy alias) |
| `files/ban` | `/usr/local/bin/ban` (legacy alias) |
