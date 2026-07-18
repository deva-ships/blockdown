# USAGE — CLI and TUI Reference

Everything here is safe to run from a normal admin account. The interactive TUI is `./blockdown` from the repo folder; the system CLI below is installed at `/usr/local/bin/blockdown`.

```bash
sudo blockdown host  {add|remove|list|status|cancel} [domain]
sudo blockdown app   {add|remove|list|status|cancel|apply} [name...]
sudo blockdown apply
sudo blockdown policies remove
```

There is no `blockdown uninstall` command; see [Uninstall](#uninstall). `pin` and `ban` still work as deprecated aliases (`pin host` → `blockdown host`, `ban` → `blockdown app`).

| Command | Blocks | Where the block lives |
|---|---|---|
| `sudo blockdown host ...` | Whole domains, system-wide | `/etc/hosts`, inside `# BLOCKER-MANAGED-*` markers |
| `sudo blockdown app ...` | Apps, by name and bundle ID | Kill daemon state in `/Library/Application Support/.cache/` |

Blockdown blocks whole domains and categories only, not individual URL paths within a site.

## Blocking

```bash
sudo blockdown host add i.redd.it            # both 0.0.0.0 and ::1; www. added automatically
sudo blockdown app add WhatsApp              # display name, without .app
sudo blockdown app add Telegram Discord      # several at once
sudo blockdown app add "Opera Air"           # quote multi-word names
```

In the TUI (**Block apps → Block any app**), spaces separate names the same way; quote multi-word ones (`WhatsApp "Opera Air" Discord`).

Blocks apply immediately: domains within seconds (a browser may cache one for about a minute), and a running blocked app is closed within 10 seconds. The kill daemon also learns the bundle IDs of installed copies, so renamed apps and re-downloads like `WhatsApp (1).app` stay blocked.

## Unblocking

In the **TUI**, unblocking follows the unlock method you chose at install, on both editions: wait out your cooldown, enter the unlock key, or immediate if you chose none.

From the **CLI**, the editions differ:

- **Blockdown:** removal is immediate.
- **Blockdown Max:** removal is a fixed two-call delay. The first call schedules it; the identical second call completes it after 24 hours have passed, counted in both wall-clock **and** powered-on time (changing the clock doesn't help).

```bash
sudo blockdown host remove i.redd.it     # schedules (Max) or removes (standard)
sudo blockdown host status               # shows the remaining wait
sudo blockdown host remove i.redd.it     # completes, once the wait is over
sudo blockdown host cancel               # changed your mind: cancel the pending removal
```

`app remove` / `app status` / `app cancel` work the same way. Cancelling only clears the pending timer; the block stays.

## Listing and maintenance

```bash
sudo blockdown host list
sudo blockdown app list
sudo blockdown apply                     # re-apply browser policies + app + hosts state now
sudo blockdown app apply                 # rebuild only the app kill lists (faster)
sudo blockdown policies remove           # remove the managed browser-policy keys
```

Back up your lists as plain text:

```bash
sudo blockdown host list > my-domains.txt
sudo blockdown app list > my-apps.txt
```

## Web filter

Configured from the TUI (**Set up web filter**), or directly:

```bash
sudo ./scripts/install-dns.sh --filter "CleanBrowsing Adult"
sudo ./scripts/install-dns.sh --remove
```

The supported filters are Control D Social, Mullvad Extended, CleanBrowsing Adult, CleanBrowsing Family, and NextDNS Custom. Changing or removing the filter from the TUI goes through your unlock method.

## TUI

```bash
./blockdown              # the menus: block websites, block apps, web filter, settings
./blockdown --dry-run    # full preview, no system changes
./blockdown --reset-dry-run
```

## Uninstall

- **Blockdown:** `sudo bash scripts/uninstall-all.sh` from the repo folder, or TUI → Settings → Uninstall. No gate.
- **Blockdown Max:** TUI → Settings → Uninstall only. Your unlock gate runs first, then the TUI authorizes the teardown with a single-use token. A bare `uninstall-all.sh` refuses on Max by design; [OVERVIEW.md](OVERVIEW.md) §8 covers the manual recovery route if the TUI is ever unusable.

Either path stops the daemons, restores `/etc/hosts`, firewall, and DNS, and leaves the internet working. Reinstalling later always starts with empty block lists.
