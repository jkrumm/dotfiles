# Reconcile decision table & subagent brief

The orchestrator reads this to classify repos in Phase 2 and to brief the per-repo
subagents in Phase 3. `L` = local/MacBook, `R` = remote/Mac mini. "push" always
means a normal fast-forward push (never `--force`).

## Terminology

For each side you have from recon: `branch`, `dirty` (count), `ahead`, `behind`,
`upstream` (enum: `"true"` tracks-and-exists / `"gone"` upstream-deleted-stale /
`"false"` never-tracked-new), `unpushed_branches`, `local_only` (count),
`detached` (bool), `remote`.

"Current-branch work" = `dirty>0 OR ahead>0` — this drives the reconcile decision.

Side branches are a **separate concern** from the checked-out branch:
- `unpushed_branches` (`branch:N`) = non-current branches that track a remote and
  are ahead → push them (own line in the plan, not conflated with the current
  branch's reconcile).
- `local_only` (a count) = no-upstream local branches = the stale graveyard.
  **Never auto-push.** Report the count; only prune/push if the user asks. Pushing
  hundreds of dead local branches is the failure mode this rule exists to prevent.

## Decision table (repos present on BOTH machines)

| L state | R state | Same branch? | Action |
|-|-|-|-|
| clean, in sync | clean, in sync | yes | **Skip** — already synced. |
| clean, behind>0 | clean, ahead/in-sync | yes | **Trivial**: `git pull --ff-only` on the behind side. |
| has work | clean, in sync | yes | Commit wip on L → push → R `git pull --ff-only`. |
| clean, in sync | has work | yes | Symmetric: commit wip on R → push → L pulls. |
| has work | has work | yes | **Reconcile** (both diverged): commit wip on BOTH. One side pushes; the other `git pull --rebase` onto it, resolve conflicts, push; first side `pull --ff-only`. Pick the side with fewer local commits to rebase (less to replay). |
| any work | any work | **no** (different branches) | **Preserve both**: commit wip on each side, `push -u` each branch. Do NOT switch anyone. Queue an "align?" question. |
| current branch `upstream:"false"` (new) | — | — | `push -u origin <branch>` to create upstream, then normal reconcile. |
| current branch `upstream:"gone"` (stale, merged/deleted) | — | — | **Do NOT push -u** — the branch is dead. Move off it: `git switch <main>` (or `git switch -C <main> origin/<main>`), then reconcile main. Report it. If it may hold unmerged local work, confirm before leaving it. |
| no remote at all | — | — | **Skip**, report: no transport bus. |
| detached HEAD | any | — | **Skip**, report: refuse to auto-reconcile a detached head. |

### PR-required repos on master/main

If the repo is in `~/SourceRoot/dotfiles/config/pr-required-repos.json` AND the work
is on `master`/`main`, the branch-protection hook will reject the push. Instead:

1. Create `sync/<host>-<YYYY-MM-DD>` from the current master tip.
2. Move the wip commit / dirty work onto it (`git switch -c sync/…`, commit, push).
3. Leave master untouched. Report: "moved master work to branch `sync/…` (PR-required)."

Never push wip commits to a protected master.

**Only `master`/`main` are protected.** Pushing a *side branch* on a PR-required repo
(e.g. `basalt-ui feat/new-theme`) is a plain push, completely unaffected by the
hook. Don't route side-branch work through a `sync/…` branch — that dance is only for
work sitting on the protected branch itself.

## Same-branch reconcile — exact sequence

Given both sides have work on branch `B` with remote as bus:

```
# On the side chosen to go FIRST (fewer local commits to preserve, call it S1):
S1: commit wip if dirty  →  git push        # S1 now == remote
# On the other side (S2):
S2: commit wip if dirty
S2: git pull --rebase                        # replay S2's commits on top of S1's
    # → if conflicts, resolve (see policy), git rebase --continue
S2: git push                                 # remote now has both
# Back on S1:
S1: git pull --ff-only                       # S1 catches up; all three in sync
```

Run the S1 side and the S2 side each in the correct machine (local git vs
`ssh mac-mini 'cd ~/<root>/<repo> && …'`). Never interleave a push from both sides
before the rebase — the second plain push would be rejected as non-fast-forward,
which is the signal you skipped the rebase step.

## Conflict resolution policy

- **Auto-resolve** (no user needed): regenerated lockfiles (`bun.lock`,
  `pnpm-lock.yaml`, `package-lock.json` — prefer the newer/union, then reinstall if
  needed), both-sides-added-the-same-import, pure formatting/whitespace clashes,
  generated files.
- **Escalate to the user**: any conflict where the two sides express *different
  intent* in the same code — show the file, both `<<<<<<< / >>>>>>>` hunks, and a
  recommendation. Do not guess at meaning; a wrong auto-merge is worse than a
  question.
- If a rebase gets messy, `git rebase --abort` and fall back to reporting the repo
  as "needs manual reconcile" rather than leaving it half-rebased.
- **Don't trust commit messages — diff the content.** Two commits with the *same
  message* can be different patches (a rebased/amended/cherry-picked duplicate of
  work already on the remote). Before treating a local commit as "new work to
  preserve," check whether its change is already upstream: `git cherry -v <upstream>`
  or compare `git patch-id`. A stale duplicate should be dropped in the rebase, not
  replayed as a conflict.

## Subagent brief template (Phase 3)

Spawn one `implementer` subagent per non-trivial repo with a brief like this:

```
Reconcile the git repo <repo> between this MacBook and the Mac mini. You own this
repo exclusively; do all its git work.

Local (MacBook) path:  <L.path>
Remote (Mac mini):     ssh mac-mini 'cd ~/<root>/<repo> && <git cmd>'

Current state (recon snapshot — may be stale, re-verify first):
  MacBook: branch=<L.branch> dirty=<L.dirty> ahead=<L.ahead> behind=<L.behind>
           upstream=<L.upstream> unpushed=<L.unpushed_branches>
  Mac mini: branch=<R.branch> dirty=<R.dirty> ahead=<R.ahead> behind=<R.behind>
           upstream=<R.upstream> unpushed=<R.unpushed_branches>

Do this reconcile: <the specific plan line, e.g. "both sides have work on master;
commit wip on both, mini pushes first, MacBook pulls --rebase and pushes, mini
pulls --ff-only">

Rules:
- FIRST re-verify: `git fetch` both sides and re-check ahead/behind/upstream. This is
  an active repo; if state moved from the snapshot above, adapt (and say so).
- Uncommitted work → one commit: `git commit --no-verify -m "wip(sync): snapshot
  from <host> <date>"`. ALWAYS `--no-verify` — a wip snapshot must not run
  pre-commit hooks (they waste time and FAIL on the mini: `ssh` is a non-login shell
  with a bare PATH, so lefthook/husky `bunx` → exit 127). Never force-push.
- Push the side branches listed in `unpushed_branches` (they track a remote and are
  ahead) — a plain push each, own step. Do NOT touch no-upstream local branches (the
  `local_only` graveyard). Side-branch pushes are unaffected by PR-required master
  protection.
- `upstream=gone` on the current branch → the branch is stale (merged/deleted). Do
  NOT push -u. Move off it onto the live main branch and reconcile that. `upstream=
  false` → genuinely new → `push -u`.
- PR-required repo with work ON master/main → move that work to `sync/<host>-<date>`
  branch, push that, leave master alone. PR-required list: <paste from
  pr-required-repos.json>.
- Conflicts: auto-resolve mechanical ones (lockfiles, dup imports, formatting);
  STOP and report file+hunks+recommendation for genuine semantic conflicts. Don't
  trust commit messages — diff content (`git cherry -v`) to spot stale duplicates.
  Abort a messy rebase rather than leaving it half-done.
- Different branches on each machine: push BOTH, do not switch either checkout.
- If a mini command genuinely needs node/bun on PATH (rare — plain git doesn't),
  wrap it: `ssh mac-mini 'zsh -lic "cd ~/<root>/<repo> && <cmd>"'` (login shell
  sources the profile with fnm/bun shims; `bash -lic` does NOT — the mini's shell is
  zsh).

Return ONE line: `<repo>: <what you did> [wip commits: N] [needs user: yes/no + why]`.
```

## Host name for wip commits

Use `macbook` for the MacBook and `macmini` for the Mac mini in the wip message and
`sync/<host>-…` branch names, so it's obvious where a snapshot originated.
