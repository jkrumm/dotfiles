# Spike 7 / station-host: stations on one OpenCode 2.0.32 server (2026-10-26)

**Verdict: the design holds.** `station.ts` (542 lines, deps `ajv` + `yaml`) runs station packages as sessions on
one private OpenCode 2.0.32 server. Commands: `up | down | run | continue | show | cancel | inspect`. Every run
returns `{output, sessionId, cost, tokens, wallMs, steps, outcome, overBudget}` and writes one span line and one
usage line. It runs unchanged on Node 26.5.1 (`node station.ts`) and Bun 1.4.3, and `tsc --noEmit` is clean. The
stations are `brain`, `research`, `analyst`, plus a `_fixture-strict` test fixture. All use route `triage`
(the DeepSeek flash model), resolved per run through `agw routing`. Every check in the brief passed. The whole spike
was 70 sessions for **$0.069**.

## Owner decisions applied (2026-10-26)

- **Yolo is the default profile:** `* allow` plus `question deny`, because a question would block an unattended
  session. `profile: focused` (or `--profile focused`) compiles the allowlist, in its own location directory.
- **Budgets and steps are report-only.** Crossing one sets `overBudget: true`, nothing is cut, and the agent file
  carries no `steps` cap. Only `station cancel` interrupts a run.
- **Code and artifacts:** every run gets a scratch workdir. `analyst` returns `artifacts: [{path, kind}]`, and the
  host rejects any artifact that is missing, empty or outside the workdir.

## Per-location over compiled config

Each station compiles into a host-owned location directory with its own `AGENTS.md`, `.opencode/agents/` and
`.opencode/skills/`. That gives every station its own context and skills, and adding a station needs no server
restart. The design's objection (agent-gateway strips `.opencode/` from worktrees) applies to repo worktrees, not to
host-owned directories.

## Runs (yolo, route `triage`)

| Run | Outcome | Cost USD | Wall | Steps |
|-|-|-|-|-|
| brain: "OpenCode version pinning" | ok | 0.0044 | 15.0 s | 6 |
| brain `continue` follow-up | ok, used prior context | 0.0009 | 8.2 s | 4 |
| research (1 quick job, 5 sources) | ok | 0.0038 | 50.1 s | 3 |
| analyst: Python stats + `cost.svg` + `cost.csv` | ok, both files exist | 0.0047 | 15.5 s | 5 |
| brain, concurrent with the two runs above | ok | 0.0038 | 30.2 s | 10 |
| brain, `--budget-usd 0.0001` | ok, `overBudget: true`, not cut | 0.0028 | 17.6 s | 9 |
| analyst, cancelled during `sleep 150` | cancelled | 0.0002 | 14.6 s | 1 |
| fixture, schema error fixed by the re-ask | ok | 0.0028 | n/a | 2 |
| fixture, unfixable | `invalid_output` | 0.0009 | n/a | 4 |

Evidence: `evidence/01`–`13`, `spans.jsonl`, `usage.jsonl`, `cost.svg`, `cost.csv`.

## Permission boundary (focused profile, 18 probes, `test/boundary.sh`)

| Probe | Result |
|-|-|
| `rg` and `cat` inside the wiki | ran |
| `ls /`, `curl`, `/etc/hosts`, files outside `wiki/` | rejected |
| shell operators `;` `&&` `|` `>` `$()`, `$HOME`, `../`, a second path, `rg --pre` | rejected |
| one probe | made no shell call, so it is inconclusive |

**OpenCode alone is not the boundary.** With the host's guards removed, OpenCode still rejects compound commands
itself. A second path argument, `../` traversal and `rg x /etc <wiki>` then all run, because permission globs are
plain text. The host guards therefore have to cover `*..*`, `* /* /*`, dangerous flags and the server's own
credentials. A first `*|*` guard broke regex alternation and was dropped. This matters only for the focused profile.

## OpenCode 2.0.32 quirks found

- **Message paging:** the cursor can't be combined with `order` (HTTP 400). Use `order=asc&limit=200` for the first
  page, then `cursor=…&limit=200`.
- **`GET /api/info` needs auth** on this build.
- **Agent files are not hot-reloaded.** After an edit, evict the location with
  `DELETE /api/debug/location?location[directory]=…`. This silently invalidated the first bare-allowlist test.
- **Ancestor `AGENTS.md` files leak into a location:** the model quoted `dotfiles/AGENTS.md`. Put locations outside
  any repo.
- **The server ignores SIGTERM**, even when idle. `station down` escalates to SIGKILL after 5 s.
- **`_oc_env` also updates the shared per-user OpenCode service.** The host evaluates only its `export IU_KEY…` line.

## What agent-gateway needs to adopt this

1. A station registry: scan `station.yaml`, compile into a location directory outside any repo, evict on change,
   warm before first use.
2. An in-process route table in place of the `agw routing` exec.
3. `run | continue | show | cancel` endpoints over the existing `OpencodeClient`.
4. Session-ledger columns for station, caller and phase.
5. usage-tracker plus OTel export in place of the two JSONL files.
6. Both profiles in the OpenCode upgrade probe.
