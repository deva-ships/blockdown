# OVERVIEW — Why Blockdown Exists and How It Holds

This document explains the reasoning: why the project exists, who it defends against, the design principles, and how the pieces back each other up. For install and daily use, start at the [README](../README.md). Implementation details per blocking surface are in [`../layers/`](../layers/).

---

## 1. Why Blockdown exists

Your computer should do what you want. Most software now wants something else from you: attention, held as long as possible, because that's what the business model pays for. The result is a machine that technically belongs to you but spends much of its time negotiating against you.

macOS ships a feature for this, Screen Time, and it fails in a specific way: it leaves the decision revocable at the exact moment the decision matters. Limits come off with a tap. Website blocks don't hold across browsers. There's no answer to the workarounds anyone can find in minutes: a new browser, a VPN extension, a different DNS setting. A limit you can dismiss the moment it binds is not control, it's a suggestion.

Blockdown is built on the opposite premise. You decide, while thinking clearly, what your Mac will and won't open, and the machine keeps that decision. Removing a block goes through an unlock you chose up front: a wait you set in advance, or a key only a parent holds. Nobody actually wants unlimited access to everything. Blockdown is for setting a limit and having your computer keep it.

Two people use it:

- **Blocking yourself** (cooldown mode). You are both the installer and the person being blocked. The unlock is a wait, sized so that the moment of weakness passes before the wait does. By the time the timer expires, you usually agree with the person who set it.
- **Blocking for someone else** (key mode). A parent enforcing blocks on a kid's Mac. The unlock is a key the kid doesn't have. A block that comes off in two clicks is not a block, so Blockdown Max makes removal genuinely hard rather than merely inconvenient (§6).

## 2. Who it defends against

The adversary is not a hacker. It is:

- **In cooldown mode: you, later.** Same admin password, same muscle memory, a few minutes of motivation. Empirically the pull to bypass a blocker decays fast, in minutes to hours. The design goal is that the cheap exits cost more time than the pull lasts. The user runs `sudo` daily for normal work, so `sudo` alone is not friction; every gate must sit above that bar.
- **In key mode: a smart, motivated kid.** Strongest when the kid's account has no admin rights; then the enforcement below is effectively a wall. Against a blocked person *with* admin credentials, Max is a very high cost, not an absolute one (§8).

Explicitly out of scope: forensic tooling, booting from external media, firmware-password tricks (Blockdown deliberately sets none, see §7), and malware running as root.

A legitimate commercial VPN is *not* an adversary: the system is designed to coexist with one (§5).

## 3. Three guiding principles

### Principle 1 — Avoid whack-a-mole

Each bypass should be killed at the most general level available, not chased site by site. Blocking one social site at a time is the Screen Time failure mode; blocking the category once, plus the mechanisms that could route around the category, is the fix. If you find yourself adding the 50th individual domain, the leak is at a broader level and should be fixed there.

### Principle 2 — High friction to unlock, low friction to whitelist

Undoing protection is expensive by design. Correcting a false positive is cheap by design. These must stay decoupled, or the user either never blocks anything (fear of friction) or tears the whole system down to unblock one thing. Concretely: unblocking one website or app is a normal, gated operation (wait out the timer or type the key); dismantling the enforcement itself is a multi-file, multi-step engineering exercise against daemons that repair it (§6).

### Principle 3 — Fully self-enforceable, minimal overlap with normal work

No "give a friend your admin password" tricks, no second user account for daily life. The user keeps full admin access for normal work, so removal mechanisms must not overlap with anything normal work does. That is why the pivot is the `schg` system-immutable flag: clearing it (`chflags noschg`) is a distinct, deliberate act that ordinary admin work never performs.

## 4. What blocks what

Three blocking layers, from specific to broad, plus browser-policy hardening (Layer 4):

| Layer | Blocks | How |
|---|---|---|
| **1 — Website blocking** | Exact domains, chosen one by one | `/etc/hosts` entries (IPv4 + IPv6), rendered from a locked state file owned by a daemon. Checked by the OS before any DNS lookup, so it applies to every browser and app, including private windows. |
| **2 — App blocking** | Apps by name and bundle ID | The `killappsd` daemon runs four passes every 10 seconds: reconcile derived state, kill by path pattern (catches `App (1).app` re-downloads), kill by bundle ID (catches renames), and harvest bundle IDs of newly installed copies. Changing a bundle ID requires re-signing the app, which is above the cost bar in §2. |
| **3 — Web filter** | Whole categories (social media, adult content, or your own NextDNS rules) | A DNS-over-HTTPS configuration profile points the entire Mac at a filtering resolver. Filters offered: Control D Social, Mullvad Extended, CleanBrowsing Adult, CleanBrowsing Family, and NextDNS Custom. Filtering happens before a connection is attempted, below every app. Enforced by the profile + PF firewall anchor + profile self-healer. |

Blockdown stops at whole domains and categories on purpose. Blocking one page but not a whole site (one subreddit, a search term) needs a content-inspecting proxy, which is a large amount of moving parts for a narrow gain, so it is out of scope.

## 5. Bypass protection (Layer 4 — browser policies)

Layers 1–3 would each leak on their own. Layer 4 is not a fourth blocking surface in the same sense; it hardens Chromium browsers so they cannot punch through the web filter. That is where Blockdown differs most from a hosts-file script:

- **Firewall (PF) rules close the other DNS doors.** Part of Layer 3: plain port-53 DNS, DNS-over-TLS, and known public DoH endpoints are blocked, with a carve-out for the active filter. Without this, any app could simply ask a different resolver.
- **Managed browser policies stop Chrome-family browsers from tunneling out.** Applied via the **Fix bypasses** step: VPN and proxy extensions blocked as a category (not enumerated one by one), the browser's own secure-DNS forced off, proxy settings forced direct, SafeSearch forced on. Policies are rewritten hourly by a daemon, so deleting the policy file buys minutes.
- **Browsers that can't be policy-managed get blocked as apps.** Firefox-family browsers ignore Chromium policies; Opera and Tor Browser ship their own VPN/relay. **Fix bypasses** detects installed ones and offers to block them through Layer 2 in one confirmation. This is Principle 1: the app surface backstops the policy surface, which backstops the filter.
- **A real VPN keeps working.** macOS applies the DNS profile above the VPN stack, so a commercial VPN's traffic still resolves through the filter. Blockdown never has to fight your VPN, and mainstream VPN apps are not blocked.
- **The profile heals.** Removing the DNS profile triggers a watcher daemon that re-queues the install within about 60 seconds, and the PF rules mean "no profile" degrades to "no DNS" rather than "no filter."

## 6. The two editions

Everything above is identical in both editions. The difference is what defends the enforcement itself, and one root-owned marker (with a single predicate, `bd_is_lite`, checked at every resistance step) keeps the two on one code path:

- **Blockdown** trusts you. Nothing is file-locked, nothing self-heals, teardown is a normal script. In-app unblocking still goes through your unlock method; the system just doesn't resist a deliberate manual undo.
- **Blockdown Max** assumes the person at the keyboard may one day be working against the setup, and makes the enforcement self-defending:
  - Every state file, daemon binary, backup, and LaunchDaemon plist is locked with the `schg` system-immutable flag.
  - The three daemons supervise each other in a cycle, each restoring the others from locked backups within about 10 seconds. There is no single "top" process to kill.
  - Backend removal timers count **powered-on time** as well as wall-clock time, so setting the clock forward doesn't shorten a wait.
  - There is no uninstall command. Teardown is a hidden, locked script that demands a single-use, 120-second token, and the only thing that mints the token is the TUI after your unlock gate passes.

Max arms the moment its installer finishes. There is no separate hardening step, and choosing the standard edition over Max is a deliberate, visible opt-out made once, at install.

## 7. Design decisions

- **No firmware password.** It would lock Recovery Mode, which a normal admin legitimately needs. The cost of a locked-out Mac exceeds the marginal protection.
- **No separate Standard account for daily use.** The user needs admin daily; a split account either gets abandoned or keeps the admin password within reach anyway (Principle 3).
- **`schg` over detect-and-alert.** The immutable flag *prevents* the edit and requires a distinct unlock step; an alerting daemon would leave the tamper window open while it reacts.
- **24 hours for CLI removals on Max.** Long enough to outlast the decay curve in §2, short enough that maintenance isn't punishing. The TUI cooldown is user-set (15 minutes to 48 hours, raise-only) for the same reason.
- **Worker and backup both locked.** The self-healer restores the worker from a locked backup, so a delete-and-wait attack needs *both* files unlocked first. Multi-file unlocks are the friction unit of the whole design.
- **Apple-style daemon names** (`com.apple.mdsyncd`, `com.apple.statsd`, `com.apple.appblockerd`). Low visibility to the blocked person scanning a process list. Documented here and in the README; transparency to the *installer* is the invariant that matters.

### Failure modes

| Symptom | Probable cause | Fix |
|---|---|---|
| `chrome://policy` empty or partial | Browser cached old policy | Click "Reload policies" or restart the browser |
| Filtered site loads | DNS profile removed or pending approval | Approve the queued profile in System Settings, or rerun `sudo ./scripts/install-dns.sh` |
| `sudo blockdown` not found | CLI/worker missing | Reinstall per [`../layers/04-browser-policies.md`](../layers/04-browser-policies.md) |
| Blocked app stays open | Kill daemon not running | `sudo launchctl list \| grep appblockerd`; reinstall per [`../layers/02-app-blocking.md`](../layers/02-app-blocking.md) |
| Blocked domain still resolves | Stale DNS cache | `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |

## 8. Removing it, and why that's written down

Being removable by the right process, and only by the right process, is part of the design, so the exit paths are documented rather than obscured. Refusing to *explain* the mechanism would be security theater; the protection is the cost of the process, not ignorance of it.

- **Blockdown (standard):** `sudo bash scripts/uninstall-all.sh` from the clone, or Settings → Uninstall in the TUI. No token, no resistance. It stops the daemons, restores `/etc/hosts`, `/etc/pf.conf`, and DNS, removes the profile, and leaves the internet working.
- **Blockdown Max, the supported path:** TUI → Settings → Uninstall. Your unlock gate runs first (key or cooldown), then the TUI mints the single-use token and executes the locked teardown script. The script pauses the supervision cycle *before* touching anything (otherwise the daemons would restore files mid-teardown), then unwinds every layer in order and verifies the network still works. It is idempotent.
- **Blockdown Max, without the TUI:** possible, by intent, but it is an engineering exercise, not a command. A root user must recreate the install lock to pause supervision, boot out all five daemons, clear the immutable flag on each locked file and its backup, and then unwind the layers in the same order the teardown script uses. The script (`scripts/uninstall-all.sh`) doubles as the runbook: read it, replicate it. This is exactly the cost described in §1: reading the source, understanding the chain, dismantling it deliberately.
- **If a teardown is interrupted** (error, Ctrl-C, power loss), the install lock it created stays behind, which leaves Max installed but *disarmed*, and the script warns loudly about it. Re-run the uninstall to finish, or delete the lock file to re-arm.
- **The repo is the recovery source.** Re-downloading and reinstalling always works, and blocks always start empty. Recovery should be possible; it just shouldn't be impulsive.
