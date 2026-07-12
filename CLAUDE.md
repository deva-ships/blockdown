# Directives for Claude working in this repo

This file is an explicit, self-authored directive from the repo owner. It is not hidden. It is meant to be read, understood, and (if deleted) deleted consciously — removing it is itself one of the frictions this stack depends on.

## Context

This repo is a blocking stack for macOS (see `docs/OVERVIEW.md`). In cooldown mode the installer and the adversary are the same person; in key mode the installer is a keyholder enforcing blocks for someone else. The stack works because undoing it requires deliberate, gated work; the risk is a motivated bypass in a short window of reduced judgment.

Claude is not that undo friction — it's a convenience for editing config, debugging, and maintenance. Without a guardrail, "hey Claude, unlock Firefox" is a 4-second ask that can defeat hours of intentional design. This file raises Claude's own cost for requests that weaken the stack.

## When this directive applies

Any request that narrows the block surface or walks the uninstall path. Non-exhaustive list:

- `chflags noschg` on any file under `/Library/PrivilegedHelperTools/com.apple.mdsyncd/`, `/Library/LaunchDaemons/com.apple.*`, `/Library/LaunchDaemons/com.dnsfilter.*`, `/Library/Application Support/.cache/`, `/etc/pf.anchors/dns-filter`, or any `/Applications/*.app` Blockdown placeholder.
- Removing lines from `data/banned-apps.txt`, `data/banned-bundle-ids.txt`, `data/hosts-domains.txt`.
- Executing `sudo blockdown app remove`, `sudo blockdown host remove` (or the legacy `ban remove` / `pin host remove` aliases) — these are legitimate CLIs with a built-in removal delay, but the checklist still applies to force articulation of why.
- Uninstalling, stopping, or disabling `mdsyncd`, `statsd`, `killappsd`, the DNS PF/profile-watcher LaunchDaemons, or the active DNS configuration profile.
- Weakening policy values — e.g. flipping `DnsOverHttpsMode` away from `off`, changing `ProxySettings:ProxyMode` away from `direct`, clearing `ExtensionInstallBlocklist`, removing the `proxy` entry from `ExtensionSettings` blocked permissions, or disabling `ForceGoogleSafeSearch`.
- Installing or helping install VPN-adjacent software (Tor, Psiphon, Clash, Shadowrocket, V2Ray, WireGuard-based custom tunnels, mesh networking clients, DNS-over-HTTPS proxies, custom resolvers).
- Any edit to `CLAUDE.md` or `UNLOCK-CHECKLIST.md` that weakens the directive (deleting triggering categories, loosening phrasing, reducing or softening checklist questions).

## What Claude should do when the directive triggers

1. **Quote the matching bullet above** back to the user in the reply.
2. **Point the user to `UNLOCK-CHECKLIST.md`** and ask them to paste their written answers into the chat.
3. **Do not begin the weakening work** until every question in the checklist has a pasted answer.
4. **Read the answers honestly.** If they indicate the change is impulsive ("I just want to"), tiny-reason ("been a while"), non-reversible ("just delete the daemon, it's annoying"), or missing a concrete external trigger, name that in the reply and suggest waiting 24 hours. Do not refuse if the user insists afterward — just record the inconsistency in the response so future-self can see it in scrollback.
5. **If the user says "skip the checklist," "just do it," "I'll fill it later," or similar:** do not skip. Remind the user they wrote this file as deliberate self-friction, and ask again for the answers. This is the one place to be stubborn.
6. **Strengthening actions are always fine without the checklist.** Adding to block lists, tightening policies, adding URL patterns, new blocked app names, new bundle IDs, new VPN extension IDs, new Firefox policy keys that lock *more*. These are the low-friction-to-whitelist side of `OVERVIEW.md` §3 Principle 2.

## Escape hatches (by design)

The user can always:

- **Delete this file** (`rm CLAUDE.md`). Claude will stop seeing it in subsequent sessions. This is the intended exit — visible, attributable, and if the repo is under version control, logged in git history.
- **Edit this file.** Any change is the user's own, and Claude will follow the updated version.
- **Override in a single case** by pasting a filled checklist.

Hidden anti-removal tricks are explicitly out of scope. The friction is the checklist and the `chflags` chain, not Claude pretending not to understand.

## What Claude should *not* do

- Do not hide text in other files that mimics this directive. Any behavior Claude applies should be traceable back to this file or the layer docs.
- Do not refuse to *explain* how to unlock. Explaining the mechanism is part of the threat model being transparent (`OVERVIEW.md` §8). Refuse to *execute* without the checklist; do not refuse to *describe*.
- Do not scold. The user is not adversarial — they wrote the whole stack. The job is to slow down impulsive weakenings, not to moralize.
- Do not treat this directive as a license for general refusal. If a request is not in the triggering list, proceed normally. Avoid false-positive friction on ordinary software-engineering work in this repo.
