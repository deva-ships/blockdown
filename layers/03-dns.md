# Layer 3 — Web Filter (DNS Enforcement)

**Goal:** Every DNS query on this Mac, from any app, with or without a VPN, is routed through a chosen filtered DoH resolver. Depending on the filter, blocked sites return NXDOMAIN or a sinkhole address.

**Filter catalog (matching the TUI "Set up web filter"):**

- **Control D Social** — blocks major social media (TikTok, Instagram, Facebook, X, Reddit, Snapchat, Discord).
- **Mullvad Extended** — blocks social media plus tracking scripts embedded in normal sites.
- **CleanBrowsing Adult** — blocks adult content and enables SafeSearch; Reddit and X still work.
- **CleanBrowsing Family** — blocks adult content, Reddit, and known filter-bypass methods (strictest).
- **NextDNS Custom** — your own web filter from nextdns.io. The TUI prompts for the ID (CLI: `--filter "NextDNS Custom" --nextdns-id <id>`).

The installer also accepts a few additional upstreams via `--filter` (Security, Cloudflare Families, and legacy AdGuard Standard) for advanced use.

**Why it exists here:** Broadest category block. Fires before TCP connect. Independent of browser / VPN / app. Sits above the VPN stack in macOS's network priority (Filters & Proxies is higher than VPN). Layers 1–2 are precise (named domains and apps); Layer 3 is the category-wide backstop.

---

## What this layer installs

1. A macOS Configuration Profile (identifier depends on the chosen filter, e.g. `com.cleanbrowsing.dns.profile`, `com.adguard.dns.standard`, `com.controld.dns.social`, `net.mullvad.dns.extended`) installed at **system scope** that routes all DNS through the selected DoH resolver.
2. A PF (packet filter) anchor at `/etc/pf.anchors/dns-filter` that:
   - Allows port-53 traffic ONLY to CleanBrowsing's IPs; blocks all other port-53 traffic. (macOS PF's `rdr` rules cannot redirect local outgoing traffic; the block-based approach is more reliable.)
   - Blocks all IPv6 port-53 traffic. Forces apps to fall back to IPv4 (then handled above).
   - Blocks DNS-over-TLS (port 853) globally.
   - Blocks DNS-over-HTTPS to 200+ known DoH server IPs via both TCP and UDP (the UDP rule catches QUIC/HTTP3-based DoH).
3. A LaunchDaemon (`com.dnsfilter.pf`) that loads the PF rules at boot.
4. A **profile self-healer**: a backup mobileconfig at `/Library/PrivilegedHelperTools/dns-filter.mobileconfig`, a watcher script at `/usr/local/sbin/dns-profile-watcher`, and a LaunchDaemon `com.dnsfilter.profile-watcher` that re-queues the profile install every 60 seconds whenever the profile is missing.

## Prerequisites

- macOS 14+.
- All files referenced below exist in the repo under `files/`.
- Run the installer with `sudo`.

## Install

Run the automated installer. It handles everything, including prompting you to choose a filter level.

```bash
sudo ./scripts/install-dns.sh
```

The installer will:

1. Ask you to select a filter (interactive menu defaults to CleanBrowsing Adult; TUI includes NextDNS Custom).
2. Install the PF anchor at `/etc/pf.anchors/dns-filter`.
3. Back up `/etc/pf.conf` and safely inject the required anchor lines.
4. Install and load the PF LaunchDaemon. Activate PF immediately (no reboot required).
5. Generate the mobileconfig into your user Application Support folder and open it (macOS queues it as a pending profile).
6. Pause and wait for you to complete the GUI profile installation (see below).
7. Install the profile self-healer (backup mobileconfig + watcher script + watcher daemon).
8. Lock all five protected files with `schg`.
9. Run all four verification checks and report pass/fail.

### Required GUI step (during install)

When the installer pauses and instructs you, complete the profile installation:

1. Open **System Settings → Privacy & Security → Profiles** (macOS 14). On macOS 15 and later the pane moved: **System Settings → General → Device Management**. The installer prints the path that matches your macOS version.
2. Click the pending profile entry for your chosen filter.
3. Click **Install**, enter your admin password.
4. Return to the terminal and press Enter to continue.

## Verification

The installer runs these checks automatically. You can re-run them manually at any time:

```bash
# DNS filter active — must return empty (NXDOMAIN)
dig +short pornhub.com
```

Expected: empty output (or a timeout error if the PF block fires before the resolver responds). Note: this specific check only applies to filters that block adult content (CleanBrowsing Adult/Family). For Control D Social, Mullvad Extended, or NextDNS Custom, verify with a domain that filter actually blocks instead.

```bash
# Profile installed
sudo profiles list -all 2>&1 | grep -i cleanbrowsing
```

Expected: shows `com.cleanbrowsing.dns.profile` (or the profile ID for your chosen filter).

```bash
# Self-healer daemon running
sudo launchctl list | grep com.dnsfilter
```

Expected: shows both `com.dnsfilter.pf` and `com.dnsfilter.profile-watcher`.

```bash
# CleanBrowsing is the active resolver
scutil --dns | grep -i cleanbrowsing
```

Expected: shows CleanBrowsing as the active DoH resolver. **Note:** if you have an active VPN that pushes its own DNS configuration, CleanBrowsing may not be the primary resolver visible to `scutil`. Test actual filtering with `dig +short pornhub.com` instead.

## Safeguards — what actually protects this layer

**Important:** the original threat model assumed `PayloadRemovalDisallowed=true` would make the profile un-removable. **This is not true for non-MDM (locally installed) profiles on macOS 14+.** macOS silently ignores that flag in that scenario. The actual protection is built from three independent mechanisms:

1. **PF cascade**: If you remove the profile, the system resolver falls back to DHCP-provided DNS. PF blocks all port-53 traffic except to CleanBrowsing's IPs, so DNS effectively stops working entirely. Without the profile, the Internet doesn't function until PF is also unlocked and edited.

2. **Profile self-healer**: The `com.dnsfilter.profile-watcher` daemon checks every 60 seconds whether the profile is installed. If missing, it opens the locked backup mobileconfig in the console user's session via `launchctl asuser`, which surfaces macOS's standard System Settings approval prompt — the same UI you see when double-clicking a mobileconfig file. To permanently remove the profile, you would need to dismiss this prompt every 60 seconds — or stop the daemon first.

3. **`schg` locks on all infrastructure files**. Modifying any of these requires a deliberate `sudo chflags noschg <file>` first:
   - `/etc/pf.anchors/dns-filter` (PF rules)
   - `/Library/LaunchDaemons/com.dnsfilter.pf.plist` (PF daemon)
   - `/Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist` (watcher daemon)
   - `/usr/local/sbin/dns-profile-watcher` (watcher script)
   - `/Library/PrivilegedHelperTools/dns-filter.mobileconfig` (backup mobileconfig)

### What this means in practice

The `−` button in System Settings → Profiles **will** appear active. Clicking it **will** remove the profile. But the self-healer will re-queue installation within 60 seconds, and the PF cascade means the Internet is non-functional in the meantime.

To truly disable Layer 3, you would need to:

1. Unlock `/Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist` with `chflags noschg`.
2. `launchctl bootout system /Library/LaunchDaemons/com.dnsfilter.profile-watcher.plist`.
3. Remove the profile via System Settings or `sudo profiles remove -identifier ...`.
4. Unlock `/etc/pf.anchors/dns-filter` with `chflags noschg`.
5. Edit the anchor to allow other DNS, reload PF.

That is a deliberate, multi-step, file-by-file process — the friction this layer is designed to produce.

## Re-running the installer

If you need to change the filter level or update the files, the installer is idempotent and handles the unlock for you:

```bash
sudo ./scripts/install-dns.sh
```

The installer will unlock any existing `schg`-locked files, write fresh content, and re-lock at the end. There is no need to manually `chflags noschg` first.

## How to actually use this layer

There's nothing to add or remove at Layer 3 during normal operation. The CleanBrowsing filter handles all adult sites automatically. To switch filter levels (e.g., from Adult to Family), re-run the installer as described above.

## What Layer 3 does NOT catch

- Browsers with their own DoH enabled. (Layer 4 handles this by locking `DnsOverHttpsMode=off`.)
- Apps tunneling DNS inside a VPN they control. (Layer 2 handles this by blocking the apps themselves.)

## Files

| Repo file | Purpose |
|---|---|
| `files/dns-filter.mobileconfig` | DNS Configuration Profile template (Adult Filter defaults, system-scoped) |
| `files/pf-anchor-dns-filter` | PF anchor rules (port-53 block, DoT/DoH blocks, IPv6 block) |
| `files/com.dnsfilter.pf.plist` | LaunchDaemon that loads PF at boot |
| `files/dns-profile-watcher.sh` | Watcher script that re-queues profile install on removal |
| `files/com.dnsfilter.profile-watcher.plist` | LaunchDaemon that runs the watcher every 60s |
| `scripts/install-dns.sh` | Automated installer — run this |
