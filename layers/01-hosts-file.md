# Layer 1 — Website Blocking (Hosts File)

**Goal:** Block specific domains at the system resolver level, via `/etc/hosts`. Exact domains you choose one by one — e.g. Reddit media subdomains, Imgur, Gfycat, web proxies, specific file-share hosts.

**Why it exists here:** This is the precise, user-driven surface. Category filters (Layer 3) catch what an upstream considers "adult" or "social," which misses a lot of SFW-by-default sites that host NSFW content (Reddit, Imgur, deviantart, etc.). Layer 1 is the fine-tuning layer for whole-domain blocks you name yourself.

Layer 1 sits below Layer 3 in breadth because it requires you to know the specific domain — it's not a category match. Layers 2–4 are broader or bypass-hardening; Layer 1 is precise.

---

## How it works

- `/etc/hosts` is checked by the macOS resolver *before* any DNS request leaves the machine. An entry `0.0.0.0 example.com` resolves `example.com` to loopback, so the connection dies instantly.
- Every domain gets **both** an IPv4 (`0.0.0.0`) and an IPv6 (`::1`) entry. Without the IPv6 entry, a dual-stack app could reach the real server via AAAA records.
- Entries live inside a marker block: `# BLOCKER-MANAGED-START` / `# BLOCKER-MANAGED-END`. The worker only touches what's between markers; any user-added content outside is preserved.
- `/etc/hosts` is `schg`-locked at rest. The worker unlocks → modifies → re-locks, atomically.
- After every write, `dscacheutil -flushcache` and `killall -HUP mDNSResponder` flush the OS resolver cache.

### Source of truth: state file, not `/etc/hosts`

The canonical list of managed domains lives in **`/Library/Application Support/.cache/hostsd-state.plist`** (base64-encoded via PlistBuddy, `schg`-locked). `/etc/hosts` is a *rendered view* of that state.

The worker's `apply_hosts` function reconciles them on every daemon cycle:

1. **First-run migration:** if the state file is missing but `/etc/hosts` has a managed block, seed state from the file (preserves whatever was already blocked).
2. **Idempotent comparison:** if the sorted domain set in state matches the file, do nothing (no write, no DNS flush).
3. **Self-heal on drift:** if they diverge (file changed manually; daemon wasn't run), rewrite `/etc/hosts` from state and flush DNS.

**Consequence:** if someone `chflags noschg`s `/etc/hosts` and deletes a line, the next daemon cycle undoes it. To actually drop a domain, they'd need to tamper with both the state file (`schg`-locked) AND `/etc/hosts`, AND stop the daemon — the standard multi-file-unlock pattern the rest of the system uses.

The daemon triggers on:
- Every hour (`StartInterval=3600`).
- Any change to `/etc/hosts` (WatchPaths trigger, typically fires within ~seconds).
- Any change to `/Library/Managed Preferences` or `/Applications` (existing triggers).

The implementation is inside the `mdsyncd` worker — specifically `apply_hosts`, `read_hosts_state`, `write_hosts_state`, `rewrite_managed_block`, and the `cmd_host_*` commands.

## What this layer installs / configures

Nothing new on disk — Layer 4's `mdsyncd` already ships the Layer 1 CLI. This layer is purely data population: adding the specific domains from `data/hosts-domains.txt` to `/etc/hosts` via the CLI.

## Prerequisites

- Layer 4 complete (mdsyncd and `blockdown` CLI installed).
- `data/hosts-domains.txt` exists in the repo, one bare domain per line.
- `/etc/hosts` is writable (may need `sudo chflags noschg /etc/hosts` if a previous install left it locked with no content).

## Install steps

### Step 1 — Populate the hosts file from the data list

```bash
while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    [[ "$domain" == \#* ]] && continue          # skip comments
    sudo blockdown host add "$domain"
done < $REPO/data/hosts-domains.txt
```

The `blockdown host add` command is idempotent: existing entries print "Already blocked" and skip. Safe to run multiple times.

### Step 2 — Verify the file is locked

```bash
ls -lO /etc/hosts | awk '{print $5}'
```

Expected: `schg`. (The CLI re-locks automatically after every write.)

## Verification

```bash
sudo blockdown host list
```

Expected: the domains you seeded from `data/hosts-domains.txt` (plus their auto-added `www.` variants).

```bash
grep -c "BLOCKER-MANAGED" /etc/hosts
```

Expected: `2` (one START marker, one END).

```bash
dscacheutil -q host -a name i.redd.it
```

Expected: `ip_address: 0.0.0.0` and `ipv6_address: ::1` — the hosts-file override. (Note: `dig` is NOT the right tool here — it queries DNS directly and bypasses `/etc/hosts` entirely. Always use `dscacheutil` or `getent hosts` / `scutil --dns` to verify hosts-file entries.)

Or in Python for a quick cross-check:

```bash
python3 -c "import socket; print(socket.gethostbyname('i.redd.it'))"
```

Expected: `0.0.0.0`.

## Safeguards

- **`/etc/hosts` `schg`-locked** at rest. Requires `sudo chflags noschg` to modify directly.
- **State file `hostsd-state.plist` `schg`-locked** at rest. Single source of truth for what's blocked.
- **Self-healing on tampering** — any line you manually delete from `/etc/hosts` is re-added by the daemon within seconds (or ≤1 hour worst case). No backup to maintain; state file IS the backup.
- **24-hour removal delay on CLI-driven removes.** Two-call pattern: schedule, wait 24h, complete. A single command cannot remove an entry immediately. The pending removal state files are `schg`-locked to prevent timestamp tampering.
- **Marker block convention** — the worker never touches anything outside the markers, so any manual user additions outside the block survive (they just aren't CLI-managed).

## How to actually use this layer

### Add a domain

```bash
sudo blockdown host add reddit.com
```

Takes effect immediately in most apps; browsers may cache DNS for ~60 seconds.

### Remove a domain (24-hour delay)

```bash
sudo blockdown host remove reddit.com     # schedules removal, tells you to wait 24h
# ... 24 hours later ...
sudo blockdown host remove reddit.com     # actually removes
```

### Check status

```bash
sudo blockdown host list                  # current blocked domains
sudo blockdown host status                # shows pending removal + time remaining
sudo blockdown host cancel                # cancels a pending removal
```

### What's in the sample `data/hosts-domains.txt`

The shipped file is a **web-proxy starter set** — 18 bare domains for services that
let you paste any URL and browse through their server (Layer 3's DNS categories
won't flag these as adult; Layer 2 handles VPN-in-browser apps instead):

- `croxyproxy.com`, `croxyproxy.rocks`, `croxyproxy.net`
- `proxysite.com`, `proxyium.com`, `kproxy.com`
- `4everproxy.com`, `4everproxy.net`, `blockaway.net`, `yuyuproxy.com`
- `proxyorb.com`, `proxykuy.com`, `proxypal.net`, `proxygratis.id`
- `hide.me`, `hidester.com`, `www-proxy.hidester.one`
- `proxyscrape.com`

The CLI auto-adds `www.` for each bare domain. List subdomains explicitly when
needed (e.g. `www-proxy.hidester.one`).

A fresh install blocks **nothing** by default — this file is an optional seed. Add
your own targets (Reddit media subdomains, Imgur, social sites, etc.) with
`sudo blockdown host add <domain>`, or edit `data/hosts-domains.txt` before running
Step 1. Lines starting with `#` and blank lines are ignored.

## What Layer 1 does NOT catch

- URL paths within an allowed domain (e.g., you need `reddit.com/r/programming` but not `reddit.com/r/nsfw`). Out of scope: `/etc/hosts` blocks whole domains only.
- Keyword matching in URLs or page content. Out of scope for the same reason.
- Apps tunneling through a non-system resolver. That's what PF anchor (Layer 3 companion) and Layer 2 are for.

## Files and data

| Repo data | Effect |
|---|---|
| `data/hosts-domains.txt` | List of bare domains to block via `blockdown host add` |

No separate binary / plist for this layer — everything is inside the `mdsyncd` worker from Layer 4.
