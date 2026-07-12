# Unlock Checklist

Paste the completed checklist into the chat before Claude executes any weakening change. See `CLAUDE.md` for what counts as "weakening."

The point is not punishment. It is forced articulation. Most impulse bypasses lose their pull when you have to write down what and why, in complete sentences, without editing yourself. The questions are designed so that "I just want to" doesn't fit in any of the blanks.

Fill out a fresh copy every time — copy the five questions into your chat message and answer each. Do not edit your answers after submitting. If you find yourself tempted to fudge a question, that is the signal the checklist is doing its job.

---

## 1. What, specifically, am I changing?

> Exact file(s), exact line(s) or entry, exact flag being cleared. Not "unblock Brave" — "remove the line `Brave Browser` from `data/banned-apps.txt`, delete `/Applications/Brave Browser.app` placeholder, remove `com.brave.Browser` from the bundle-ID kill list." If you cannot name the specific change in one sentence, stop — you do not yet know what you are doing.

**Answer:**

## 2. What changed externally since I installed this block?

> A concrete event outside your head: a new browser required for work, a specific site that broke, a legitimate app that the block caught as collateral. Reasons that do *not* count as external change: "I feel fine now," "it's been a while," "I want to try again," "the urge is gone." If the only thing different is how you feel, write that here explicitly. Do not dress it up.

**Answer:**

## 3. Is this the smallest possible change that achieves the goal?

> Could the same outcome come from `sudo blockdown host add <one-domain>`, `sudo blockdown app remove <one-app>`, a Layer 4 browser-policy exception, or an added allowed-extension ID? Full-layer unlocks (removing a daemon, clearing a list, disabling a profile) are almost never the smallest option. If the change unlocks worker binaries, backup files, or daemon plists, you must be able to explain specifically why no smaller change works.

**Answer:**

## 4. When did I first want this?

> Date and time, roughly. If the answer is "today" or "in the last few hours," stop here and revisit in 24 hours. This is the rule from `OVERVIEW.md` §6 applied to yourself, not to a hypothetical future user. If it has been 24+ hours, note when and keep going.

**Answer:**

## 5. If this turns out to have been a mistake in a week, what's the cost?

> Reversible changes (one URL, one banned app) are cheap — redo with `sudo blockdown host add` or `sudo blockdown app add`. Irreversible or expensive-to-rebuild changes (uninstalling a daemon, deleting a backup, removing the DNS profile, flipping a profile's `Locked` flag to false for a category) are expensive. Name the worst realistic outcome of this change being wrong, not the best case. If the worst outcome is "I have to reinstall a layer," that's acceptable; if it's "I lose the filter at 2am with nothing catching it," that's not.

**Answer:**

---

After answering, paste the filled form into the chat. Claude reads it, comments on anything that reads as impulsive or hand-waving, and then proceeds — or suggests waiting 24 hours, but will not refuse indefinitely if you insist after seeing the commentary.
