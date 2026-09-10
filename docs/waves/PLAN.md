# Estate Round 2 — acting on the findings

**Goal:** every finding in the Round 2 audit is fixed, deferred with a reason, or
explicitly rejected — and the docs describe the estate that actually exists.

**Gate:** `/check` on the touched repo, plus `/review` on anything non-trivial.

**Findings (the what and why):** `~/SourceRoot/brain/Inbox/Estate Review Round 2 — Findings.md`
Read it first. It is the authority on *what* is wrong; this file only says *which
context does what*. Its finding 27 carries the ranked fix order.

**Cross-repo note:** this chain spans repos, so every wave prompt must reference
this plan by absolute path (`~/SourceRoot/dotfiles/docs/waves/PLAN.md`) and each
wave runs in its own repo's herdr space via `rd wave <repo> '<prompt>'`.

## External blocker — read before starting

The shared IU API key answers `403 rolling-30-day-cost-service-denial-limit`.
That is **upstream and being fixed by IU** — do not investigate it, do not work
around it, do not rewrite routing because of it. Probe with a single cheap call
before any wave that needs it; if still 403, skip that wave and move on.

Everything in Waves 2 and 3 is local and needs no IU key.

## Wave 1 — the dead cheap lane (repo: `sideclaw`)   <!-- status: pending, needs IU key -->
- [ ] Finding 1: every `check`/`overview` job has failed since 2026-09-09 12:09Z with
      `[claude-code:unrecognized_model] glm-5.3-flash`. This is **ours**, not the 403.
- [ ] Finding 22 and finding 1's tail: a route failure that is neither quota- nor
      timeout-shaped fires no fallback and alerts nobody. Make a dead route loud.
**Left behind:**

## Wave 2 — enforcement, not prose (repo: `dotfiles`)   <!-- status: done -->
- [x] Findings 11 and 14: orchestration and model discipline exist only as prose.
      Two Bash-only hooks are the whole enforcement layer. Add a `SubagentStart`
      hook that rejects a worker on Opus/Fable unless explicitly justified —
      **verify the blocking semantics first, they are undocumented.**
      Verified empirically (`claude -p --settings <probe>`) that `SubagentStart`
      is observational only — no `permissionDecision`/exit-code combination
      blocks it. Built `hooks/model-discipline.ts` as a `PreToolUse` hook on
      `matcher: "Agent"` instead (same mechanism `protect-branches.ts` uses):
      denies a `model: fable` worker outright, and denies `subagent_type: "fork"`
      whenever the caller's own model (read from its transcript — `PreToolUse`
      carries no field for it) is Fable/Opus. `model: opus` stays open — the
      audit's own "already right" list calls existing Opus worker sites
      deliberate, and hard-blocking would break them. Verified live (four
      scenarios: fable-worker denied, fork-from-fable denied, plain-sonnet
      allowed, explicit-opus allowed) plus 10 unit tests.
- [x] Finding 4's real content: the "cannot spawn Fable" claim was false. Either
      make it true or correct the wording in `output-styles/Direct.md`. Do not
      leave a rule that probes disprove.
      No literal claim existed to correct — made it true instead, via the hook
      above. Updated `Direct.md` and `global.CLAUDE.md` to say enforcement is a
      hook now, not just prose; added the one-clause-justification note to
      `implement/SKILL.md:63` for the sanctioned Opus escalation path.
- [x] Finding 13's tail: `/wave`'s green gate is prose. Decide what can be
      mechanical (a `--gate` check before spawning) and what must stay judgment.
      "/check passed" and "review resolved" stay the finishing wave's own
      judgment (not re-provable from the plan file). Made mechanical: plan
      committed (git status clean), an `active` wave whose immediate
      predecessor is `done` with every step ticked and a non-empty Left behind,
      and a keyword heuristic on the skill's own outward-facing verb list
      (merge/publish/release/deploy/ship). New `scripts/wave-gate.py`, wired
      into `cmd_wave` in `remote-dev.sh` before it touches herdr. 11 unit tests
      plus 5 live end-to-end cases (pass, dirty tree, outward step, undone
      predecessor, no active wave) against a scratch git repo.
- [x] `@verifier` is invoked by nothing. Wire it into `/implement` and `/ship`.
      `/implement`'s Heavy-tier runtime validation now delegates to `@verifier`
      instead of calling `/browse`/`/otel` inline (Quick/Standard keep the
      direct routing — proportionate at that volume). `/ship` gained a
      verifier step before commit in both the direct-to-master and PR flows,
      gated the same way `/review` already is ("non-trivial", skip
      docs/config-only).
- [x] Finding 9: `global.CLAUDE.md`'s "50 s regardless" sideclaw wait contract is
      stale; `otel` bypassing the job queue on Max is stale.
      Rewrote the wait-contract paragraph: `job_wait` accepts `maxWaitMs` up to
      29 min, pass it up rather than looping on the ~50s default. Pulled `otel`
      out of the async-job-tool list and documented its exemption (runs inline
      on Max, no `jobId`, no `job_wait`) — it was listed alongside check/
      review/dispatch as if it followed the same contract, and it doesn't.
**Left behind:** A `/review --deep` pass (sideclaw multi-angle + native
correctness) caught a real command-injection bug I introduced: `plan_ref`
(extracted from free-text wave-prompt content) was interpolated unsanitized
into a `host_run` shell string. Fixed with a strict charset validator before
it ever reaches the shell; verified with a constructed injection payload that
now gets rejected instead of composed. Also applied the review's minor
findings (fail-open JSON.parse in `model-discipline.ts`, a runtime type guard,
an unclosed file handle in `wave-gate.py`, a `wave-gate.test.py` fixture for
the plan parser). A follow-up native `/code-review high` pass found three more
real bugs specific to `wave-gate.py`, all fixed: the git-dirty check ran
against the wave's *target* repo, not the repo that actually owns the plan
file — wrong for exactly the cross-repo case this chain itself uses (dotfiles
plan, `brain` target) — now checks both; the step-text capture had no
continuation-line handling, so an outward-facing keyword landing on a wrapped
bullet's second line was invisible to the gate — now joins wrapped bullets
before scanning; and a `done` wave with zero checklist items passed the
completeness check vacuously — demonstrated live against this very file's own
Wave 4 — now a zero-step `done` wave fails the gate instead of passing it.
12 unit tests cover all three; a live cross-repo probe (two scratch git repos)
confirmed the dirty-check fix. Declined as scope creep for this wave: two
pre-existing `cmd_wave` bugs the same pass found (herdr workspace/tab lookups
swallow transient errors, indistinguishable from "doesn't exist yet") — real,
but in code I didn't touch, so reported and left for whoever next edits that
lookup; deduping the `block()` helper across `docker-makefile.ts`/
`model-discipline.ts`/`protect-branches.ts` (touches two files outside this
wave's diff); restructuring `callerModel` for its complexity score
(well-tested, small, not worth the churn here). The sideclaw adversary review
angle failed with the known IU 403 cost-limit — not investigated per this
chain's own instruction; re-run that angle once the key is fixed. Wave 3 was
**not**
spawned — it spans `dotfiles` **and** `brain`, and the instruction for this
run was explicit: do not touch other repos' checkouts. Wave 3's `active`
flip below is the close-out convention; actually starting it is a separate,
outward-facing call for the human to make.

## Wave 3 — docs describe the estate that exists (repos: `dotfiles`, `brain`)   <!-- status: done -->
- [x] Findings 23 and 24: `global.CLAUDE.md`, the brain wiki (zero hits for
      `warden`) and both archify diagrams do not know Warden exists.
      `global.CLAUDE.md` and `dotfiles/CLAUDE.md`'s architecture map both get a
      warden row/section. Brain: new `wiki/engineering/warden-control-plane.md`
      is the current source of truth, linked from `index.md`; the three
      Hermes pages that used to own this mechanism
      (`hermes-as-control-surface.md`, `incident-triage-loop.md`,
      `agent-dispatch-paths.md`) each get a "superseded 2026-09-09" banner —
      design narrative stays, mechanism description points at the new page.
      `agent-dispatch-paths.md`'s stale "Approve button is a dead end" claim
      corrected in the body, not just banner-noted. `dispatch-path.html`
      (sequence diagram) regenerated via archify with a `warden` participant
      and the `--auto-from-item` unattended trigger path alongside the
      existing human-initiated one — validated, delivered, visual-checked.
      `estate.architecture.json` (source) got a `warden` component and the
      dispatch edge rerouted off `hermes -> sideclaw`; `estate.html` itself
      is **not** regenerated — `deliver` correctly refused on a pre-existing,
      unrelated desktop-readability failure (confirmed present before this
      change, on unrelated sublabel text). The source change is committed so
      whoever fixes that debt doesn't have to redo the Warden addition too.
- [x] Finding 8: `warden/DESIGN.md` says four LaunchAgents; there are five.
      Fixed the dotfiles-side half: `architecture.md` now has a `### warden`
      heading with all five (`warden-api` was missing entirely, filed
      nowhere) and links to `warden/docs/api.md`, `FLOWS.md`, `docs/triage.md`.
      Also fixed a self-contradiction one paragraph away: the gateway's own
      "6 live jobs" cron count still listed watchdog/dispatch-sweep as
      gateway cron directly next to the warden row saying those two were
      promoted OUT on 2026-09-09 — corrected to 4. **`warden/DESIGN.md`
      itself is not touched** — that's the warden repo, outside this wave's
      declared scope (`dotfiles`, `brain`); still says four.
- [x] Finding 9: a 41.9k `CLAUDE.md` (over the 40k rule), a 286 KB `STATE.md`,
      secrets prose duplicated across 19 files.
      The 41.9k figure is `free-planning-poker`'s CLAUDE.md, not a dotfiles
      one (dotfiles' is 38.5k, under the limit) — out of this wave's repo
      scope regardless. Of the three dotfiles sections the audit named as
      duplicating `docs/*.md`: Colima genuinely was (docs/remote-dev.md
      already carried the full narrative) — trimmed to command + pointer.
      "Unattended boot posture" and "MacBook-only subsystems" turned out to
      already be pointer-only on inspection, nothing to trim. Evaluated and
      declined the `brain-access.md` "symlink" fix: the two files are
      genuinely different, valuable content (dotfiles-side machinery vs.
      brain's sync-contract authority), already explicitly cross-reference
      each other — not accidental duplication, and symlinking would destroy
      real information. `STATE.md` (286 KB) and the 19-file secrets-prose
      duplication are in `warden` and mostly repos outside `dotfiles`/`brain`
      — out of scope here.
- [x] The model exists nowhere as one piece. Write the single page a new agent
      reads to get the shape — machine, orchestrator, delegation roster, model
      discipline, `/wave`, Warden's loop, sideclaw's tiers. One home, everything
      else links to it.
      New `wiki/engineering/agent-estate-model.md`, linked first in
      `index.md`'s "Agents and gateways" section. One pass per topic, links
      out to every deeper note rather than restating it. vault-lint: 0
      errors, 0 warnings after every wiki edit this wave.
**Left behind:** `warden/DESIGN.md`/`README.md`/`STATE.md` still say "four
LaunchAgents" — the actual repo-side fix is one-line-times-three but out of
this wave's declared scope; worth folding into Wave 4 (already touches
`warden`) or a quick standalone pass. `estate.html` needs its pre-existing
desktop-readability failure fixed before the Warden addition already sitting
in `estate.architecture.json` can actually be delivered. The narrower
Finding-17-shaped issue (Hermes's own docs — README, scheduled-jobs.md,
CLAUDE.md, and `agent-overview-loop.md` in brain — asserting stale cron-job
counts and the `#agents` digest pause) lives in `hermes-agent`, out of scope,
not investigated. `wiki/engineering/projects/warden.md` was not hand-authored
— it's a `project-narratives` cron artifact generated from `hermes-agent`'s
own project set, which this wave has no way to register warden into without
touching that repo; either the generator discovers it automatically or that's
a `hermes-agent`-scoped follow-up.

## Wave 4 — Warden's actuator (repos: `warden`, `hermes-agent`)   <!-- status: blocked -->
Findings 2-6 and 16: dispatch/implement/merge/approvals still run through
`hermes-agent/scripts/hermes-cc.sh`; verdict delivery depends on the Hermes
gateway binary; "merge is deploy" has no code path, so `verified_unattended_fixes`
is structurally 0; Hermes's persona line 41 still claims it triages.

**Blocked on the IU key** and on the owner — this is the largest change in the
estate and its design is not settled. Do not start it in this chain. Report it as
the next decision needed.
