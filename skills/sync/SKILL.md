---
name: sync
description: >-
  Bidirectionally sync all git repositories between this MacBook and the always-on
  Mac mini (over SSH), using GitHub/GitLab as the transport. Commits and pushes
  uncommitted/unstaged work on both machines, then rebases/fast-forwards each side
  so they converge — with per-repo subagents that resolve rebases and merge
  conflicts intelligently. Use this whenever the user mentions syncing machines,
  syncing repos, "catch up" the laptop to the Mac mini (or push laptop work back),
  is about to travel or just got back, has uncommitted work scattered across many
  repos, or asks to reconcile branches that diverged between the MacBook and the
  Mac mini. Trigger even when the user just says "sync", "sync my machines", or
  "get my repos up to date" without naming git explicitly.
---

# sync — MacBook ⇄ Mac mini repo reconciliation

Keep every git repo consistent across the two machines. The **MacBook is always
the orchestrator** (this skill runs here); the **Mac mini is always the remote
peer**, reached with `ssh mac-mini`. GitHub/GitLab is the transport — nothing is
copied machine-to-machine directly, so the flow is: commit local work → push →
pull the other side → reconcile.

**The user has chosen these defaults (do not re-litigate them):**

- **Uncommitted work becomes a plain real commit** — `wip(sync): snapshot from
  <host> <YYYY-MM-DD>` — normal push, normal rebase-pull. **Never force-push.**
  These wip commits are allowed to accumulate in history; the user squashes them
  later with `/git-cleanup` or `gback` when resuming. Do not try to write clever
  per-file commit messages; keep the wip commit uniform and fast.
- **Bidirectional by default** — reconcile both directions in one run; per repo,
  figure out who is ahead.
- **Different branches per machine → preserve both.** Commit+push *both* branches
  (nothing is ever lost — both end up on the remote), report the mismatch, and
  *then* ask whether to check one branch out on both machines. Never drop a branch
  without asking.
- **Plan → one confirmation → execute.** Always print the full reconcile plan and
  get a single go-ahead before doing anything with side effects. Then run it all,
  stopping only on a genuine merge conflict a subagent can't confidently resolve.

## Phase 0 — Preflight

1. Confirm you are on the MacBook (`hostname` — the mini is `Minivonohannes3…`).
   If run on the mini, stop and tell the user this skill orchestrates *from* the
   MacBook.
2. Confirm the mini is reachable: `ssh -o ConnectTimeout=8 mac-mini 'echo ok'`.
   If it fails, report and stop — no half-sync.

## Phase 1 — Recon (read-only, safe)

Gather git state on both machines with the bundled script. It takes root *names*
relative to `$HOME` so the same call works despite different usernames
(`johannes.krumm` here, `jkrumm` on the mini).

```bash
SKILL=~/.claude/skills/sync
# Local (MacBook)
bash "$SKILL/scripts/recon.sh" SourceRoot IuRoot > /tmp/sync-macbook.jsonl
# Remote (Mac mini) — pipe the script over stdin, runs there
ssh mac-mini 'bash -s -- SourceRoot IuRoot' < "$SKILL/scripts/recon.sh" > /tmp/sync-mini.jsonl
```

The default does a parallel `git fetch --prune` per repo first, so `ahead`/`behind`
are accurate. Add `--no-fetch` (before the root names) for a quick offline peek.

**Abort guard — do not skip this.** If the remote recon exits non-zero or produces
**zero lines**, STOP. Never build a plan from a one-sided recon: an empty mini file
makes every repo look "MacBook-only," and acting on that could push over or ignore
real remote state. A common cause is a transient 1Password SSH-agent failure
(`signing failed … communication with agent failed`) — retry the SSH command once
or twice; if it keeps failing, report it and stop. `[ -s /tmp/sync-mini.jsonl ]`
must be true before proceeding.

Each line is JSON: `{root, repo, path, branch, detached, dirty, upstream, ahead,
behind, remote, head, head_date, head_msg, unpushed_branches, local_only}`.

- `unpushed_branches` — comma list of `branch:N`: **non-current** branches that
  already track a remote and are N commits ahead. This is real unpushed work on a
  side branch — push it.
- `local_only` — a **count** of no-upstream local branches. These are almost always
  the stale graveyard (old, merged, remote-deleted branches). **Never mass-push
  them.** Surface the number ("repo has 250 local-only branches") and only act if
  the user explicitly asks to review/prune them. Mass-pushing hundreds of dead
  branches to pollute the remote is the classic wrong move here.

The **checked-out branch** is always synced regardless of upstream status (that's
the reconcile/mismatch logic below) — so a brand-new local current branch still
gets `push -u`. The graveyard rule only applies to *non-current* branches.

Read both files. Match repos by **`(root, repo)`** (same relative path on both
machines). This handles that folder names, not remotes, define identity —
duplicate clones like `argo` vs `argo-old` are treated as separate repos.

## Phase 2 — Classify and build the plan

Classify every repo, then print a plan grouped by action. See
`references/reconcile.md` for the full decision table — the summary:

- **Both sides, clean, in sync** → skip (list briefly under "already synced").
- **Both sides, work on the same branch** → the reconcile case. Sequence pushes so
  the second pusher rebases onto the first. Subagent handles it.
- **Different branch per machine** → push both branches, flag mismatch, queue an
  "align?" question for after execution.
- **No upstream / local-only branch with a remote** → `push -u` to create it.
- **No remote at all** → report, skip (can't sync without a bus).
- **PR-required repo (`config/pr-required-repos.json`) with work on `master`/`main`**
  → the branch-protection hook blocks pushing master. Move the work to a
  `sync/<host>-<YYYY-MM-DD>` branch, push that, and report it instead.
- **Detached HEAD** → report, skip (never auto-reconcile a detached head).
- **Repo on only one machine** → report under "MacBook-only" / "mini-only" and do
  NOT touch it (user's explicit call: sync is strictly machine-to-machine). Still
  **flag the ones with uncommitted work** (`[uncommitted]`) so the user knows that
  work isn't backed up — they'll commit it themselves. Offer to clone to the other
  side only if the user asks.

Print the plan like the example the user approved:

```
PLAN — MacBook ⇄ Mac mini
 RECONCILE (subagent per repo):
   free-planning-poker   rebase 1 local commit onto 48 remote, then push wip
   argo                  mini has 16 dirty + feat/argo-voice → commit, push, MacBook pulls
   student-enrolment     push BOTH branches (feat/enable-reimport ⇄ fix/gasthoerer-…) — ALIGN?
 TRIVIAL (inline):
   dotfiles              MacBook 1 dirty → wip commit + push; mini ff
 SKIP (already synced):  argo(?), homelab, vps, modelpick, …
 MacBook-only:           photo-flow, busplan, open-news, snow-finder, …
 mini-only:              hermes-agent, audio-gateway, research-gateway, argo-old(detached), …
 QUESTIONS AFTER EXECUTE: align student-enrolment branch?
```

Then ask for the single confirmation. **Nothing with side effects runs before this.**

## Phase 3 — Execute

After confirmation, split the work:

- **Trivial repos** (one side clean, other has only a linear push, or a pure
  fast-forward) — handle inline with plain git. Fast, no subagent overhead.
- **Non-trivial repos** (rebase needed, both sides have work, conflicts possible,
  PR-required-master, no-upstream) — **spawn one `implementer` subagent per repo**,
  in parallel across *disjoint* repos (each repo is independent, so this is safe
  fan-out). Give each the brief from `references/reconcile.md` (the "Subagent brief"
  template): both-sides state, the house rules above, and the specific reconcile it
  must perform. Each subagent runs git locally *and* `ssh mac-mini` for the mini
  side, resolves rebases/conflicts with judgment, and returns a one-line result.

**Conflict policy for subagents:** auto-resolve the obvious mechanical stuff
(regenerated lockfiles, both-added-same-import, formatting-only clashes). Escalate
to the user only a genuine *semantic* conflict where either resolution could be
wrong — with the file, both hunks, and a recommendation. Don't guess on meaning.

**File-ownership caveat:** a repo is owned exclusively by its subagent while it
runs. Never run your own git/validation over a repo a subagent is mid-reconcile on.
Parallelize on disjoint repos only.

## Phase 4 — Report and follow-ups

Collect the subagent result lines and print a final summary: what synced, what wip
commits were created (and where to squash them), what was skipped and why. Then ask
any queued questions (branch alignment for mismatched repos). Do not silently
converge branches — that was the user's explicit call.

If wip commits were pushed, remind: "resume with `gback` (soft reset) on the
receiving machine to get your working tree back, or `/git-cleanup` to squash."

## Notes

- **IuRoot is in scope** (GitLab). Git ops need no 1Password account; the transport
  is SSH-key git. `student-enrolment` is the flagship mismatch case.
- Keep the orchestrator context clean: recon output goes to `/tmp`, per-repo grind
  goes to subagents. The orchestrator holds the plan and the verdicts.
- This skill is symlinked from `dotfiles/skills/sync/`; edit there and it's tracked.
