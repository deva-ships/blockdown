# Blockdown

Screen Time for Mac, but it actually works.

You decide what your Mac will and won't open. Blockdown holds the line. Block websites, apps, and whole categories, everywhere at once: every browser, every app, even apps you haven't installed yet. Turning a block off is deliberate, never instant. You wait out a timer, or you use a key only you hold. Free and open source.

## Install

Needs macOS 14 or later and a personal admin account (not a work or school Mac).

Open **Terminal** and paste:

```bash
git clone https://github.com/deva-ships/blockdown.git
cd blockdown
./setup
./blockdown
```

If macOS asks to install developer tools for `git`, click **Install**, wait for it to finish, then paste the command again. Keep the `blockdown` folder because you'll open the app from there later.

In the menu you can set up an optional web filter, or preview changes with `./blockdown --dry-run`.

## Day to day

From the folder you cloned:

```bash
cd blockdown
./blockdown
```

## Uninstall

Open Blockdown, then **Settings → Uninstall**.

- **Blockdown:** that menu path, or `sudo bash scripts/uninstall-all.sh` from the clone folder.
- **Blockdown Max:** the same menu path, through your unlock method. There is no uninstall command.

Both restore network settings. If setup fails partway, see [docs/OVERVIEW.md](docs/OVERVIEW.md) §8. Reinstalling always works; blocks start empty.

## What it blocks

- **Websites.** Block a site everywhere at once. `reddit.com` stops loading in Safari, Chrome, private windows, and inside other apps.
- **Apps.** A blocked app closes within about ten seconds of opening. Renaming it or downloading a fresh copy doesn't bring it back.
- **Web categories** (optional). One filter blocks an entire category for the Mac: ads and trackers, social media, or adult content. You pick one of five filters during setup.

Blockdown also closes the usual workarounds. A **Fix bypasses** step in the menu hardens Chrome, Edge, and similar browsers so they cannot skip the filter, and can block Firefox, Opera, and Tor Browser as apps if you want. Your own VPN keeps working.

Blockdown blocks whole sites and categories, not single pages within a site.

## How blocks come off

You pick this during install. It is the point of the product:

- **Cooldown timer**, for blocking yourself. Removing a block starts a wait you set in advance, 15 minutes to 48 hours. The wait can be raised later, never lowered.
- **Unlock key**, for blocking on someone else's account. Blocks stay until you type the key. Made for parents.
- **None.** Removal is instant. A plain system-wide blocker.

## Two editions

Also chosen during install:

- **Blockdown** enforces blocks day to day but uninstalls normally. If you change your mind about the whole thing, it comes off in a minute.
- **Blockdown Max** defends itself. Its files are locked, helpers restore anything that gets removed within seconds, removal timers count powered-on time so changing the clock doesn't help, and there is no uninstall command. The one supported exit runs through your unlock method. Beyond that, taking Max off a machine means reading the source and dismantling it step by step while it repairs itself. Pick Max when the blocks must hold.

Switching editions is a reinstall, and blocks start empty either way.

## Command line (optional)

If you prefer typing over menus:

```bash
sudo blockdown host add reddit.com        # block a website (www. added automatically)
sudo blockdown app add WhatsApp Telegram  # block apps
sudo blockdown host list                  # see what's blocked
```

On Max, CLI removal is a fixed two-step, 24-hours-apart process. Full reference: [docs/USAGE.md](docs/USAGE.md).

## If you use an AI coding assistant

[CLAUDE.md](CLAUDE.md) tells an AI assistant working in this repo to refuse to *execute* block-weakening changes until you fill in the written checklist at [docs/UNLOCK-CHECKLIST.md](docs/UNLOCK-CHECKLIST.md). Both files are visible and deletable; there are no hidden tricks.

## Honest limits

- Personal project, provided as-is with no warranty (see [LICENSE](LICENSE)). It changes real system settings on your Mac (network filtering, the hosts file, background helpers). Read what it does before running it; try a spare Mac or a virtual machine first if unsure.
- Max resists an admin by cost, not magic. Someone with admin access who studies the code can eventually take it apart; the design makes that a deliberate, multi-hour project instead of a toggle. For a user without admin rights (a kid's account), it is effectively a wall.
- Some background helpers use Apple-style names on purpose, so they don't advertise themselves to the person being blocked. This is documented behavior, not concealment from you.

## For developers

The full design is in [docs/OVERVIEW.md](docs/OVERVIEW.md). [CONTRIBUTING.md](CONTRIBUTING.md) maps the architecture and how to test safely. [docs/internal/PRD.md](docs/internal/PRD.md) is the spec and regression contract. A manual, layer-by-layer install guide lives in [layers/](layers/).

## License

MIT, see [LICENSE](LICENSE).
