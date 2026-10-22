# Evidence — conventions

Every number in `../report.html` comes from a script here, with its output stored next
to it. Nothing in the loop can edit these scripts' inputs: they read frozen snapshots or
append-only stores, read-only.

## Rules for every script

- **As-of time:** `AS_OF=2026-10-22T08:00:00Z` (env override). Filter every
  timestamped row to `< AS_OF`. Windows are named relative to it: `14d`, `30d`, `90d`, `all`.
- **Mutable stores come from the frozen snapshot**, never the live file:
  `~/.local/share/factory/snapshots/2026-10-22/{warden.db, agw-jobs.db, usage.db,
  research-jobs.sqlite, human-queue/}` — created by `snapshot.sh`. Open SQLite as
  `sqlite3.connect("file:<path>?mode=ro", uri=True)`.
- **Append-only stores are read live, filtered by `AS_OF`:** git (`git log --before`),
  Claude Code transcripts (`~/.claude/projects/**/*.jsonl`; MacBook copy via
  `ssh iumac`), OpenCode (`~/.local/share/opencode/opencode.db`, read-only), Hermes
  (`~/.hermes/state.db`, read-only), `~/Library/Logs/*`.
- **Never load a whole large store into memory or into an agent's context.** Stream
  files, aggregate in SQL, print summaries.
- **Language:** Python 3 stdlib only (`python3 -I`), or `sqlite3`/`jq`/`git` in shell.
  No network except `ssh iumac` / `ssh homelab` / `ssh vps` read commands.
- **Outputs:** `<script>.out.json` (machine-readable, every number the report cites,
  with its definition key) and, where useful, `<script>.out.md` (human table). Stable
  key order, so a re-run diffs cleanly.
- **Public repo:** dotfiles is public. Pass every free-text field (titles, payload
  excerpts, notes, commands, owner messages) through `lib/redact.py:redact()` before
  writing. No hostnames, IPs, tokens, internal URLs; `~` paths only; IuRoot repos by
  name only, never their content. Gate before commit:
  `python3 -I lib/redact.py --check $(git ls-files -mo --exclude-standard .)`.
- **Header:** each script starts with a docstring naming the question it answers, the
  definition keys from `DEFINITIONS.md` it implements, its inputs, and how to run it.
- `run-all.sh` re-runs every script in dependency order.

## Layout

| Dir | Question |
|-|-|
| `kpi/` | the baseline, one definition per metric (`DEFINITIONS.md`) |
| `postmortem/` | why every locked model since the September estate round drifted |
| `incidents/` | the ten costliest incidents and the twenty latest owner interventions, raw signal to closure |
| `golden/` | ≥ 400 labelled warden events (entity-centric sample) and the backtest over them |
| `toil/` | what the owner and agents repeat by hand |
| `signals/` | the primary sources behind the Slack relays |
| `gameday/` | the baseline gameday run |
