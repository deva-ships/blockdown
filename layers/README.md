# Manual install, layer by layer

The normal install is `./blockdown` onboarding (see the [README](../README.md)); it installs the browser-policy and app-blocking backends and walks you through the web filter. This guide is for installing by hand instead: contributors, debugging, or anyone who wants to see every command. Each layer doc in this folder is standalone, with its own verify step.

Working with an AI assistant? From inside the cloned repo you can say: *"Read layers/README.md and install the full stack on this Mac, layer by layer, verifying each before moving to the next."* Every privileged command still runs in your own Terminal with your own password.

## Before you start

1. **macOS 14 (Sonoma) or later**, admin account, not MDM-enrolled (a corporate MDM can conflict with the DNS profile).
2. **No Homebrew needed.** Everything uses macOS built-ins (`launchctl`, `pfctl`, `chflags`, `profiles`, `PlistBuddy`).
3. **Existing `/etc/hosts` entries are preserved**, but must not use the markers `# BLOCKER-MANAGED-START` / `# BLOCKER-MANAGED-END`.
4. **A commercial VPN can stay installed.** The stack is designed to coexist with it.
5. Budget about 15 minutes of paste-and-confirm.

Set `$REPO` in the shell you'll use throughout:

```bash
cd /path/to/your/cloned/repo
export REPO="$(pwd)"
```

## Step 0 — Choose the edition

The installers read one root-owned marker to decide whether to install the removal-resistance layer (locked files, self-healing daemons, gated teardown). **Blockdown Max is the default** when the marker is absent. For the standard edition, set the marker first:

```bash
sudo bash "$REPO/scripts/set-edition.sh" blockdown   # standard edition
sudo bash "$REPO/scripts/set-edition.sh" max         # back to Max (then reinstall layers)
```

Onboarding does this for you based on the edition you pick; this step exists only for manual installs.

## Install order

Do not start a step until the previous one's verify step passes. Layer numbers below are the canonical names (see [CONTRIBUTING.md](../CONTRIBUTING.md)); install order follows dependencies (`mdsyncd` before hosts/apps), not numerical order.

| Step | Layer | Doc | Time |
|---|---|---|---|
| 1 | Layer 4 — Browser policies (worker + CLI) | [04-browser-policies.md](04-browser-policies.md) | 5 min |
| 2 | Layer 2 — App blocking | [02-app-blocking.md](02-app-blocking.md) | 5 min |
| 3 | Layer 1 — Website blocking (hosts) | [01-hosts-file.md](01-hosts-file.md) | 3 min |
| 4 | Layer 3 — Web filter (DNS) | [03-dns.md](03-dns.md) | 3 min |

Layer 3 is independent and can be installed first if you prefer; Layers 1 and 2 need Layer 4's worker.

## Post-install sanity check

**Web filter** (adult-content filters only; for AdGuard/Control D/Mullvad test a domain that filter blocks):

```bash
dscacheutil -q host -a name pornhub.com
```

No `ip_address` line, or `0.0.0.0`, means the filter is working. Do **not** use `dig` for this: it queries port 53 directly, which the firewall blocks for every domain, so it proves nothing about the filter.

**Browser policies** apply after the opt-in (**Set up web filter → Fix bypasses → Block VPN extensions** in the TUI). Then `chrome://policy` → "Reload policies" should show `ProxySettings`, `ExtensionSettings`, `ExtensionInstallBlocklist`, `ForceGoogleSafeSearch`, `DnsOverHttpsMode=off` as Platform/Mandatory/OK. Before the opt-in, no policy files exist; that is expected.

**App blocking** starts empty. Block a test app and launch it; it should close within 10 seconds:

```bash
sudo blockdown app add "Tor Browser"
```

## Adding blocks later

`sudo blockdown host add <domain>`, `sudo blockdown app add <AppName>`, or the TUI. Full reference: [../docs/USAGE.md](../docs/USAGE.md). The `data/*.txt` files are optional seed templates; installers never auto-load them, so every fresh install starts with zero blocks.

## Uninstall

See the [README](../README.md#uninstall). Standard edition: `sudo bash "$REPO/scripts/uninstall-all.sh"`. Max: TUI → Settings → Uninstall (the gated path); [../docs/OVERVIEW.md](../docs/OVERVIEW.md) §8 explains the manual recovery route.

## Related

[CLAUDE.md](../CLAUDE.md) and [../docs/UNLOCK-CHECKLIST.md](../docs/UNLOCK-CHECKLIST.md) are the optional AI-assistant guardrail: an assistant in this repo should refuse to execute weakening changes until the checklist is answered in writing.
