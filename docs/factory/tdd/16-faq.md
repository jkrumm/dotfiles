# FAQ

**Can I still just use Claude Code in herdr?** Yes. Your sessions are outside the loop unless you hand
work to it. The picker keeps choosing the account for you.

**What if both Max accounts are walled and production is down?** The deterministic parts still run:
settle, restart, rollback to the last good deploy, runbooks. Code waits for the first reset. No IU
fallback, by your rule — rollback is usually the faster fix anyway.

**Why does IU review every factory change if IU must not write code?** Review reads code; it does not
change it. Cheap angle reviewers plus a DeepSeek adversary — another model family — are the second
pair of eyes pstack and oh-my-hermes both insist on, at ≈ $2.40 a full review.

**Why not let OpenCode/IU do small fixes, since it is cheap?** Because your rule is about where code
gets written, and because the expensive part of a fix is being wrong. Small fixes run at P1 on
whichever account has room — usually `me`.

**Why DBOS if it lost v1's spike?** It lost on its default configuration (§6). With the version pinned it
passed the redeploy test; patching covers the incompatible edit it failed and is tested in W1; on
crashes it was always equal. W1 re-runs the spike on Postgres before anything depends on
it, with v1's own design as the measured fallback.

**Why Node, when everything else runs on Bun?** DBOS' TypeScript SDK supports Node only; its workflow
context sits on `node:async_hooks`, which Bun implements partially. One service on Node is a smaller
cost than hand-writing durable execution.

**Why not keep warden and refactor it?** You asked for a sunrise, and the data says the same: warden's
65-column item row, its Slack intake and its escalation rules are the parts v1 had to work around.
Nothing in warden.db is needed to run the new loop; the golden set already captured what was worth
learning from it.

**What do I lose during the rewrite?** Warden's triage and its Slack summaries, for about three days
until W1 heals the first failure class. Raw alerts keep flowing to Slack.

**How much does it cost?** No new Max spend — factory code work fits the pool's headroom and the
capacity that would lapse. IU grows by ≈ $50–95 a week, mostly review; review-depth gating is the
lever.

**How do I steer something in flight?** Argo intents (steer, pause, stop), a comment on its plan in
*Artifacts*, Hermes, or `factory issue|task|session` from any shell.

**Where does this document live?** In `dotfiles/docs/factory/` until W0, then in the factory repo's
`docs/`. It is the source of truth; the public guide on jkrumm.com is written from it once W9 has
real numbers to show.

**What is the first thing I will notice?** After W1: a container that stops comes back on its own,
and you read about it in the next morning briefing instead of in Slack.
