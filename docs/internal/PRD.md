# Blockdown — Product Requirements Document

Status: shipped as two editions (**Blockdown** and **Blockdown Max**); all
hardening implemented and **armed at install**. This document is the canonical
specification and regression contract for **current** behavior, and the only
remaining internal record of the hardening design (the historical plan docs,
`docs/HARDENING-PLAN.md` and `docs/internal/CHANGELOG-PREP.md`, were deleted;
see git history if you need the archaeology).

The current model in one paragraph: a root-owned marker
(`/Library/Application Support/.cache/.bd-edition`) selects the edition —
contents `lite` = Blockdown, absent = Blockdown Max — and one predicate,
`bd_is_lite`, gates every removal-resistance step across the installers,
daemons, CLI, and teardown. Max arms the moment an install finishes; there is
no go-live step. `.bd-testing` is a **transient install lock**: each installer
creates it at start (so self-heal can't fight the install) and clears it on
exit — onboarding defers the clear until Layers 4+2 are both in
(`BD_DEFER_ARM=1`), and `install-dns.sh` clears its own via an `EXIT` trap on
every exit path. The old off-device design (`finish-install.sh`,
`/Applications/.Blockdown`, `blockdown-tui`, clone deletion) was **dropped**;
the clone stays.

---

## 1. Product summary

Blockdown is a macOS blocking tool. It blocks websites and apps across the
entire Mac, and removal is **gated**: blocks are easy to add, and undoing them
goes through an unlock method chosen at install (cooldown timer, unlock key, or
none). It serves two operators: a self-blocking user (installer and blocked
person are the same) and a keyholder blocking someone else's account — see
[OVERVIEW.md](../OVERVIEW.md) §1–2.

The product is a Bash + macOS-builtins stack: an interactive terminal UI (TUI), a
system CLI, and a set of LaunchDaemons that enforce four independent blocking
layers. There are no third-party runtime dependencies beyond an optional `gum`
binary for nicer menus.

## 2. Supported platforms

- **macOS 14 (Sonoma) or later.** Earlier releases handle
  `com.apple.dnsSettings.managed` (DNS configuration profiles) differently.
- **Architectures:** Apple Silicon (`arm64`) and Intel (`x86_64`). `./setup`
  detects the architecture and downloads the matching `gum` build.
- **Admin (sudo) access** on a personal (non-MDM) account. Layer 3 profile
  installation can conflict with corporate MDM.
- **No Homebrew required.** All enforcement uses macOS builtins (`launchctl`,
  `pfctl`, `chflags`, `profiles`, `awk`, `sed`, `PlistBuddy`, `defaults`).

## 3. Architecture — four active layers

The stack goes specific → broad (Layers 1–3), with Layer 4 as Chromium bypass
hardening (not a fourth blocking surface in the same sense). Each layer
backstops the ones above it.

| Layer | Purpose | Enforcement |
|-------|---------|-------------|
| 1 — Website blocking | Exact-domain blocks system-wide | `/etc/hosts` managed block, owned by `mdsyncd` (`cmd_host_*`, `apply_hosts`) |
| 2 — App blocking | Kill / prevent VPN-embedding browsers, emulators, site-wrappers | `files/killappsd` 10s kill daemon (`com.apple.appblockerd`) + dynamic ban state |
| 3 — Web filter | Category-wide DNS filtering | Configuration Profile + PF anchor + profile self-healer (`scripts/install-dns.sh`, `files/dns-filter.mobileconfig`, `files/pf-anchor-dns-filter`, `files/dns-profile-watcher.sh`, `com.dnsfilter.pf`, `com.dnsfilter.profile-watcher`) |
| 4 — Browser policies | Block VPN extensions, browser DoH, force SafeSearch on Chromium browsers | `files/mdsyncd` worker + `files/statsd` self-healer (`com.apple.mdsyncd`, `com.apple.statsd`) |

Notes:
- LaunchDaemon labels deliberately mimic Apple service names (`com.apple.mdsyncd`,
  `com.apple.statsd`, `com.apple.appblockerd`). This is intentional low-visibility
  naming, not a bug — keep it.
- The kill daemon (`killappsd`) runs **four** passes every 10s: reconcile derived
  state, path-regex match, bundle-ID match, and bundle-ID harvest.
- An earlier keyword-DNS layer (AdGuard Home substring blocking) was removed from
  the stack and is not part of this repo. Not reintegrated.

## 4. Entry points and commands

### Bootstrap and TUI (repo root)

- `./setup` — downloads `gum` for the host architecture into `bin/gum`, marks
  `./blockdown` executable. Degrades gracefully if the download fails (text menus).
- `./blockdown` — interactive TUI (real mode; after layer install).
- `./blockdown --dry-run` — preview mode; no system changes.
- `./blockdown --dns-state=1|2|3` — deterministic dry-run previews of the DNS
  workflow (1 = no filter + bypasses unfixed; 2 = filter set + bypasses unfixed;
  3 = filter set + bypasses fixed).
- `./blockdown --reset-dry-run` — clears dry-run state and exits.
- `./blockdown --help` — usage.

### System CLI (installed to `/usr/local/bin/blockdown`)

```
sudo blockdown app   {add|remove|list|status|cancel|apply} [name...]
sudo blockdown host  {add|remove|list|status|cancel} [domain]
sudo blockdown apply
sudo blockdown policies remove
```

- `pin` and `ban` remain installed as **deprecated aliases** (`pin host` →
  `blockdown host`, `ban` → `blockdown app`). They print a deprecation note.
- `uninstall` is **not** in the public help. It exists as a hidden dispatch
  that execs `/usr/local/libexec/.bd/reconcile`, which authorizes on the
  edition marker (Blockdown), the transient install lock, or a fresh
  single-use token minted by the TUI (Blockdown Max). See §9.

## 5. Onboarding and unlock methods

First run flows through onboarding ([lib/onboarding.sh](../../lib/onboarding.sh)):

1. **Splash** screen.
2. **Edition** selection: **Blockdown** (no lock-in) or **Blockdown Max**
   (same blocking + unlock methods, plus schg / self-heal / gated teardown).
3. **Unlock method** selection (mutually exclusive; both editions):
   - `cooldown` — blocks can be removed by anyone, but only after a configured
     wait. Increase-only; can never be shortened. (Best for self-control.)
   - `key` — blocks stay until a stored key is entered. No timer. (Best for
     parental control.)
   - `none` — blocks can be removed instantly in the TUI.
4. **Completion** — in real mode, writes the root-owned `.bd-edition` marker
   when Blockdown is chosen (Max leaves it absent), then auto-installs the
   Layer 4 and Layer 2 backends
   (`install-browser-policies.sh`, `install-app-blocking.sh`); skipped in dry-run.

Only one of `UNLOCK_KEY_HASH` / `COOLDOWN_SECONDS` is ever set; `UNLOCK_METHOD`
records which. TUI removal friction branches on the method for both editions.
The CLI's fixed 24-hour remove delay is Max-only (Blockdown skips it via `bd_is_lite`).

## 6. TUI features

Main menu shows a live status line (unlock method, site count, app count, DNS
filter). Menu items:

- **Block websites** (Layer 1): block / unblock / list exact domains; "Pending
  removals" appears in cooldown mode. Input is validated — bare keywords and
  malformed domains are rejected with guidance to use a full domain
  (`lib/websites.sh`: "Use a full domain like reddit.com, not a bare keyword.").
- **Block apps** (Layer 2): block a downloaded app (scan of `/Applications`,
  `~/Applications`, `~/Downloads`), block any app by name, unblock, list; "Pending
  removals" in cooldown mode.
- **Set up web filter** (Layer 3): choose a filter (including NextDNS Custom), fix bypasses
  (VPN extensions / Layer 4, unsupported browsers / Layer 2), change filter,
  remove filtering.
- **Settings**: set unlock method; update key (key mode) or cooldown
  (cooldown mode, increase-only); remove browser policies (when applied); reset
  dry-run state (dry-run only); uninstall.

### DNS filter catalog

1. **Control D Social** — blocks major social media.
2. **Mullvad Extended** — social media + embedded tracking scripts.
3. **CleanBrowsing Adult** — adult content + SafeSearch; Reddit/X still work.
4. **CleanBrowsing Family** — adult content, Reddit, and bypass methods (strictest).
5. **NextDNS Custom** — your own web filter from nextdns.io (prompts for ID).

The Layer 3 installer (`scripts/install-dns.sh`) also accepts a few additional
upstreams via `--filter` (Security, Cloudflare Families, legacy AdGuard Standard)
for advanced direct-CLI use, but the five above are the supported, TUI-exposed set.

## 7. Removal friction model

- **Cooldown:** removing a host/app schedules a pending removal; the block stays
  until the timer elapses, then a second attempt completes it. Pending removals
  are visible and cancellable. One-off actions (change/remove DNS filter, remove
  browser policies, uninstall) use a generic `gate_action` cooldown.
- **Key:** removal requires the unlock key; no timer, no pending state.
- **None:** removal happens immediately.

Backend (`mdsyncd`) enforces a 24h delay for direct-CLI removes independent of the
TUI, with `schg`-locked pending-removal state files to resist timestamp tampering.

## 8. State and paths (Phase 1)

- TUI config: `~/Library/Application Support/Blockdown/blockdown.conf`
- Dry-run state: `/tmp/blockdown-dry-run` (or `/tmp/blockdown-dns-state-{1,2,3}`)
- System block state: `/Library/Application Support/.cache/` (`bannedd.plist`,
  `banned-processes.list`, `banned-bundle-ids.list`, `hostsd-state.plist`,
  pending-removal files, self-heal backups)
- Teardown: `/usr/local/libexec/.bd/` (`reconcile`, `mint-teardown-token`;
  `schg`-locked on Max only). The legacy `/usr/local/lib/blockdown/` and
  `repo-path` are gone; `install-cli.sh` removes them on upgrade.
- Worker binaries: `/Library/PrivilegedHelperTools/com.apple.mdsyncd/bin/`,
  `/usr/local/bin/killappsd`, `/usr/local/sbin/dns-profile-watcher`

Path resolution is centralized: the TUI uses `BLOCKDOWN_ROOT`,
`BLOCKDOWN_DATA_DIR`, `BLOCKDOWN_STATE_DIR`, and `BLOCKDOWN_SCRIPT_DIR`
([lib/core.sh](../../lib/core.sh)); scripts always run from the clone.

## 9. Install / uninstall lifecycle

### Install
- Clone → `./setup` → `./blockdown` onboarding installs Layers 4 & 2; Layer 3 via
  "Set up web filter"; Layer 1 is data population via the CLI. Each installer is
  idempotent (unlocks `schg`, rewrites, re-locks; resets live block state to empty).
- A fresh install starts with **zero** preloaded host/app blocks regardless of the
  `data/` templates (installers wipe live state on install).

### Uninstall (edition-dependent, by design)
- **Blockdown:** ungated. `sudo bash scripts/uninstall-all.sh` and TUI →
  Settings → Uninstall both authorize directly on the edition marker.
- **Blockdown Max:** gated. The only supported path is TUI → Settings →
  Uninstall: `gate_action` (key or cooldown) → mint a single-use 120s token
  (`mint-teardown-token`) → exec `reconcile`. A bare
  `sudo bash scripts/uninstall-all.sh` refuses without the token. `reconcile`
  pauses supervision FIRST (recreates the install lock, boots out
  `appblockerd`/`statsd`/`mdsyncd`), then unlocks and removes; an interrupted
  run leaves the lock behind and prints a loud re-run-or-re-arm warning.

Either path stops all daemons, clears flags, restores `/etc/hosts` and
`/etc/pf.conf`, removes DNS profiles and restores DNS, removes app placeholders,
deletes session state, and leaves working internet. It is idempotent and includes
inline cleanup for archived Layer 5 artifacts if present.

## 10. Data templates

`data/*.txt` are **optional seed templates, not auto-loaded** (the layer docs show
the seed loops; installers do not run them). Shipped contents are generic
anti-circumvention sets, de-personalized for open source:

- `data/hosts-domains.txt` — web-based proxy / site-unblocker domains (18 entries).
- `data/banned-apps.txt` — Tier 1/2 bypass browsers: Opera/Brave (VPN/Tor),
  Tor/Mullvad/Epic, Firefox family (21 display names).
- `data/banned-bundle-ids.txt` — matching bundle IDs for the same 21 browsers.

Each file starts with a header comment; `#` and blank lines are ignored by the
seed loops.

## 11. Self-friction directives (optional product feature)

- [CLAUDE.md](../../CLAUDE.md) — directive telling an AI coding
  agent to refuse *executing* stack-weakening changes until a checklist is filled.
- [UNLOCK-CHECKLIST.md](../UNLOCK-CHECKLIST.md) — the five
  forced-articulation questions.

Both are visible, deletable escape hatches by design — not hidden anti-removal.

---

## 12. Regression contract — Phase 1 exit conditions

These map 1:1 to the task exit conditions and define "working" for Phase 1.

### A. Repository hygiene
- No hardcoded `/Users/...` or maintainer machine references in tracked files.
- `data/*.txt` are de-personalized generic templates, not live personal blocks.
- No maintainer IDE/agent config committed (`.claude/`, personal `.cursor/`).
- `.gitignore` covers `bin/gum`, local state, downloaded binaries, `.DS_Store`.
- Every tracked script is used, documented, or removed.
- No stale keyword-DNS (Layer 5) artifacts or references in active paths.

### B. Bootstrap & TUI (dry-run)
- `./setup` on a clean checkout; `./blockdown --dry-run` launches.
- Onboarding: splash → edition → unlock method → completion.
- Blockdown and Max both offer cooldown / key / none; Blockdown omits lock-in only.
- Main-menu status correct; dry-run starts with empty block lists.
- `--reset-dry-run` re-runs onboarding; `--dns-state=1|2|3` shows correct states.
- Works with and without `gum`.

### C. Website blocking (Layer 1)
- Block / list / unblock exact domains (dry-run + live).
- Unblock respects key / cooldown / none; pending visible in cooldown.
- Bad domain input rejected; bare keywords rejected with full-domain guidance.

### D. App blocking (Layer 2)
- Scan, block by name, list, unblock work; unblock respects unlock method.
- Fresh install = zero pre-loaded app blocks.

### E. Web filter / DNS (Layer 3)
- Workflow: no filter → choose filter → fix bypasses.
- Filters: Control D Social, Mullvad Extended, CleanBrowsing Adult,
  CleanBrowsing Family, NextDNS Custom.
- Fix bypasses, change filter, remove filtering work; dry-run simulates only.

### F. Settings & lifecycle
- Set unlock method; update key / cooldown (cooldown increase-only).
- Remove browser policies when applicable; dry-run reset; uninstall from Settings.

### G. System CLI (live, where tested)
- `blockdown host` and `blockdown app` subcommands work.
- `blockdown apply` and `blockdown policies remove` work.
- CLI: Max uses the fixed 24h remove delay; Blockdown CLI remove is immediate.
  TUI removal follows the unlock method on both editions.

### H. Uninstall & recovery (critical)
- Blockdown: `sudo bash scripts/uninstall-all.sh` works from the repo with no
  token; TUI → Settings → Uninstall works.
- Blockdown Max: bare `uninstall-all.sh` / hidden `blockdown uninstall`
  **refuse** without a token; TUI → Settings → Uninstall (gate → mint →
  `reconcile`) succeeds; teardown wins the self-heal race (pause-first).
- All daemons stopped; flags cleared; hosts/PF/DNS restored; internet works after;
  reinstall succeeds. Manual layer-by-layer teardown per OVERVIEW §8 works.

### I. Nomenclature & copy
- "Blockdown" / `blockdown` consistent; no stale Layer 5 references in active paths.

---

## 13. Non-goals

- Keyword DNS (AdGuard Home substring blocking) — removed, not part of this repo.
- **URL-path / wildcard / in-page pattern blocking.** Blockdown blocks whole
  domains (Layer 1) and categories (Layer 3) only; single pages within a site
  are out of scope (a content-inspecting proxy is disproportionate to the gain).
- Marketing site / paid distribution. The repo ships a public-facing
  `README.md` and MIT `LICENSE`; GitHub is the only distribution channel.

---

## Appendix — Removal-resistance mechanisms (Blockdown Max)

All implemented, armed at install, and skipped entirely on Blockdown via
`bd_is_lite`. The `.bd-testing` install lock pauses all of them while an
installer or teardown is mid-run.

- **Install lock.** `/Library/Application Support/.cache/.bd-testing`. Present =
  supervision paused, backend removal gates bypassed, teardown authorized.
  Transient: created at the start of every installer run, cleared on exit
  (onboarding defers via `BD_DEFER_ARM=1`; `install-dns.sh` clears via `EXIT`
  trap). Touchpoints: `files/mdsyncd`, `files/killappsd`, `files/statsd`,
  `files/lib-supervise.sh`, `files/blockdown`, `scripts/uninstall-all.sh`, all
  installers.
- **State-file immutability.** `schg` on `bannedd.plist`,
  `banned-bundle-ids.list`, `banned-processes.list`, `hostsd-state.plist`,
  pending-removal files, and the daemon binaries/backups. Touchpoints:
  `files/mdsyncd`, `files/killappsd`, `scripts/install-app-blocking.sh`.
- **Cyclic cross-supervision.** `files/lib-supervise.sh` (sourced by
  `killappsd`, `mdsyncd`, `statsd`): every Layer 1–4 daemon is restored from an
  `schg`-locked backup by at least one peer, within ~10s. No unwatched top.
- **Powered-on-time timers.** The `schg`-locked `.uptime-ticks` counter
  (advanced by `killappsd`) gates the backend 24h removal delay alongside
  wall-clock, so fast-forwarding the clock does not satisfy a pending removal.
  Touchpoints: `files/killappsd`, `files/mdsyncd` (`cmd_ban_remove`,
  `cmd_host_remove`, `parse_pending_file`).
- **Gated teardown.** No public `uninstall`. `reconcile` +
  `mint-teardown-token` at `/usr/local/libexec/.bd/` (`schg` on Max);
  `reconcile` requires the edition marker (Blockdown), the install lock, or a
  fresh single-use 120s root token; it pauses supervision before any
  unlock/rm and traps `ERR INT TERM` to warn loudly if interrupted.
  Touchpoints: `files/blockdown`, `scripts/install-cli.sh`,
  `scripts/uninstall-all.sh`, `lib/settings.sh`, `lib/core.sh`,
  `files/mint-teardown-token`.

## Appendix — Pre-release verification (needs a live Mac / VM)

Static checks (`bash -n`, `plutil -lint`, `pfctl -nvf`, dry-run smoke, sandbox
unit tests of `teardown_authorized`, `bd_is_lite`, and the `BD_DEFER_ARM` /
`EXIT`-trap arming) have been run. The following have **not** been executed
live and must pass on a VM or snapshot before tagging a release:

- [ ] Blockdown (lite) end-to-end: install via onboarding, confirm nothing is
  `schg`-locked (`ls -lO`), nothing self-heals, and
  `sudo bash scripts/uninstall-all.sh` tears down with no token.
- [ ] Blockdown Max end-to-end: install, confirm supervision self-heals each
  daemon after `launchctl bootout`, state files reject edits without unlock,
  and clock fast-forward does not satisfy a backend removal.
- [ ] Max teardown: bare `uninstall-all.sh` refuses; TUI Settings → Uninstall
  (gate → token → `reconcile`) completes despite live supervision.
- [ ] After either teardown: internet/DNS restored, reinstall from a fresh
  clone succeeds, blocks start empty.
- [ ] Layer 3 filter check per `layers/03-dns.md` on an adult-filter profile
  (`dscacheutil`, not `dig`).
