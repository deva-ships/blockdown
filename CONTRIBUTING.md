# Contributing to Blockdown

This file explains how the repo is organized, how the pieces fit together at runtime, and where to make common changes. Design rationale and the threat model live in [docs/OVERVIEW.md](docs/OVERVIEW.md); this is the code-level map.

## The two planes

Blockdown code runs in two different places, and the repo layout follows that split:

1. **The repo plane** (runs from the clone, as your normal user): the `./blockdown` TUI and everything in `lib/`. It keeps its state in `~/Library/Application Support/Blockdown/blockdown.conf` and shells out to `sudo` only for the moments that need root.
2. **The system plane** (runs as root from system paths): everything in `files/` is a *source* that an installer in `scripts/` copies to a system location. Editing `files/mdsyncd` changes nothing on a machine until an installer copies it into place.

The `/usr/local/bin/blockdown` CLI ([files/blockdown](files/blockdown)) is the bridge: a thin shim that execs the installed `mdsyncd` worker. The TUI calls that same CLI for real block operations, so the TUI and CLI never have separate block state.

## The four layers

Numbered specific → broad, matching the TUI surfaces. Layer 4 is bypass hardening (not a fourth blocking surface in the same sense as 1–3), but it also installs the shared `mdsyncd` worker that Layers 1 and 2 use.

| Layer | Blocks | Enforced by | Installer | TUI surface |
|---|---|---|---|---|
| 1 Website blocking | Exact domains | `mdsyncd` rendering `/etc/hosts` from a state file | installed with Layer 4 | [lib/websites.sh](lib/websites.sh) |
| 2 App blocking | Named apps, renamed copies | `killappsd` kill-on-launch (path regex + bundle ID) | [scripts/install-app-blocking.sh](scripts/install-app-blocking.sh) | [lib/apps.sh](lib/apps.sh) |
| 3 Web filter | Whole categories (adult, social, ...) | DoH configuration profile + PF firewall anchor + profile self-healer | [scripts/install-dns.sh](scripts/install-dns.sh) | [lib/dns.sh](lib/dns.sh) |
| 4 Browser policies | VPN/proxy extensions, browser DoH, SafeSearch | `mdsyncd` writing managed-preferences plists | [scripts/install-browser-policies.sh](scripts/install-browser-policies.sh) | [lib/dns.sh](lib/dns.sh) (Fix bypasses), [lib/settings.sh](lib/settings.sh) (remove) |

Manual install order follows dependencies, not layer numbers: Layer 4 first (worker + CLI), then Layer 2, then Layer 1 data, then Layer 3 (independent; can go anytime). See [layers/README.md](layers/README.md).

Cross-layer: [files/lib-supervise.sh](files/lib-supervise.sh) is sourced by all three daemons and restores any missing daemon file from `schg`-locked backups in `/Library/Application Support/.cache/`. This supervision (Blockdown Max only) and the CLI's 24-hour removal delay are paused while the testing marker `/Library/Application Support/.cache/.bd-testing` exists. The marker is a **transient install lock**: each installer creates it at the start of its run so self-heal can't fight the install, and clears it at the end (onboarding clears it once after Layers 4+2). Blockdown Max is fully armed the moment installs finish — there is no separate go-live step.

## File map

Payloads in `files/` and where they land:

| Repo file | Installed at | Role |
|---|---|---|
| `files/mdsyncd` | `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/mdsyncd` | The Layer 1/2/4 worker: hosts backend, app-ban backend, browser policies, removal cooldown |
| `files/killappsd` | `/usr/local/bin/killappsd` | Layer 2 kill daemon, every 10s: reconcile, path-kill, bundle-ID kill, bundle-ID harvest |
| `files/statsd` | `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/statsd` | Secondary restorer in the supervision cycle |
| `files/lib-supervise.sh` | `.../com.apple.mdsyncd/bin/lib-supervise.sh` | Shared supervision functions, sourced by all three daemons |
| `files/dns-profile-watcher.sh` | `/usr/local/sbin/dns-profile-watcher` | Re-queues the DNS profile install if the profile is removed |
| `files/blockdown`, `files/pin`, `files/ban` | `/usr/local/bin/` | CLI shim + legacy aliases |
| `files/com.apple.*.plist`, `files/com.dnsfilter.*.plist` | `/Library/LaunchDaemons/` | launchd schedules for the above |
| `files/dns-filter.mobileconfig` | generated per filter, backup at `/Library/PrivilegedHelperTools/` | DoH profile template (installer substitutes IPs, DoH URL, IDs) |
| `files/pf-anchor-dns-filter` | `/etc/pf.anchors/dns-filter` | PF rules: allow port 53 only to the active filter, block DoT and known DoH endpoints |

The daemon names imitate Apple services on purpose (low visibility for the self-control use case, stated in the README). Do not rename them: install paths, backups, supervision, and the docs are coupled to those names.

TUI libraries in `lib/`, all sourced by `./blockdown`:

- `core.sh` dry-run plumbing, paths, the CLI bridge, counting and formatting helpers
- `ui.sh` menus and prompts, gum when available with a plain-bash fallback
- `state.sh` config read/write and dry-run state seeding
- `onboarding.sh` first run: choose the unlock method, install Layers 4 and 2
- `removal.sh` the friction gates (see below)
- `websites.sh`, `apps.sh`, `dns.sh`, `settings.sh` one file per screen

## Unlock modes

The mode is a single config value (`UNLOCK_METHOD` = `cooldown`, `key`, or `none`), read through `unlock_method()` in [lib/core.sh](lib/core.sh). All mode-dependent behavior goes through exactly two dispatch points, both in [lib/removal.sh](lib/removal.sh):

- `attempt_removal()` for unblocking a website or app (per-item, with its own pending timer per type).
- `gate_action()` for one-off actions not tied to a list item: changing or removing the DNS filter, removing browser policies, uninstalling.

Each has one function per mode (`_attempt_removal_key`, `_attempt_removal_cooldown`, ...). Mode selection and its config writes live in [lib/onboarding.sh](lib/onboarding.sh). To add a mode, add a case at those two dispatch points and an onboarding/settings screen; nothing else branches on the mode.

Separately from the TUI gate, the backend CLI (`mdsyncd`) has its own fixed 24-hour, two-call removal delay. The TUI passes `--confirmed` after its own gate has passed ([lib/core.sh](lib/core.sh), `_blockdown_remove`) so the two gates do not stack.

## Where to make common changes

- **Add a web filter:** the TUI catalog in [lib/dns.sh](lib/dns.sh) (`_dns_choose_filter`, `_dns_filter_summary`, `_dns_filter_detail`) plus the name-to-endpoint mapping in [scripts/install-dns.sh](scripts/install-dns.sh) (the `--filter` case and the `FILTER_CHOICE` block). If the provider's own DoH endpoint appears in the PF anchor's blocklist, add a carve-out in `carve_out_active_provider`.
- **Add a browser to the "unsupported browsers" set:** `_DNS_UNSUPPORTED_BROWSERS` and the bundle map in `_dns_detect_unsupported_browsers` in [lib/dns.sh](lib/dns.sh), plus the seed templates in `data/`.
- **Change what blocking or unblocking does:** TUI side in [lib/websites.sh](lib/websites.sh) / [lib/apps.sh](lib/apps.sh); backend behavior in [files/mdsyncd](files/mdsyncd) (`cmd_host_*`, `cmd_ban_*`, `apply_hosts`, `apply_app_blocks`).
- **Change browser policy keys:** `apply_chromium_policies` and `apply_chromium_extras` in [files/mdsyncd](files/mdsyncd); the browser detection list is `CHROMIUM_BUNDLES` + `detect_chromium_browsers`.
- **Change the kill behavior:** [files/killappsd](files/killappsd); its inputs (`banned-processes.list`, `banned-bundle-ids.list`) are derived state owned by `mdsyncd`'s `apply_app_blocks`.
- **Change self-healing:** [files/lib-supervise.sh](files/lib-supervise.sh), and keep the backup seeding in the installers in sync.

## Testing changes

- `./blockdown --dry-run` runs the whole TUI against throwaway state in `/tmp/blockdown-dry-run` with every `sudo` command echoed instead of executed. `--dns-state=N` (1 to 3) previews the web-filter workflow at each stage. `--reset-dry-run` wipes preview state.
- Static checks that must pass: `bash -n` on every script, `plutil -lint` on every plist and the mobileconfig, `pfctl -nvf files/pf-anchor-dns-filter`.
- Installer and daemon changes: test in a VM or on a snapshot, never first on your main Mac. The invariant to protect: `sudo bash scripts/uninstall-all.sh` must always leave DNS and the internet working.
- There is no automated test suite; the dry-run mode and the installers' built-in verification steps are the current coverage.

## Conventions

- Everything is bash targeting macOS's system `/bin/bash` (3.2). No bash-4 features (no associative arrays, no `${var,,}`), no Homebrew dependencies. The only optional binary is `gum`, downloaded by `./setup`, with a plain-bash fallback in `lib/ui.sh`.
- Protected files follow one pattern: `chflags noschg`, write, `chmod`, `chflags schg`. If you add a state file a daemon must survive tampering of, give it the same lock helpers and a seeded backup.
- Asymmetry is the point: adding a block must stay cheap, removing one must go through a gate. Keep that in mind before "simplifying" a removal path. Relatedly, [CLAUDE.md](CLAUDE.md) at the repo root asks AI coding assistants to hold weakening changes to a checklist; it is part of the design, not clutter.
