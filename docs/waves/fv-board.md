# FV: the board on the fleet view

**Goal:** the Herdr board (`config/herdr-app/mods/jk-board`) reads the factory's fleet view (software-factory `docs/waves/fv.md`)
instead of its own collectors, shows the owner's asks with their actions, and reports the owner's presence at the desk.
Owner choices (2026-11-02): variant A layout with C inline actions, the app's `theme()` tokens only (`working` and `blocked` the
only hues), presence from navigation never from prompts or input idle. Already landed: `bc420a1` (dated statuses, click to jump,
colour cleanup).
**Gate:** `make check` green, `/review` with findings fixed, `make deploy`, the mod reloaded in the app, a screenshot per wave.

## Wave 1 — The queue's read and the board on `/fleet`            <!-- status: active -->
- [x] `ask-human.sh list --json` (id, text, cmd, askedAt, ageSeconds, state), stable for the factory to read; tested hermetic like the rest
  of `human-queue-test`. Lands first: the factory's FV Wave 1 reads it.
- [x] `ask-human.sh resolve <id> --as done|denied|superseded [--note]`: the owner's answer without the MacBook (the factory's FV Wave 3
  calls it, never writes the queue). Never runs the command; `denied`/`superseded` are status `denied` (a waiting caller exits 1),
  `resolvedAs`/`resolvedNote` show in `status <id>`.
- [x] After software-factory FV Wave 1 is live: the board reads `factory fleet --format json` over the existing ssh exec **with the token** (`secrets-run run --env-file=<the factory's .env.tpl> -- factory fleet`): `/fleet` is token-only, because the socket is every pane's and IuRoot text must not reach an agent's model; the
  `PLAN.md` grep and its parser go. Layout A, repos with plan and sessions, asks on top.

## Wave 2 — Actions and the away card            <!-- status: pending -->
- [ ] After FV Waves 3 and 4: C inline actions on each ask (the intents the model lists, nothing hardcoded), "Apply all" for the
  one-click tier, Undo on the triage log; the "While you were away" card with the paragraph, counts per group and "Caught up".

## Wave 3 — Presence from the desk            <!-- status: pending -->
- [ ] The app reports desk acts to `POST /fleet/presence`: a focus change (space, tab, pane), the app's "looked at", a click on the
  board, a macOS unlock. First prove that a tab `rd` or the factory opens does not move the app's focus by itself; if it does, that
  act is not counted.
- [ ] `AGENTS.md`: `agw agents` is no longer "the one producer" once agw decides (software-factory FV Wave 5).
