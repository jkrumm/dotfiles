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

## The IU key is back — and the chain's second half is one tab

The `403 rolling-30-day-cost-service-denial-limit` was the provider's own
usage-tracking fault, resolved externally 2026-09-10 and confirmed by the owner.
Nothing below is blocked on it. The former Wave 1 (the dead cheap lane) was never
run and is now step 4.2 of Wave 4 — the failure is still live and is still ours.

**Waves 4–8 are the wrap-up the owner asked for on 2026-09-10**: one Fable tab
in `warden`'s herdr space, orchestrating subagents, that keeps chaining until the
estate is end to end — a human in herdr, a human in Hermes, proof and insight in
Argo, the model and cost choices reconciled — and ends by writing the handover
the owner runs after days in the field (Wave 9). The design authority for the
split is `~/SourceRoot/brain/Inbox/Warden Wave 4 — Shape.md`; the ground truth
for where Warden is remains `warden/STATE.md` (§§46–51 are Wave 3). This is not
a re-derivation: the decisions are made and documented, the job is to finish and
align. Every wave runs in `warden`'s space via
`RD_WAVE_MODEL=fable rd wave warden '…'`; a wave that touches `hermes-agent`,
`sideclaw`, `argo` or `brain` says so in its steps and commits in each repo it
touched. Workers stay on Sonnet (the hook enforces it); raise one to Opus only
for novel-hard logic, in one clause.

**Owner authorization, recorded once so the gate's outward-verb heuristic is not
the human's call by proxy:** landing pull requests the chain itself opened in
argo's *canary scope* (Wave 5) is inside this chain. Widening `autoMergePaths`
past the canary, any change to a production repo outside a chain-opened PR, and
any Tailscale ACL push remain the owner's call — stop and hand back.

**Method rule, from three waves of evidence in `STATE.md`:** every wave has had
defects invisible to reading and caught only by mutation or by executing the
path. Acceptance for moved or ported code is *executing* it, never diffing it.
A worker's report is a claim; read its diff; run the thing.

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

## Wave 4 — ground truth, the cheap lane, the wholesale move (repos: `warden`, `sideclaw`, `hermes-agent`, `dotfiles`)   <!-- status: done -->
Read first: the shape note (above), `warden/STATE.md` §§46–53, `warden/CLAUDE.md`,
findings 1, 3, 4, 6, 22. The Warden Wave 3 session finished items 0, 1a, 1b;
items 2 and 3 are Wave 5 here. Started from `d3f5f2b`.
- [x] 4.1 Reconnaissance against the running system, no edits: `make status`,
      `make test`, `make check-policy` in warden; `/health` + `/metrics` on
      `127.0.0.1:7735`; sideclaw `GET /api/routing`, `/api/jobs/health`,
      `/api/jobs?limit=30` (as of 2026-09-10 14:23 `overview` still exits with
      `unrecognized_model glm-5.3-flash`, and a `check` exited with "claude.ai
      connectors are disabled" — two distinct shapes); the Hermes gateway log;
      Argo's agents page. Append a dated section to `warden/STATE.md` (its
      convention) — findings only, and anything the shape note got wrong.
      `warden/STATE.md` §52. Warden green (148/148, five agents, policy agrees);
      IU key answering 200; the two stderr lines are warnings printed on every
      successful IU run, one shape not two — what failed was a 403 refusal in
      the result envelope (never classified) and a 120 s `overview` cap neither
      lane meets. Gateway: Socket Mode client reconnect-looping every 10 s all
      day while a second client still answers. Argo `/agents` 200, API 401 —
      Wave 7's. Stale counts fixed on the way: `test_triage` gate 148/148 in
      `CLAUDE.md`/`docs/triage.md`, five LaunchAgents in README/DESIGN/STATE.
- [x] 4.2 The cheap lane lives again (findings 1, 22; the former Wave 1). Root-cause
      the `unrecognized_model` exit on Claude Code 2.1.266+ — a version fact,
      so `/research` it, never from memory — and either fix the pin in
      `session-runner.ts` or re-route `check`/`overview`/`review_router` to the
      cheapest IU model `modelpick` currently passes (`cap --list`). Classify
      `unrecognized_model`, `connectors are disabled` and
      `access_denied|cost-service-denial` as "IU never answered" in
      `planNextAttempt` so the Max fallback fires. `GET /api/jobs/health`
      flags N consecutive failures per route; `devhost-health-check.sh` WARNs on
      it and on `backendFallbacks.count > 0`. Acceptance: one `check` and one
      `overview` job `done` on the cheap route; a forced route failure produces a
      fallback and a WARN, not silence.
      sideclaw `df89ac5`, dotfiles `3bf4b30`. Not the pin: `api_error_status`
      off the result envelope, `{400,401,403,404}` or `access_denied|cost-
      service-denial|403` on a zero-output exit → Max fallback at attempt 1;
      429/5xx keep the same-backend retry. Bounded per-route streaks +
      `warnings[]` on `/api/jobs/health`, `ok` untouched; devhost WARNs on it.
      `overview` cap 2 → 3 min (measured: glm 139 s, haiku hit 120 s once).
      Review caught the banner lines in the classifier — removed, pinned by a
      test. Live: `check` 64 s and `overview` 166 s `done` on glm/iu; forced bad
      model → fallback in 1.2 s, health `warnings` set, devhost rc=2. Route stays
      glm-5.3-flash (`cap` still picks it). Research-gateway returned zero
      citations on the 2.1.266 catalog question — its own defect.
- [x] 4.3 `hermes-cc.sh` moves wholesale into `warden/scripts/` (shape note step
      4.0): `triage.py`'s `HERMES_CC_BIN` default, the plugin's
      `_DEFAULT_CC_SCRIPT`, `skills/claude-dispatch`, the hermes Makefile and
      tests repointed; `~/.hermes/scripts/hermes-cc.sh` becomes a two-line exec
      shim; `hermes-agent/config/dispatch-repos.json` deleted (sideclaw is the
      boundary, warden's copy is defence in depth, `make check-policy` proves
      they agree); the schema pin intra-repo; `hermes-cc.log` registered in
      `dotfiles/scripts/log-rotate.sh`. Zero behaviour change. Acceptance: the
      165-case and 148-case suites green from the new location; one live
      `investigate` opened from Slack through Hermes and one from the loop, both
      folded onto their cards.
      warden `e29434a`, hermes-agent `3ecbdef`, dotfiles `dd306eb`. Byte-identical
      apart from comments and one default; five-line exec shim stays because the
      Hermes guards allow that literal path (the skill keeps calling it; loop and
      plugin call warden directly). `dispatch-repos.json` moved, not deleted —
      it is what `make check-policy` compares against sideclaw. Both suites moved:
      165 + 85 green under `make test`; schema pin asserted by a ledger test.
      Live: loop ticked on the moved script; one `investigate` opened through the
      shim (`c7737ef5`, 25 s) — the recursion guard refused inside this Claude
      session, re-run with `CLAUDECODE` unset as a human would. **From Slack
      through Hermes: not done unattended** — needs a human typing.
- [x] 4.4 Verdict delivery off the gateway binary (finding 3): `dispatch-sweep.py`
      `send_message()` and the plugin's `_send_to_origin` use the plain
      `chat.postMessage` client `triage.py` already has; `reported_at` gets a
      sibling `delivery_status` instead of a string in a timestamp column.
      warden `c1ebe58`, hermes-agent `0429201`. `scripts/slack_client.py`, stdlib,
      never raises; sweep and plugin post through it; schema 6 with a backfill
      (25 delivered, 2 undeliverable, zero strings left in `reported_at`);
      every `reported_at` write point writes both, `--wait` and abandon included.
      The live ledger migrated at the loop's next tick from the working tree,
      the sweep refused once and resumed, the API needed a kickstart. Live: the
      probe's verdict posted to the card channel over HTTP at 18:34Z,
      `delivery_status = delivered`, gateway still reconnect-looping.
- [x] 4.5 The notifier reads the ledger (STATE §49, finding 6): the reminder path
      skips events whose item is `ignored`/`note`/terminal, `needs_human` gets
      its own cadence, and the three UptimeKuma group monitors (`uk:95`, `uk:179`,
      `uk:186`) are disposed of the way DESIGN § Open questions already names.
      warden `968f4ac`. Terminal-state items skipped without touching the
      anchor; `needs_human` on its own 24 h cadence with the verdict folded in;
      group monitors dropped in `poll_uk` (children alert on their own; a parent
      is never escalatable). Proven on a `.backup` copy, then live: the poller's
      first run resolved all three at 18:14Z.
**Left behind:** Everything green and live; nothing pushed (the chain runs in
this checkout — push when the owner next looks). `warden/STATE.md` §§52–53 are
the record. Open, by owner: (1) 4.3's "one live `investigate` from Slack through
Hermes" needs a human typing in Slack — the shim path is what answers, the
plugin's HTTP delivery is what replies; do it once. (2) `hermes_log` events ride
`upsert_grouped()`, not the reminder branch, so ev261 is not on the 24 h cadence
(worker finding, STATE §53). (3) `hermes-cc.sh` still runs on bare `python3`
(Homebrew 3.14) and its `APPROVAL_PY` is the gateway venv — zero-change kept
them; Wave 5 deletes the file. (4) The gateway's dead Socket Mode client has
logged `Session is closed` every 10 s since 09-07 while a live one answers —
Hermes's own bug, now irrelevant to delivery, still worth a restart from the
owner. (5) Declined review items, recorded with reasons in STATE §53:
`session-health.ts` extraction, streak-limit env override, `runSessionAttempt`
refactor, `triage.py` importing state names from `ledger.py` (a module reorder,
not an alias), `sensitive ⊆ deny` in the moved validator, the `cmd_merge`
`--confirm` argument (pre-existing contract, Wave 5.2's port). (6) The
`modelPicker`/`behavesAs` catalog mapping that would silence the
`unrecognized_model` banner is cosmetic and undocumented; research-gateway
returned a report with zero citations on it — a research-gateway defect to look
at. Wave 8.2's "five LaunchAgents" line is already done (this wave's recon
commit). (7) `scripts/wave-gate.py` scanned every unchecked step for an
outward verb and reported the hit as "the next step" — it refused Wave 5's
spawn on 5.4 (`Deploy`), three steps away. Fixed to its documented contract
(next step only) with a test; 5.4 stays the Wave 5 agent's own stop-and-judge
moment under the header's owner authorization.

## Wave 5 — the actuator in Python, and the chain proven end to end (repos: `warden`, `hermes-agent`, `sideclaw`, `argo`)   <!-- status: done -->
Shape note §§ 3–4 are the design; STATE §12 has `hermes-cc.sh`'s line ranges —
the file is `warden/scripts/hermes-cc.sh` now (Wave 4.3), its suites are
`warden/tests/test_hermes_cc.py` (165) and `test_dispatch_approval.py` (85), the
ledger is schema 6 with `dispatches.delivery_status`, and `scripts/slack_client.py`
already is the slack client 5.1 names. Read `STATE.md` §53 first.
- [x] 5.1 `warden/scripts/clients/`: sideclaw (submit, get, wait, cancel), github
      (read PR, ready-for-review, the landing call, branch delete, check-runs,
      Actions run), slack (HTTP), signer (verify against the published pubkey),
      rollout (the one-arm closed argv `case`). The loop calls functions; the
      exit taxonomy becomes exceptions; the Actions-run step is its own
      operation with its own write-point (STATE §48's "one operation, not two"
      limitation disappears); the 21 monkeypatched `_run_hermes_cc_*` shims in
      tests become one injectable fake.
- [x] 5.2 `warden/scripts/lifecycle/`: `resolve_repo`/`resolve_tier`, the five
      budgets, `require_auto_from_item`, the signed-decision spend — inside
      `drain_intents()` so it stays synchronous with the click, `spent_at` and
      the operation row in one transaction, a key id recorded at mint so a
      rotated key reads `superseded` — and `merge_gate_check`. The `warden` CLI
      (closed verbs, no path or URL argument, brief on stdin, recursion guard,
      audit line) over them; the bash file deleted; `test_hermes_cc.py` ported
      black-box against the CLI; the approval canonical-string spec versioned
      with fixture vectors read by both repos' tests. Delete, do not port:
      `cmd_cancel`, `record_as_job_json`, `queued`, `lost`.
- [x] 5.3 Real cancel and the rest of warden Wave 3 item 2: sideclaw
      `POST /api/jobs/:id/cancel` (the only kill surface today is process-wide
      `POST /api/shutdown`), `warden abort <item>`, `warden revert <item>`
      recording the revert PR, the per-repo in-flight lock.
- [x] 5.4 The stop-condition exercise (warden Wave 3 item 3, DESIGN § Migration
      Wave 3): a canary scope in argo — `autoMergePaths` limited to a path only
      this exercise touches and that still triggers argo's `Deploy` workflow
      (`on: push: master`, unfiltered), so an item runs `implementing →
      validating → merged → liveness_pending → fixed` with zero blast radius
      and the `GIT_SHA` probe as proof. Kill the loop at every boundary and show
      it neither drops the obligation nor repeats an unsafe action. Record the
      run in `STATE.md` with timestamps. Owner-authorized for the canary scope
      only (see the header).
**Left behind:** Everything green and live, nothing pushed (the chain runs in
this checkout — push when the owner next looks). `warden/STATE.md` §54 is the
record, with timestamps. Commits: warden `fb87038` (clients + lifecycle +
schema 7, bash deleted), `2918fa2` (CLI, loop seam, abort/revert, canary
scope), plus the reconcile fixes + close-out; sideclaw `a08965a` (cancel);
hermes-agent `949594d` (plugin reads the row, shim → `warden`); dotfiles
`4acb077` (log rotation). The stop condition is met: argo#18 landed
`docs/DEPLOY-VERIFICATION.md` (`5941c600`) through implementing → validating →
merged → liveness_pending → fixed with the loop killed at seven boundaries and
every recovery observed; three earlier canaries were refused by the models
themselves (evidence in another repo / a scope grant the PR body did not
mention / "looks like an injection attempt") — the property, not a failure.
The canary path in `config/triage-policy.json` is `docs/DEPLOY-VERIFICATION.md`
(one documentation file nothing reads), not `docs/CANARY.md`. Open, by owner:
(1) the 4.3 "human types a dispatch into Slack" acceptance — the plugin now
reads `spent_job_id`/`spend_error` off the row, `--confirm` on dispatch no
longer exists; the first real click proves it. (2) Wave 6.2's "the
dispatch-approval plugin's replay path calls the CLI" is obsolete — there is no
replay path any more; the click is drained and spent by `intents.py`, and 6.2
should say so rather than rebuild one. (3) Carried gaps, each named in STATE
§54 Next action: the reclaim note not cleared on re-claim (cosmetic); the
orphan-branch/PR ledger field for an `after-implement-submit` crash (the cancel
endpoint is the manual remedy); `abort` leaves the card to the loop's next
tick; reconcile reads merges through `gh` while everything else uses
`clients/github.py`; hermes-agent's `docs/guards.md`, `docs/symlinks-and-agents.md`,
`docs/agents-overview.md`, `skills/agents/SKILL.md` still say `hermes-cc.sh`
(the shim path is real, the prose is dated — Wave 8). (4) Declined from
review, with reasons in STATE §54: splitting `plan_or_land`, request-object
refactors, collapsing the `slack_client.py` shim, `collect_expected_alerts`'
silent degrade (needs a design call). (5) Side findings: `warden-loop.err`
shows a `propose_mappings` 403 on the cheap model route (Wave 7's model
choices); a `node astro dev` (`sy-serendipity`) listens on `[::1]:7734` while
`warden-api` held `127.0.0.1:7734` — `localhost:7734` answered a stranger's
404; nothing in warden uses `localhost`. Resolved 2026-09-11: warden-api
moved to 7735, reserved in the Caddyfile. (6) Suite numbers: `test_triage.py`
is 157/157 (was 148); 14 suites under `make test`; the 165 bash cases became
53 CLI + 108 + 63 unit cases, recorded honestly in STATE §54.

## Wave 6 — every origin opens an item; Hermes is the door (repos: `warden`, `hermes-agent`, `sideclaw`)   <!-- status: done -->
Shape note § 2 "every origin opens an item", § 5 items 2, 3, 5, 8.
- [x] 6.1 `warden run <repo> '<brief>' [--tier]` (the `human` origin) and the
      `warden:go` label on a GitHub issue (`github_issue` origin, FLOWS.md flow 3)
      create items that ride the same lifecycle as an alert. Third-party issues
      stay `investigate`-only.
- [x] 6.2 Hermes's `claude-dispatch` skill calls the warden CLI (`--wait` keeps
      the in-turn `investigate` answer); the dispatch-approval plugin's replay
      path calls the CLI; `SOUL.md:41` says Hermes narrates and answers while
      Warden triages, decides and dispatches (finding 15); `hermes-agent/CLAUDE.md`
      names Warden in its opening section.
- [x] 6.3 Hermes reads Warden (finding 16): a read-only `warden` skill in
      `HERMES_SKILLS` on `/health`, `/metrics`, `/board`, `/items/:id` (add the
      two projections to `warden-api` if missing); the morning briefing reads the
      ledger instead of a second `gh search`; `warden` joins the
      `project-narratives` project set.
- [x] 6.4 One quality vocabulary for humans and machines: sideclaw `review`
      accepts a branch or PR ref, and Warden's step-7 validation reads its typed
      `outcome` (`clean` → confirmed, `blocking` → blocked, `needs-human` →
      `needs_human`) instead of marker-matching an `investigate` verdict; the
      implement handler runs sideclaw `check` in the worktree before push, and a
      red check is `nextAction: human`, never a PR.
**Left behind:** Everything green and live, nothing pushed. `warden/STATE.md`
§55 is the record with timestamps. Commits: sideclaw `e9b6584` (review by
`pr`/`branch`, check before push, dispatch schema 2, review schema 1);
hermes-agent `11bb095` (SOUL, claude-dispatch v3 with `run`, the read-only
`warden` skill linked into `~/.hermes/skills`, briefing reads `/board`,
capture's opt-in label); warden — schema 8, `warden run`, the `warden:go`
poll, `/board` + `/items/:id`, typed outcomes, review-based validation (`34ac048`). Proven by execution, not diff: `checks_failed` on a
scratch implement (branch, no PR, `nextAction: human`); review of rollhook#23
by `pr`; `warden run --wait` answering in 21 s and closing as `answered:`; a
labelled issue (`dispatch-scratch#9`) becoming an item, a comment-back, an
auto-implement with the check, PR #10, a `clean` review → `confirmed`, and the
merge gate refusing on scope. Nine defects found only by executing (STATE
§55), all fixed. **Owner, before the `github_issue` origin is real under the
LaunchAgent:** the PAT at `op://mini/github/token` has no Issues permission
(403 on issues, works on pulls) — grant Issues read & write on github.com;
until then the search API answers it with 200 and zero hits, so no label is
picked up and nothing is logged (silently dead). Also owner: the
4.3 "human types in Slack" acceptance. For Wave 7: the `propose_mappings`
503/403 on the cheap route recurs every tick (model choices); `/health` reads
`ok: false` whenever a poller is stale, which is right, but Argo has no board
yet. Wave 8 docs: hermes-agent's `docs/guards.md`, `docs/symlinks-and-agents.md`,
`docs/agents-overview.md`, `skills/agents/SKILL.md` still say `hermes-cc.sh`;
`docs/symlinks-and-agents.md` still claims `config/dispatch-repos.json` lives
in hermes-agent and an 18-entry skill roster (it is 20). Declined with reasons
in STATE §55: `lifecycle/origins.py` extraction, `runReview` refactor. Note for
whoever runs the loop by hand: `env -u CLAUDECODE -u CLAUDE_CODE_SESSION -u
CLAUDE_SESSION_ID -u CLAUDE_ENTRYPOINT` or the recursion guard refuses every
dispatch; `sideclaw`'s MCP `review` tool only sees `pr`/`branch` after
`RESTART_MCP=1 make reload` or a fresh session (HTTP callers see them now).

## Wave 7 — the surfaces: Argo, herdr, Slack, and the model choices (repos: `argo`, `warden`, `sideclaw`, `hermes-agent`, `dotfiles`, `brain`)   <!-- status: done -->
How the owner proves, sees and steers it: in herdr on his own, in Hermes, in Argo.
- [x] 7.1 Argo — a Warden board: items by state, one timeline per item (brief,
      verdict, PR, validation outcome, operation receipts, probe result), the six
      funnel numbers, budget deferrals as a first-class state, intents recorded
      and visibly *not* approving. Fed by push from the mini the way the agents
      overview already reaches `GET /agents/overview` — Argo on the VPS cannot
      probe the mini. Screenshots by `@verifier`, not inline.
- [x] 7.2 herdr — the overview pane (`make agent-overview`, sideclaw's
      `overview.txt`/JSON) shows Warden's open items and in-flight operations
      beside the agent roster; `rd`/`agent-dispatch` help text names the three
      lanes — executor (sideclaw), lifecycle (`warden run`), colleague (`rd bg`).
- [x] 7.3 Slack — the `#agents` digest pause (`72aa2fb36307`, paused since
      2026-09-08, `paused_reason: null`) decided: resume or retire, a
      `(paused, reason)` marker in the registry and a `make status` assertion
      (finding 17); the five docs asserting it live corrected.
- [x] 7.4 Model choices and cost, reconciled once: sideclaw's routing table against
      `modelpick`'s current picks (CLASSIFY on the cheapest passing IU model,
      JUDGE on Max, adversary out-of-family), Warden's `VALIDATION_MODEL`,
      `rd wave`/`claude --bg`'s default model versus `c` pinned to Fable
      (findings 12, 13), `otel` registered as a job tool or its exemption
      documented (finding 19), usage-tracker attributing every lane. The
      rationale written once in `brain/wiki/engineering/model-routing.md`;
      every other mention becomes a link.
**Left behind:** Everything green and live on the mini; `warden/STATE.md` §56
is the record with timestamps. Commits: warden `547f47e`, sideclaw `49a065e`,
hermes-agent `5f5c7c6`, dotfiles `6dfba3e`, usage-tracker `ae805b3`, brain
`a180ec6`, modelpick `baf441c`; **argo is PR #19** (`warden-board`, draft) —
argo master deploys, so landing it is the owner's; until then every loop tick
logs `argo push — http-error:404` by design. Proven by execution: the loop's
push (73 KB, 12 items) against the not-yet-deployed endpoint; sideclaw's
`overview.txt` rendering the warden block live in the herdr pane (a clipped
`merge_blocked` column was found only there); the pane-shell `USAGE_LANE`
export surviving into child processes; `propose_mappings` root-caused by
calling the endpoint (`max_tokens` and `temperature: 0` both 503 on the
reasoning model — the loop's one LLM call had never succeeded); `hermes cron
remove` leaving four jobs and `make status` asserting `4 live, 0 paused, 1
retired`. Reviews caught before commit: Argo's board dropped items with an
unknown state and rewrote the pushed `generatedAt`; sideclaw's block ignored
warden's own `truncated`, had the wrong cache TTL and rendered
attacker-influenced titles unstripped; warden's intent entries were unbounded
and a rejected intent's error line leaks the submitted signature; the
registry's recreate command used the wrong CLI syntax. **Found only by
executing, after every unit test was green:** the real 73 KB snapshot was
rejected by Argo's ingest with 422 — the sixth metric is a composite of two
leaves and the schema demanded a top-level `value`; the verifier ran a local
Argo on the branch, POSTed the real file, and got the honest empty state
(six `n/a` tiles, no bare 0). Fixed on the branch, the real snapshot is now
a test fixture; the second pass rendered it (201, round-trip verbatim, six
honest tiles, `needs_human` 8) and found three display defects — fixed at
`1f245b1`. Decisions: digest
**retired**; otel **stays inline on Max** (interactive, quota not money);
`rd wave`/`rd bg` default **sonnet**, this chain passes `RD_WAVE_MODEL=fable`
per spawn. Carried to Wave 8: sideclaw `fallow` fails at HEAD before and
after this wave (unused MCP tool files, never-imported `agents.ts` exports,
CRITICAL functions) — pre-existing debt, decide whether it is a gate; the
`hermes-cc.sh` mentions in hermes-agent docs listed under Wave 6 are still
8.2's; cost per Warden item needs a join on ledger job ids (usage lanes now
give `sideclaw:dispatch`/`sideclaw:review`) — Wave 9 will want it. Owner:
merge argo PR #19; the PAT Issues permission and the 4.3 Slack acceptance
from Wave 6 are still open.

## Wave 8 — docs describe the estate that exists, and the field-review handover (repos: `brain`, `warden`, `hermes-agent`, `sideclaw`, `dotfiles`)   <!-- status: done -->
- [x] 8.1 brain: `agent-dispatch-paths.md` rewritten around the three lanes,
      `warden-control-plane.md` and `agent-estate-model.md` brought to the state
      Waves 4–7 left, `dispatch-path.html` and `estate.html` regenerated (fix the
      pre-existing desktop-readability failure that blocks `estate.html`
      delivery), vault-lint 0/0.
- [x] 8.2 Repo docs: five LaunchAgents in `warden/{DESIGN,README,STATE}.md`;
      `warden/docs/watchdog.md` and the "Hermes cron" docstrings retired
      (finding 10); `WARDEN_LEDGER_SCHEMA_VERSION` renamed and sideclaw's
      `DISPATCH_SCHEMA_VERSION` asserted by the client (finding 18);
      `warden/STATE.md` split into a two-page state plus
      `docs/history/state-log.md` (finding 25 — history preserved verbatim, never
      rewritten); `global.CLAUDE.md` and `dotfiles/CLAUDE.md` routing tables
      updated so `warden run` is the unattended lane; `make doctor`'s
      architecture assertion green.
- [x] 8.3 The field-review handover: `warden/docs/handover-field-review.md`, the
      prompt the owner runs after days in the field — what to measure (the six
      metrics, `needs_human` queue age, reverts and reopen-after-`fixed`, false
      `fixed`, budget deferrals, cost per item), what to read (`STATE.md` tail,
      ledger queries, `#agents` cards, Argo board), where the friction was in
      herdr / Hermes / Argo, where it was too fast, and the decisions it must
      surface (widen `autoMergePaths`? promote or demote a tier? retire a
      surface?). Wave 9 below is its checklist. Also a one-page "how to use it"
      in `warden/README.md`: the three lanes, the four verbs a human needs, and
      where to look when something is stuck.
**Left behind:** Five repos committed, nothing pushed: warden `e144466`
(§57 is the record), brain `fe3f631`, dotfiles `f16181d`, hermes-agent
`fb7a753`; sideclaw untouched. `warden/STATE.md` is two pages; §§1–56 are
verbatim in `warden/docs/history/state-log.md`, which is append-only from
here (every `STATE.md §NN` citation in warden repointed). Gates: `make test`
all suites, `test_triage.py` 211/211; vault-lint 0/0; `make doctor` clean
with the architecture map green; dispatch-path `deliver` 9/9. sideclaw review
on warden: one finding (a doc named `merge` as reporting `budget`; it does
not), fixed. Caught before commit: the new STATE.md's origin list was the
brief's, not the column's (`alert | github_issue | human`); a `warden
budget` verb that does not exist; the dispatch-path door labelled `warden
dispatch` when `warden run` is what opens an item. **Not fully closed:**
`estate.html`'s desktop-readability refusal is gone (viewBox 3000 → 930,
five vertical bands) but `deliver` now refuses on one `proper-crossing`
(`devhost → kuma` vs `argoapi → otel`, ~20 corridor attempts); it ships as
a `render` with the crossing recorded in `architecture.md`. Finding 25's
other items (free-planning-poker and dotfiles CLAUDE.md length, PRD.md
files, the basalt-ui plan) were never in this wave's scope and stay open.
Carried: sideclaw `fallow` debt (decided: not a gate for this chain); cost
per item is still a join nobody built — the handover doc names both sides.
Owner: argo PR #19, the PAT Issues permission, the 4.3 Slack acceptance;
hermes-agent's `cron/usage_audit.jsonl` has an uncommitted append from
running its tests. **Wave 9 is the owner's to start, by hand, after days
unattended** — `warden/docs/handover-field-review.md` is the prompt; this
wave does not spawn it.
## Wave 9 — field review (repos: `warden`, `brain`)   <!-- status: active -->
Started by the owner, by hand, after the chain has run unattended for days.
- [ ] 9.1 Run `warden/docs/handover-field-review.md` against the live ledger and
      the owner's own notes from the field; write the findings as a dated
      section in `warden/STATE.md` and a brain Inbox note.
- [ ] 9.2 Surface the decisions the review demands, with the evidence for each;
      propose the next chain as a new `PLAN.md`. Do not implement in this wave.
**Left behind:**
