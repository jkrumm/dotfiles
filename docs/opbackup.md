# opbackup + the secrets auto-reseed

`opbackup` (`scripts/backup-1password.py`) exports every vault, age-encrypts it in
memory and rsyncs the ciphertext to homelab. The same hourly agent
(`com.jkrumm.opbackup`) also reseeds the headless mini's secrets cache, through
its own guard in `scripts/opbackup-seed-auto.sh`.

Commands and the one-line rules live in `AGENTS.md` → *opbackup + secrets
auto-reseed*; this is the rationale behind them.

## Why it stays attended

The first `op` call raises a biometric approval, and every way around that parks
a credential able to export every vault. The goal is not an unattended backup —
it is a prompt at a sane moment, on a machine with a human in front of it.

## The backup guard

- **Hourly via `StartCalendarInterval`**, never `RunAtLoad`/`StartInterval` — only
  calendar intervals coalesce a fire missed while asleep into one wake-up run.
- **Every decision lives in `scripts/opbackup-auto.sh`**, cheapest-first, each
  exiting **0** (a skip is the normal case). Two separate stamps (success >5d,
  attempt >6h), because declining an approval must not mean being asked again in
  60 minutes forever. Screen lock is `ioreg -n Root -d1 -k
  CGSSessionScreenIsLocked` — the key is **absent** while unlocked — read into a
  variable, never piped to `grep -q` (`pipefail` turns SIGPIPE into a false fail).
- **Retention:** `prune_remote()` keeps the newest 8 plus the newest per calendar
  month, deleting an explicit regex-validated filename list, never a remote glob —
  an old dump stays decryptable after the passwords in it are rotated.
- **A skip line in `~/Library/Logs/opbackup.log` is a claim, not a diagnosis** —
  three Secrets gotchas above (whoami, per-binary approval, a locked app reading as
  "mini unreachable") each present as a clean deliberate skip.
- **One transient `op read` failure must not discard a whole ~150-ref run** — reads
  are `timeout -k`-bounded and retried 3× **on transient errors only**; retrying a
  genuinely missing ref just delays an error a human has to fix.

## The reseed trigger — why age is not enough

The reseed guard used to fire on one condition: the mini's cache file older than
`MAX_AGE_DAYS` (5). That is the wrong question, and it produced a daily chore.

An agent on the mini that needs a new secret adds the ref to
`dotfiles-private/headless.refs` and commits it. The mini's cache is still *fresh
by mtime* — nothing about it changed — so the age gate skipped, for up to five
days. Meanwhile the ref it needs does not resolve, so the agent does the only
thing left to it: enqueues an `ask-human` request asking for a manual
`make secrets-seed`. That is the loop that made the queue feel like a daily tax.

The second half of the same bug is worse because it is silent. This machine
seals from **its own** checkout of dotfiles-private. Nothing pulled it. So even
a reseal that ran — manually, or on the 5-day tick — sealed a refs list that did
not contain the new ref, reported success, and delivered a cache missing exactly
the secret that triggered it. Observed 2026-09-07: `secrets-seed` reported *161
secrets sealed* while `op://vps/argo/HYPERDX_API_KEY_PROD` was still
unresolvable on the mini, because the MacBook's checkout was one commit behind.

The fix treats **the refs list changing as the cache going stale**, which it is:

1. `git fetch` dotfiles-private, bounded by `timeout` and `GIT_TERMINAL_PROMPT=0`
   — `origin` is `git@github.com` over the per-use biometric 1Password agent, and
   an unanswered approval on an unbounded fetch wedges the hourly job.
2. Compare the **blob hashes** of `headless.refs` and `headless.iu.refs` at
   upstream against the pair recorded at the last successful seal
   (`$STATE_DIR/seed-last-refs`).
3. Different ⇒ due, bypassing the age gate. Fast-forward first, then seal, then
   record the sealed pair.

The first version compared the newest refs **commit date** to the cache mtime.
That looked stateless and elegant, and has a real hole: commit time is not push
time. Commit a ref at 10:00, let the age gate seal at 10:30, push at 10:35 — the
comparison reads 10:00 < 10:30 forever and the new ref waits out the full five
days. Content hashes carry no ordering assumption. A missing stamp means
"unknown" and degrades to the age gate rather than forcing a seal on a guess.

The whole block sits **after** the backoff check: everything in it is a network
fetch and a working-tree mutation, and running it above the backoff meant an
hourly fetch — plus, on a broken checkout, an hourly macOS notification — for a
run that was about to skip anyway.

**A checkout that cannot fast-forward refuses to seal.** The first version warned
and sealed the stale list anyway and called that failing open. It isn't: sealing
rewrites the mini's cache mtime, so the next tick sees a 0-day-old cache, and
with the refs stamp untouched the run after that skips too. One warning, then
permanent silence, with a cache missing exactly the ref that triggered it — the
original bug moved one tick later.

Refusing keeps the cache honest instead. The refs stamp stays stale so the run
stays due, the attempt stamp throttles the retry to `RETRY_HOURS`, and if nobody
fixes the checkout the cache ages past the secrets-freshness monitor and goes
red. Visibly wrong beats invisibly wrong.

`make opbackup-seed-test` is the hermetic regression suite — stubbed ssh/op/
pgrep/ioreg and a local bare repo as `origin`, so it runs on either machine and
touches no network.
