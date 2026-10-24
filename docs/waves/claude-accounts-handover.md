# Claude accounts — orchestrator handover (2026-10-24 ~18:30)

Spec and rules: `docs/claude-accounts.md` (read fully). You are the orchestrator for
the rest of this project: merge W1, deploy, then run W2 to completion. Workers are
`rd fan` tabs; you review (`mcp__agent-gateway__review`), send fixes with `rd say`,
merge with `rd merge`, deploy, verify. Never edit worker-owned files yourself.

## Accounts (live)

| id | plan | dir | state |
|-|-|-|-|
| `iu` | IU-paid Max 20x | `~/.claude` (CLAUDE_CONFIG_DIR **unset**) | ~88% weekly, resets Tue 17:00 |
| `me` | personal Max 5x | `~/.claude-me` (keychain `Claude Code-credentials-7253dcbc`) | logged in 2026-10-24, 0% |

`~/.claude-me` symlinks skills/agents/hooks/rules/output-styles/plugins/CLAUDE.md/projects/logs
to `~/.claude`; `settings.json` is rendered. `~/.claude-b` is gone (renamed).

## Merged and live (W0)

- dotfiles #26: registry, `claude-account` picker (`~/.local/bin`), per-account quota cache
  (`~/.cache/claude-accounts/<id>.*`), statusline feed, session-env `account`, fetch_usage reader.
  Registry on master still says ids `a`/`b` with `~/.claude-b` until W1 merges.
- usage-tracker #9: `account` column; all historical Max rows = `a`. Argo receives but drops `account`.

## Open PRs (W1) — finish these first

| repo | PR | branch | worker tab (agent name) | state at handover |
|-|-|-|-|-|
| dotfiles | #27 | feat/claude-accounts-w1 | `dotfiles-claude-accounts-w1` | review 5c1a3f95 actionable (auth_failed never re-probed) → round 4 sent 2026-10-24 ~19:00 (+ env scrub, sid validation, mkdir -p, hasOwn); re-review after it reports |
| usage-tracker | #10 | feat/claude-accounts-rename | `usage-track-claude-accounts-rena` | review clean + follow-ups done (BEGIN IMMEDIATE, user_version gate) — ready |
| agent-gateway | #32 | feat/claude-account-pick | `agent-gatewa-claude-account-pick` | round-3 fixes sent (quota regex, token strip, fail-closed exclude, pin sweep/validation, exit-3 only for pick, epoch clamp, runSessionAttempt test) — re-review after it reports |

**Merge order (ids switch together):** usage-tracker #10 and dotfiles #27 back to back, then
agent-gateway #32. Before `rd merge`: `gh pr ready <n>`. Gate:
- dotfiles: `rd merge dotfiles --check 'make hooks-test jobs-test secrets-lint && bun test scripts/claude-account.test.ts' feat/claude-accounts-w1`
  (full `make check` fails ONLY on 8 pre-existing unmapped `com.iu.teamchat-*` LaunchAgents in
  architecture-check — not ours; tell the owner, don't fix).
- usage-tracker / agent-gateway: default `rd merge <repo> <branch>`.

**Deploy after merge:**
- dotfiles: `git pull`, `make claude-accounts-setup`, then the per-account MCP registration
  (`make setup` runs it; at minimum the MCP loop so `me` has chrome-devtools + research-gateway +
  agent-gateway), `source ~/.zshrc` note for the owner's open shells.
- usage-tracker: `make deploy` (a launchctl "Bootstrap failed: 5" means retry once), then verify
  `sqlite3 ~/.local/share/usage-tracker/usage.db "select account,billing,count(*) from usage_record group by 1,2"` → `iu|max|…`, NULL for iu billing.
- agent-gateway: its own `make deploy` / reload per its AGENTS.md; verify `/api/health`.
- `rd fan --clean <repo>` for each repo afterwards.

## W2 state (live log)

Briefs: `~/.local/share/claude-accounts-w2/{dotfiles,agent-gateway,argo,tinycast-extensions}.md`.

| repo | branch | tab | state |
|-|-|-|-|
| argo | feat/usage-account | `argo-usage-account` | fanned 2026-10-24 |
| tinycast-extensions | feat/quota-two-accounts | `tinycast-exte-quota-two-accounts` | fanned 2026-10-24 |
| dotfiles (W2a) | feat/claude-accounts-verify | — | waits for #27 merge |
| agent-gateway | feat/claude-accounts-usage | — | waits for #32 merge |

Decisions taken during W2:
- **Tinycast reads quota via Argo, not the tailnet door.** agent-gateway is loopback-only by design
  (`exclude agent-gateway` in `~/.config/caddy-tailnet.ports`, index.ts bind comment); the spec's door
  never existed (404). agent-gateway adds `quota` to `/api/overview`, which it already pushes to Argo
  (≤10 min); Argo stores it verbatim; Tinycast reads `GET /agents/overview`.
- `/api/usage` GET builds from `claude-account usage --json` (cache-only); POSTs gain optional
  `account` (fixes a live bug: a `me` statusline POST overwrites iu's numbers). Merge order:
  agent-gateway W2b before dotfiles W2a (W2a's producers send `account`).
- Heartbeat quota line moved into W2a (same file it already owns), read locally from `claude-account usage --json`.

## W2 (original plan)

- **W2a — verify, E2E, keepalive (dotfiles):** brief ready at
  `~/.local/share/claude-accounts-w1/w2-dotfiles.md` → `rd fan dotfiles ~/.local/share/claude-accounts-w1/w2-dotfiles.md`.
  Covers `make claude-accounts-verify` (in `make doctor`), `scripts/claude-accounts-e2e.sh` with
  real Haiku spawns per account + break tests, Claude-Code-update detection, daily
  `claude -p "/usage"` login keepalive LaunchAgent (no inference, no window priming), Operate docs.
- **W2b — displays (write briefs yourself, one per repo, disjoint):**
  agent-gateway `/api/usage` → `{accounts:{iu,me}}` + herdr overview pane shows both quotas and the
  account per agent; argo stores/filters `account` then run `bun run src/cli.ts resync-account` in
  usage-tracker once; tinycast-extensions `extension/src/usage/quota.ts` reads
  `https://agent-gateway.mini.jkrumm.com/api/usage` (tailnet door), shows both accounts, local
  fallback; heartbeat quota line both accounts.
- **E2E proof you run yourself at the end** (delegate to `@verifier` if it drags context): every
  launcher `c`/`cs`/`cf` (pick interactive → iu), `ca`/`cap`/`claude_iu` (IU endpoint, untouched),
  `rd wave` + `rd fan` (→ me unless me walled), an agent-gateway worker job (→ me for non-review
  tools), and confirm `session_env.account` + usage-tracker rows per path. Subagents inherit the
  parent's account (same process) — confirm once.

## Known gaps / decisions already made

- Spill sentinel is stdout `spill` + exit 3; registry unreadable = exit 4 + `unset` (iu safe default).
- `claude-auth.zsh` token fallback applies to iu only (live bug fixed in #27).
- herdr restart may resume a `me` session on iu (cold cache) — accepted for now; check whether
  herdr persists pane `--env`.
- No `op://mini/claude-me/oauth-token`; `me` has keychain login only.
- Owner said: name accounts `iu` / `me`; split by responsibility (lane), not project; route
  automatically; iterate on thresholds from `~/.local/share/claude-accounts/picks.jsonl` (W3).
