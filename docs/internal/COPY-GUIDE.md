# Blockdown — Copy Guide & Review Prompt

This is the canonical reference for all user-facing text in Blockdown (TUI, CLI,
installers, instructions). Part A is the principles. Part B is the operational
prompt to run every string through. Part C is the terminology table. Part D is
the width decision. Part E is worked before/after examples from the real code.

---

## A. Principles

### 0. Positioning (the external pitch)

The tagline is **"Screen Time for Mac, but it actually works."** It opens the
README and the TUI splash, once per surface, at most.

The full narrative (control over your own computer, why Screen Time fails,
the two audiences, "setting a limit and having your computer keep it") lives
in `docs/OVERVIEW.md` §1. The README stays functional: what it blocks, how
blocks come off, install, usage. It quotes the narrative in single lines at
most and links to OVERVIEW for the rest. Don't restate the pitch on inner
docs or TUI screens; when quoting it, reuse the exact sentences rather than
paraphrasing, so surfaces don't drift.

The pitch, in order, for any new external surface (repo description, release
notes, a future website):

1. **Screen Time for Mac, but it actually works.**
2. **The frame is control.** Your computer should keep the limits you set.
   Screen Time makes every limit revocable at the moment it binds; Blockdown
   sends removal through an unlock you chose up front. Free and open source.
3. **Two audiences, one sentence each.** Self-blocking: you decide while
   thinking clearly, and undoing it takes a wait you set in advance. Parents:
   blocks hold; a block that comes off in two clicks is not a block.
4. **The closer.** Nobody actually wants unlimited access to everything.
   Blockdown is for setting a limit and having your computer keep it.

Word choice: do not use "urge" (interim replacement: "impulse"; when the final
term is decided, sweep README, OVERVIEW.md, and UNLOCK-CHECKLIST.md in one
pass). Do not describe Max removal as "slow" ("deliberately slow" is banned):
slow undersells it. Max has no uninstall command; removal without the gated
path means reading the source and re-engineering the teardown by hand. Say
that. Do not mention Cold Turkey or any other third-party tool by name; for
URL-path / single-page blocking, state that it is out of scope (Blockdown does
whole domains and categories) without recommending an alternative.

### 1. One product, two narratives

Blockdown has two kinds of users, and the **unlock method** is the fork:

| Mode | User | Mental model | Voice for friction copy |
|------|------|--------------|-------------------------|
| **Unlock key** | Parent / guardian (protecting someone else, or future-self via a key they hand away) | "I hold the key. Blocks stay until I say so." | Authoritative, final. The keyholder is in control. |
| **Cooldown timer** | Self-control user (blocker and blocked are the same person) | "I'm setting friction now so future-me can't cave in a weak moment." | Commitment-affirming, on their side. The wait is the feature. |
| **No restrictions** | Trying it out / undecided | Neutral. | Plain, no friction language. |

Rules:
- **Branch only the friction surfaces** (removal, unlock, gated actions, cooldown
  setup, the "why this is locked" lines). Everything neutral — adding a block,
  listing, choosing a filter — stays **shared, identical copy**. Don't fork what
  doesn't need forking.
- **Key mode never mentions waiting or timers.** Cooldown mode never mentions a
  key. They are mutually exclusive; copy must respect that.
- Friction is the product working, not an error. Never apologize for it, never
  make it sound like a failure. Key mode: calm authority. Cooldown mode: "you
  asked for this, and it's holding."

### 2. Plain, direct, concise

- Write for someone non-technical. If a sentence needs a networking concept to
  parse, rewrite it. **Hide the machinery**: no "DNS", "resolver", "PF",
  "daemon", "Chromium", "policy", "Layer N", "bundle ID" in normal copy. Use them
  only where the user genuinely must act on them (e.g. a `chrome://policy` step),
  and explain inline.
- One idea per line. Lead with the action, then the consequence.
- Cut filler: "Please", "simply", "just", "in order to", "you can now".
- Prefer the shortest correct word: "remove" not "deactivate", "wait" not
  "cooldown period", "blocked" not "restricted".

### 3. Instructions must be exact and verifiable

Whenever the user has to do something outside the TUI (approve a profile in
System Settings, reload browser policies), the copy must give:

1. **Numbered steps**, one action each.
2. **The exact label they will see**, in the exact case (`Privacy & Security`,
   `Profiles`, `Install`), so they can pattern-match without thinking.
3. **A success check** — "You'll know it worked when…" — so they can confirm
   before moving on.
4. **A failure fallback** — what to do / what command to run if it didn't work.

Never put variable-length text inside a fixed-width ASCII box (the border breaks).
Either size the frame to the content at render time, or drop the box and use a
simple indented numbered list.

### 4. No em dashes, no AI-isms

- **No em dashes (—).** Replace with a period, comma, colon, or parentheses.
  A period is almost always right.
- **No "it's not X, it's Y"**, no "more than just", no "the best part?", no
  "let's dive in", no rhetorical-question-then-answer.
- Use a memorable line **once**. "Hard to remove by design" earns its place on the
  splash. Don't repeat the same flourish on three screens.
- Read it aloud. If it sounds like marketing or like a model wrote it, flatten it.

### 5. Styling discipline (bold / gray / plain / color)

The TUI already defines the palette in `lib/ui.sh`. Use it semantically, sparingly:

- **Bold** = the single thing to read or act on: a screen header, a prompt, the
  current consequence. **One bold element per line, max.** Never bold a whole
  paragraph.
- **Gray / dim** (`_C_GRAY`, `_C_DIM`) = secondary, skippable context:
  consequences, hints, "you can change this later", keyboard tips. If the user
  could skip the line and still succeed, it's gray.
- **Plain** = body text the user must actually read.
- **Color is semantic, never decorative:**
  - Green `✓` = done, safe, succeeded.
  - Red `✗` = error, blocked, failed.
  - Yellow `⚠` = friction or caution the user should notice (a gate, a pending
    wait, an irreversible step).
  - Accent blue = brand / logo / section headers only.
- **Don't stack emphasis.** A line that is already a yellow `⚠` warning does not
  also need bold and ALL CAPS. Pick one signal.
- Match the existing helpers (`ui_success`, `ui_error`, `ui_warn`, `ui_info`,
  `ui_section`) rather than hand-rolling escape codes.

### 6. Progress is a state, not a log

The user needs exactly three states: **working**, **succeeded**, **failed**. Not
the internal steps in between.

- **Collapse multi-step internal work behind one status line.** Installing the
  layers, writing browser policies, flushing the DNS cache, staging and loading
  daemons, patching `pf.conf` — all of that is one operation to the user. Show a
  single "Setting up…" (or a spinner) while it runs, then one `✓` or one `✗`.
- **Internal step names are debug output, not copy.** "Step 1/7", "Staging PF
  LaunchDaemon", "Patching /etc/pf.conf", "Installing Layer 3" must not appear on
  the default screen. **Where they go:** always append to a log file
  (`/Library/Logs/Blockdown/` for root-run installers/uninstallers;
  `~/Library/Logs/Blockdown/` for anything run as the user), and also print them
  live when the user opts in with `--verbose` (or `BLOCKDOWN_VERBOSE=1`). The
  default screen stays clean; the detail is still there for troubleshooting and
  for diagnosing a failed install.
- **On failure, don't dump the failed internal step.** Say, in user terms, what
  didn't work, what it means for them, and the one thing to do next (a command,
  a retry, a place to look). The user should never have to interpret a daemon
  label to recover.
- **Exception — steps that need the user to act are not internal.** Approving the
  web-filter profile in System Settings, reloading browser policies: those are
  foreground instructions (Principle 3), and they stay visible. Hide everything
  the system does on its own; surface everything the user must do.
- **Keep the loader honest.** Only show "working" while something is actually
  running, and always resolve it to a definite success or failure. No spinner
  that never ends, no "Done!" before the work finished.

### 7. Consistency

- Use the **terminology table (Part C)**. One term per concept, everywhere.
- "Blockdown" (capital B) = the product. `blockdown` (lowercase, monospace) = the
  command you type. Never lowercase the product in prose.
- Durations are always human-readable via `format_duration` ("24 hours", never
  "86400 seconds"). Watch article/plural agreement: "a 24-hour wait", not "a 24
  hours cooldown".
- Buttons/menu items: imperative and parallel ("Block a website", "Unblock a
  website", "List blocked websites").

---

## B. The Review Prompt

Run this on **every** user-facing string, new or existing. It is a procedure, not
a vibe.

> **1. Surface & mode.** What screen is this, and is it a *friction* surface
>    (removal, unlock, gate, cooldown setup) or a *neutral* one? If friction,
>    which mode am I writing — key, cooldown, or none? If neutral, write one
>    shared version.
>
> **2. Goal.** In one sentence: what is the user trying to do on this screen?
>    Delete any line that doesn't serve that goal.
>
> **3. Action line.** Write the imperative the user acts on. Bold it. Keep it
>    short. Lead with the verb.
>
> **4. Consequence / context.** Add what happens and what it costs, in plain or
>    gray text. If this is a friction surface, branch the wording by mode
>    (authoritative for key, commitment-affirming for cooldown). Key mode says
>    nothing about timers; cooldown mode says nothing about a key.
>
> **5. Instructions (if any).** Numbered steps, exact UI labels in the right case,
>    a "you'll know it worked when…" check, and a failure fallback. No
>    fixed-width box around variable text.
>
> **5b. Progress.** If this string is one of several internal steps in an
>    operation (installing, writing, flushing, loading), it should not be its own
>    line. Collapse the whole operation to one "working" state plus a single
>    success/failure. Keep visible only the steps the *user* must act on.
>
> **6. Terminology.** Replace every concept word with its canonical term from the
>    table. Check "Blockdown" vs `blockdown` casing.
>
> **7. Styling.** One bold element per line. Gray the skippable lines. Color only
>    semantically (green done / red error / yellow caution). No stacked emphasis.
>
> **8. Strip.** Remove every em dash (→ period/comma/colon/parens). Remove
>    AI-isms and repeated flourishes. Remove "please/simply/just".
>
> **9. Read aloud.** Does it sound like a calm person who's on the user's side?
>    Does it fit the width budget (Part D)? If not, cut.

---

## C. Terminology table

| Use this | Not this | Notes |
|----------|----------|-------|
| **Blockdown** | blockdown, BlockDown, the app, the tool, Lite, Blockdown Lite | The standard product, capital B. Easy to uninstall. |
| **Blockdown Max** | Full, full edition | The lock-in edition. Same blocking; resists a quick teardown. |
| `blockdown` | — | Only as the literal command, monospace/lowercase. |
| **unlock key** | password, passphrase, PIN, code | The secret in key mode. |
| **cooldown timer** | cooldown period, delay, waiting period | The wait in cooldown mode. The duration itself: "the wait". |
| **web filter** | DNS filter, category filter, DNS filtering, content filter | User-facing name for Layer 3. |
| **block / unblock** | restrict, deactivate, allow, whitelist, remove a block | Verbs for sites and apps. |
| **website / site** | host, domain (in body copy) | "domain" is fine in input prompts where precision matters. |
| **app** | application, bundle, process | |
| **Set up Blockdown** / "finish setup" | install daemons, install Layers 4 & 2, backend | Hide the layer/daemon machinery. |
| **System Settings** | System Preferences, settings (macOS 13+) | Exact macOS name. |

---

## D. Width decision

**Recommendation: standardize, expand slightly, don't go wide.**

- Keep the existing **2-space left indent**.
- Target a **content width of ~64 characters** per line (so ~66 columns total).
  This reads comfortably in an 80-column terminal with breathing room, and the
  hand-wrapped DNS detail blocks already sit around 58–62 chars, so it's a small,
  consistent bump, not a redesign.
- **Make frames dynamic, not fixed.** Dividers (`ui_divider` is a hardcoded 40
  chars) and instruction boxes should size to the longest line they wrap. This
  also fixes the broken-border bug when a filter name is interpolated into a box.
- Don't go full-terminal-width. A narrow, predictable reading column is calmer
  and is what makes the friction screens feel deliberate rather than noisy.

If a specific screen's copy genuinely needs more than ~64 chars to stay clear
(rare), widen that screen rather than the whole app.

---

## E. Worked before / after (from the current code)

**Terminology drift** — `lib/onboarding.sh:221`
- Before: `You can change your password in settings.`
- After: `You can change your unlock key in Settings.`

**Jargon leak** — `lib/onboarding.sh:224`
- Before: `Installing backend daemons (Layers 4 & 2)...`
- After: `Finishing setup. This takes a moment.`

**Em dash + flourish** — `lib/dns.sh:32-33`
- Before: `Blocks ads, trackers, and phishing sites. The web stays fully open otherwise — no content restrictions.`
- After: `Blocks ads, trackers, and phishing. Everything else stays open.`

**Friction copy, grammar bug + mode tailoring** — `lib/removal.sh:119`
- Before (both modes get the generic line): `Removal requires a 24 hours cooldown timer.`
- After, **cooldown mode**: `Removing this starts a 24-hour wait. The block stays active until then.`
- After, **key mode** (`removal.sh:35`): `Enter your unlock key to remove this block.`

**Instruction box, broken border + exactness** — `scripts/install-dns.sh:524-530`
- Before: fixed-width box with `'${FILTER_NAME}'` interpolated inside (borders
  misalign; no success check).
- After (no box, numbered, with a confirmation):
  ```
  Required: finish the install in System Settings.

    1. Open System Settings, then Privacy & Security.
    2. Scroll down and click Profiles.
    3. Click the pending "<filter name>" profile.
    4. Click Install and enter your Mac password.

  You'll know it worked when the profile shows under "Configuration Profile".
  If you don't see the prompt, run: sudo ./scripts/install-dns.sh --filter "<name>"
  ```

**Repeated flourish** — splash keeps "Hard to remove by design"; the cooldown
settings screen and the "very hard to remove" line drop their separate "That's
the point." repetitions.
