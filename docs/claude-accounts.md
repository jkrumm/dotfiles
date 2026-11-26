# Claude Max accounts: the dotfiles side

Several Claude subscriptions behave as one pool: no manual switching, no lost prompt cache, every display shows every
account and every usage row says which account paid. The picker, the quota cache, the pick rule, the modes and the
health grading are the software-factory `packages/accounts` package, the `claude-account` CLI. Its docs are the one
source for them: `~/SourceRoot/software-factory/packages/accounts/docs/accounts.md` (rule §The picker, quota feeds
§Quota sources, §Modes, §The host block). Verbs and flags: `claude-account --help`.

This page is what stays in dotfiles: the owner's registry and the adapters around the package (launchers and `rd`,
statusline record, peer import, keepalive, heartbeat, re-login, displays).

## Invariants

1. **The account is chosen at spawn, never mid-session.** The prompt cache is
   scoped per organisation, and two Max accounts are two organisations. Switching
   mid-session or running `--resume` under the other account re-sends the whole
   context uncached (one rebuild ≈ 300k tok × 2× input ≈ $2.4 API-eq on Opus 5.5).
2. **Official binary, own logins, no relay.** Never route credentials through
   claude-relay-service, CCR or LiteLLM pools, and never run rotation that swaps
   logins under a live process. Anthropic staff (2026-02-18): multiple Max
   accounts are not a ToS violation; reselling is. Relays and credential
   intermediation are what enforcement targets.
3. **Split by responsibility, not by project.** The account follows the lane
   (`USAGE_LANE`), so it doesn't matter which repo or machine the work starts from.
4. **Account `iu` stays at the default path.** `CLAUDE_CONFIG_DIR` is *unset* for
   `iu`. Setting it to `~/.claude` explicitly changes the Keychain service to
   `Claude Code-credentials-<hash>` and `iu` would look logged out.

## Accounts and on-disk layout

| Id | Plan | Config dir | Keychain service | Capacity units (session / weekly) |
|-|-|-|-|-|
| `iu` | Ultra | `~/.claude` (env unset) | `Claude Code-credentials` | 4 / 2 |
| `me` | Max | `~/.claude-me` | `Claude Code-credentials-<sha256("~/.claude-me" abs)[:8]>` (`-7253dcbc`) | 1 / 1 |
| `me2` | Max | `~/.claude-me2` | `Claude Code-credentials-<sha256("~/.claude-me2" abs)[:8]>` (`-a3d9de83`) | 1 / 1 |

The suffixes above are the mini's: the hash covers the absolute dir, so it differs per machine whenever `$HOME` does
(`printf %s "$HOME/.claude-me2" | shasum -a 256 | cut -c1-8` prints this machine's). `me2` shares the bulk lanes with `me`.

The Keychain naming is verified in the 2.1.310 binary (`Jj()`: suffix =
first 8 hex of sha256 of the config dir). The capacity units come from measured
ratios: 20x/5x ≈ 3.7× per session and ≈ 2.0× per week (mulletiq regression).

`~/.claude-me` is created by `make claude-accounts-setup` (idempotent):

- **Symlinked to `~/.claude`:** `skills agents hooks rules output-styles commands
  plugins CLAUDE.md projects logs`.
  - **`projects/`:** shared, so `--resume` works across accounts and usage-tracker
    keeps one root.
  - **`logs/`:** shared, so `session_env` lines land in one place.
- **`settings.json` is rendered, not linked.** Claude Code rewrites it by
  temp-file-and-rename, which silently replaces a symlink with a real file
  (agswt trap). `make setup` already merges the template into
  `~/.claude/settings.json`; it runs the same merge into `~/.claude-me/`.
  Identical `cleanupPeriodDays` in both keeps the shared `projects/` sweep safe.
- **Per account (never link):** `.claude.json` (oauthAccount,
  `cachedUsageUtilization`, trust, **user-scope MCP**), credentials,
  `history.jsonl` (symlinks rejected since 2.1.278), `file-history/`,
  `stats-cache.json`, `ide/`.
- **Never copy credentials between dirs.** Each dir does its own `/login`, because
  two homes sharing one refresh-token family invalidate each other (caam,
  ClaudeBar).
- **User-scope MCP servers** live in `.claude.json`, so a registration loop would run once per enabled
  account (`CLAUDE_CONFIG_DIR=… claude mcp add-json …`). None is registered today: `chrome-devtools`
  is inline in `agents/browser.md`, and `make setup` only removes a leftover registration per account.
- Same for every other `~/.claude.json` writer: `_claude_theme_auto`
  (`claude.zsh:40`) pre-trusts; it loops over the
  registry.

## Package

| Machine | `~/.local/bin/claude-account` is a link to | Kept level by |
|-|-|-|
| mini | `~/.software-factory/current/packages/accounts/bin/claude-account.ts` (the live release, as `factory` is linked) | the factory's deploy |
| MacBook (no factory checkout) | `~/.local/share/claude-account/claude-account`, the package's built single file | `scripts/claude-account-sync.sh`: pulls it through the core (`hc exec --on mini cat`), swaps only if it differs and `--version` names the package; runs after every factory deploy (post-deploy hook, gate verb `claude-account-sync`), on `make herdr-app-setup` and on `make claude-account-link` |

`make claude-account-link` (run by `make setup`, `make claude-accounts-setup` and the MacBook's `dotfiles-sync`) links the CLI
and links `config/claude-accounts.json` to `~/.config/claude-accounts/registry.json`, the path the package reads first.
`claude-account --version` prints `@software-factory/accounts <version> (<commit>)`; the mini's `make doctor` row compares it
with the MacBook's (`ssh iumac account-version`) and warns when they differ; an off MacBook is info. A bad release is
rolled back in software-factory (`make rollback`), not here.

## Registry

`config/claude-accounts.json` is the owner's data and the single source of which accounts exist (ids, dirs, plans, home
lanes, `loginBrowser`, enabled flags, `platform` blocks). Field semantics and validation: the package docs §The registry.
`scripts/claude-account-host.test.ts` loads it with the live release on the mini. What is specific here:

- `enabled` stays false until an account's login exists, so a new account ships dark (§Operate, Adding an account).
- `host`: this setup's two machines. The mini reaches the MacBook over `ssh iumac` (fixed gate verbs), the MacBook the
  mini over `ssh mini`, both preferring the herdr-core. `reloginAsk` runs `scripts/claude-relogin.sh`, `wake` pushes through
  `scripts/ask-human.sh` and notifies, `afterAdd` runs `make claude-accounts-setup`.
- `platform`: read by the agent-workflows gateway only (§Operate, Platform).

### Fable mode

Fable resets refill only Fable usage, so one account can be set aside for it: the top-level `"fable": "<id>"` (`null` =
off). `cf` launches on it (`claude-account fable` prints it; `cf --account <id>` wins) and every other pick holds it back as
the last resort. `"drain": ["<id>"]` fills accounts first; it does not end by itself. Both are commit-to-switch, read on
every call; a dated override without a commit is `claude-account mode`. The rules: package docs §Modes.

## Feeds dotfiles supplies

- **Statusline record:** every render gets native `rate_limits` for the session's own account; `statusline.sh` hands them
  to `claude-account record`.
- **Peer import:** quota is per account, not per machine, so a refresh imports the other machine's samples (`host` block;
  the MacBook's gate verb `account-usage`). Auth state is never imported: logins are per machine.
- **Cache reader:** `scripts/fetch_usage.py` only reads the quota cache (on a stale default sample it runs
  `claude-account refresh --ids <default>`) and writes `/tmp/claude_sl/usage_api.json` (the default account) and
  `usage_accounts.json` (all accounts), which the statusline and Tinycast read.

## Spawn integration

| Spawner | What it does |
|-|-|
| bare `claude` in an interactive zsh (`claude()` in `claude-auth.zsh`; what a terminal in the core runs when you type `claude`) | `claude-account pick --lane ${USAGE_LANE:-interactive}` unless `CLAUDE_ACCOUNT_PICKED` is set (see Account marker); `--resume` and `--continue` pin; non-interactive shells, `-p`, info flags and subcommands (`auth`, `mcp`, …) never pick |
| `c` / `ch` / `cs` / `cf` (`claude.zsh` `_claude_launch`) | `claude-account pick --lane interactive` (`cf` skips it: always the Fable account, `claude-account fable`, §Fable mode); `--account <id>` override (strips the flag, runs in a subshell; a failing pick answers `iu` and says so on stderr); sets the marker for the `claude` it calls |
| `rd work` (`remote-dev.sh` `pick_account`, `spawn_env`) | pick before spawn and pass `CLAUDE_CONFIG_DIR` (absent for iu) and `CLAUDE_ACCOUNT_PICKED=<id>` in the spawn's `env` (iu included; the core's own env is every terminal's, so nothing is inherited and no typed `export` can race the shell); `USAGE_LANE` rides along. When no account has room `rd` pauses the spawn (no IU spill) |
| `claude-auth.zsh` token fallback (mini; `_claude_auth_run`, called by `claude()` after the pick) | `op://mini/claude/oauth-token` is injected **only** when `CLAUDE_CONFIG_DIR` is unset (`iu`) and its `claude auth status` fails. For any other dir the wrapper never injects a token: a dead login prints a `/login` hint on stderr and `claude` runs normally (the IU token on `me` ran the session on IU, verified live). Never export it otherwise (#37512: the env token deletes the Keychain entry on exit) |
| `hc-reap.py`, `remote-dev.sh` `claude agents --json` | query once per enabled account and merge |

Resume pins the account: `c --resume <id>` (also `-r`, `--resume=<id>`) looks the session up in the
`session_env` hook log (`claude-account session <id>`) and launches on the account it ran on, so the
cache stays warm and the work never changes provider. `--continue` / `-c` pins the same way: it resumes the newest
session of the cwd, so `claude-account latest "${PWD:A}"` (the physical path: Claude Code keys the transcript dir by the resolved cwd, so a symlinked `$PWD` would miss) finds that session (newest `<id>.jsonl` by mtime under the shared
`~/.claude/projects/<cwd, every non-alphanumeric as '-'>/`) and the lookup above gives its account. Both lookups fall
through to the normal pick when they find nothing: no transcript for the cwd, or a `session_env` line older than the
hook log's 3-day retention (a `--continue` into a session older than that re-picks, and the context is cold anyway).
The hook line carries no cwd, which is why the transcript directory, not the log, answers "which session". `--account` overrides.
A running session never changes account: `CLAUDE_CONFIG_DIR` is fixed at spawn and subagents inherit it.

**Account marker (`CLAUDE_ACCOUNT_PICKED=<id>`).** An iu pick is `unset CLAUDE_CONFIG_DIR`, indistinguishable
from "nobody chose", so the decision travels in this variable instead:

- every chooser sets it: `c`/`ch`/`cs`/`cf` (in their subshell, with `--account`/resume pins), `rd work`
  (the spawn's `env`, from `pick_account`'s `# picked=` line). Children inherit it, so a nested `claude` never re-picks.
- the routing reason rides with it as `CLAUDE_ACCOUNT_REASON=<reason>` (the picker's `reason=`, `forced` for `--account`, `resume`
  for a session pin; unset when unknown), set and unset together with the marker by `_claude_enter_account` and by `pick_account`'s
  spawn `env`. It is display-only (kept for Tinycast and later displays; the statusline does not render it); nothing routes on it.
- bare `claude` in an interactive zsh picks unless the marker is set **and consistent**: the marked account's registry dir
  must equal the current `CLAUDE_CONFIG_DIR` (iu = unset; one `jq` read, only when the marker is set). A stale marker
  inherited from a long-lived parent (a core's env, an old shell) fails that check and is ignored, so it cannot
  silently skip the pick; every chooser sets marker and dir together. An unreadable registry lets the marker stand. It
  then sets the marker inside a subshell (the terminal's own
  environment stays unmarked: the next `claude` typed there is a new spawn and picks again).
- **A consistent marker in a terminal's own environment stays valid after its agent exits (decided 2026-10-25, no code
  change).** An `rd` terminal gets marker and `CLAUDE_CONFIG_DIR` from the spawn's `env`, so they are the terminal's
  environment, not a subshell's. A second `claude` typed there after the first exited skips the pick and runs on the
  terminal's account. That is intended: the terminal is one seat on one account (and one `USAGE_LANE`), the second session is the
  same work in the same place, and it shares the account's prompt-cache organisation, which a re-pick could only
  forfeit; the guard above exists for markers that *disagree* with the dir, and this one agrees. Costs, accepted: that
  second spawn writes no `picks.jsonl` line, and if the account was exhausted meanwhile Claude Code shows the limit
  itself (the statusline feed marks it). To re-route from such a terminal, type `c` (always picks, then sets the marker for
  its own `claude`) or `c --account <id>`. A bare `claude` in a *plain* terminal is the other case: its marker lives in a
  subshell, so each typed `claude` picks.
- result: exactly one `picks.jsonl` line per spawn (`scripts/claude-launcher.test.sh` counts them for `rd`,
  `c` and bare `claude`). Never export it from a profile (it would be ignored whenever it disagrees with the dir, but a matching one still skips the pick).

One `claude` function serves both machines (`config/zsh/claude-auth.zsh`): the pick runs everywhere, then
`_claude_auth_run` applies the mini's token fallback (defined as a plain `command claude` off the dev host).
`~/.zshenv` sources only that file for non-interactive mini shells, so `ssh mini 'claude …'` keeps the fallback and
never picks.

**Trust.** A fresh config dir asks "trust this folder?" on the first start in a path and an `rd` spawn then
sits at the dialog (status `null` on a Claude terminal). `make claude-accounts-setup` runs two steps (re-run both after the first `/login` of an account, since
an account without a `.claude.json` is skipped): `scripts/claude-pretrust.sh "$HOME"` (atomic jq write of
`.projects[$HOME].hasTrustDialogAccepted` in every registered account that has a `.claude.json`) and
`scripts/claude-trust-sync.sh`, which copies `hasTrustDialogAccepted=true` from the default `~/.claude.json` into each
extra account for exactly the project paths the default already trusts. It never loosens: it sets true only where the
default says true (false or unknown paths are left alone; entries that are not JSON objects are ignored on both sides), touches no other key, writes one atomic replace per account
(original mode kept) and nothing at all when the account is already in sync. An account dir it cannot write in prints a diagnostic and makes the run exit 1. A folder the default has never opened still prompts once per account.

Known gaps:

- **Core restart or reboot:** `hc-resume` types `env CLAUDE_CONFIG_DIR=… claude --resume <id>` (`env -u …` for `iu`) from the
  terminal's `jk.claude.config` label, so a `me` session resumes on `me`. Model, effort and the `c` launcher's env are not restored.
- **`claude --bg` / `claude agents`:** the background supervisor is a long-lived
  daemon bound to one identity. caam defaults `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`
  for non-default profiles for this reason. Keep `--bg` on `iu`
  only; `hc-reap` queries `claude agents` once per account.

## Effort per model

Claude Code has one global `effortLevel` and no per-model default, so every launch we control adds `--effort` from
`config/claude-effort.json` (decided 2026-10-27): **Sonnet high, Opus medium, Fable medium**, no `--model` = `default`
(the account's default model, Opus or Fable) = medium. It applies on every account because it rides the launch, not
the config dir: `c`/`ch`/`cs`/`cf` and a bare interactive `claude` (`_claude_effort_args` in `claude-auth.zsh`), and
`rd work` (`rd_effort_flag` in `remote-dev.sh`). An explicit `--effort` always
wins; an unlisted family (Haiku) gets no flag. `settings.json` `effortLevel` stays `high` in all three accounts on
purpose: it is what a spawn without the flag runs at, and those are the headless runs (the e2e). Custom
subagents pin their own (`agents/*.md` `effort: high`). A mid-session `/model` switch keeps the session's effort.

## Operate

**Verify (read-only, no tokens).** `make claude-accounts-verify` prints one `PASS|WARN|FAIL` line per check and
exits 1 on any FAIL; `make doctor` runs it on the mini. Over plain ssh the login keychain is invisible (every account "NOT logged in"), so doctor outside a core terminal (no `HC_TERMINAL_ID`) runs it through the running herdr-core (`hc exec`), never starting one.

| Check | What it proves | FAIL means |
|-|-|-|
| `auth/<id>` | `claude auth status` is loggedIn with the expected `configDirectory`; keychain service `Claude Code-credentials` (iu) / `…-<sha256(abs dir)[:8]>` exists (`security find-generic-password -s`, never `-w`) | "Claude Code changed credential naming" or config-dir resolution; a logged-out `me` is a WARN, `iu` a FAIL. Fix: `claude-relogin <id>` |
| `login/<id>` | `claude-account expiry`: the Keychain item's `claudeAiOauth.refreshTokenExpiresAt` (epoch ms; the refresh token ends 30 days after the login and rotation does not extend it). Only the two timestamps are read, never a token | PASS > 7 d left, WARN <= 7 d, FAIL <= 2 d or already past for the default account (`iu`); any other account is capped at WARN, like `auth/<id>`. An unreadable item (locked Keychain, foreign format) is a WARN, never a FAIL. Fix: `claude-relogin <id>` (§Re-login) |
| `plan/<id>` | `claude-account expiry` `plan_detected` (parsed from the Keychain item's `rateLimitTier`) equals the registry's `plan`. The picker's default units hang on that plan | WARN only: a mismatch (fix: set `"plan"` in `config/claude-accounts.json`) or an undetectable tier |
| `quota/<id>`, `statusline/<id>` | the `cachedUsageUtilization` the binary keeps in `.claude.json` still has `five_hour`/`seven_day` `utilization` + `resets_at` (its age is informational: only sessions refresh it now); the statusline fed the cache in the last 24 h if sessions ran | field renamed by an update (quota); WARN for a silent statusline |
| `launcher/*` | static: `c cs cf` reach `claude-account pick --lane interactive` and set the marker; bare `claude` picks unless the marker is set; `rd` exports the marker; `claude_iu` and the other retired IU launchers (`ca cap cdf cdp`) must stay gone; `rd work` calls `pick_account` | someone rewired a launcher past the picker |
| `pick/<lane>` | `claude-account pick --dry` (no pick-log line, no refresh) for interactive, bulk, headless: account + reason | the picker errors or stops explaining itself |
| `attribution/*` | last 24 h: every Claude `session_env` line carries a registered account; no `billing='max'` usage row without an account; `account='me'` rows exist once `me` sessions ran (WARN for the first 2 h: ingest lag). Reads `usage.records` in usage-tracker's Postgres (`USAGE_TRACKER_PG`, default `host=/tmp dbname=shared`), not the retired SQLite archive; an unreachable cluster is a WARN, a failed query a FAIL | the hook or the usage-tracker join lost the account |
| `version` | compares `claude --version` with the stamp in `~/.local/state/claude-accounts/verified-version` | (never FAIL; WARN when unstamped) |

Verify never writes. `make claude-accounts-stamp` runs it and, only with no FAIL, records the running version in the stamp. The heartbeat (`check_claude_version`) WARNs `unverified Claude Code version` whenever the running version differs from the
recorded one, until the stamp is renewed. Subagents run inside the parent process and inherit its account (and its
`CLAUDE_CONFIG_DIR`) automatically; nothing picks for them.

**E2E (manual, a few Haiku tokens).** `make claude-accounts-e2e` (`ARGS=--subagent` adds one Haiku run that spawns a
subagent). Per enabled account it builds the launcher env, runs `claude -p "reply ok" --model haiku`, ingests with
usage-tracker, and asserts the session's `usage_record` rows say `billing=max` + the expected account and `session_env`
has the account (with `--subagent`: every row of the subagent session carries the parent's account). Break tests need
no tokens and run against a throw-away copy of the cache, pick log and registry (the default account and one other, no mode, no peer; the real files
are never written):

| Break | Expected |
|-|-|
| exhausted mark on `me` | `bulk` picks `iu` (reason `spill`; `rd` then pauses only if iu has no room either); removing the mark restores `me` (`home`) |
| `CLAUDE_CONFIG_DIR` at an unregistered dir | `claude-account account` -> `?`, the session-env hook logs `account: null` |
| registry unreadable | `pick` exits 4 and answers `unset CLAUDE_CONFIG_DIR` |
| `me` dir without credentials | `claude auth status` loggedIn=false; `refresh` marks it auth-failed; `bulk` never picks it |

**Quota + login keepalive.** `com.jkrumm.claude-accounts-keepalive` (**hourly, on both machines**, under jobrun with
`--every 3600`, `RunAtLoad`) runs `claude-account refresh --all`. Hourly sits far under the picker's 6 h eligibility window and
survives a missed run or two. `make claude-accounts-keepalive-setup` (part of `make setup`) installs it; it needs
`~/.local/bin/jobrun` and `claude-account` (both from `make setup`) and fails loudly without them. Each machine keeps its own
cache, so each refreshes its own (the peer import tops up an idle account): the MacBook's picks route on the MacBook's
samples. `jobs-grade`'s window for `every 3600` is 3 h (a sleeping laptop fires one run on wake, not a backlog);
`make doctor` maps the label in `docs/architecture.md` (mini table and MacBook list). Log:
`~/Library/Logs/claude-accounts-keepalive.log` (a green run prints nothing). What a refresh calls, when it exits 1 and when
it asks for a re-login: the package docs.

**Health on wake.** `claude-account health [--json] [--wake]` grades this machine and its peer; the rows, the transport and
the exit codes are the package's. What dotfiles supplies: the registry's `host` block (§Registry), `scripts/claude-account-snapshot.sh`
behind the gate verbs `account-snapshot` / `account-snapshot-core`, and `scripts/wakeup.sh` (sleepwatcher, MacBook), which runs
`health --wake` 30 s after wake. Readers: Tinycast's Claude usage view (offers each row's `fix`) and the Herdr app's
`jk-status`, which polls every 5 min for its ⚠ chip. A Re-login started from the chip in `jk-details` sets
`shared("jk.relogin")`; `jk-status` then re-polls from 60 s after the start, once a minute, until that row is gone or 15 min
have passed (the chip's "approve in browser" label follows the same key, on either machine), so the chip clears when the
login lands.

**After a Claude Code update.** The heartbeat shows `unverified Claude Code version`. Run `make claude-accounts-verify` (or `make claude-accounts-stamp`, which verifies and then stamps):

1. No FAIL -> `make claude-accounts-stamp` records the version, the WARN clears on the next heartbeat.
2. `auth/*` FAIL -> the credential naming or config-dir resolution changed. Re-derive the keychain suffix from the new
   binary, fix `scripts/claude-accounts-verify.sh` and the table above, and check `claude-auth.zsh` still agrees.
3. `quota/*` FAIL -> the `cachedUsageUtilization` shape changed: that parser, like the usage-endpoint one and the Keychain
   service name, lives in the accounts package (software-factory `packages/accounts`); fix it there. Until then the picker
   routes on the statusline and OAuth feeds. A refresh that logs `usage endpoint gave no sample` / `no Keychain token` is the
   same repo's job.
4. Optional: `make claude-accounts-e2e` for the real attribution round trip.

**Re-login** (dead login, revoked session, or `login/<id>` WARN): `claude-relogin <id>`. Logins are per machine (the
mini and the MacBook keep separate Keychain items), so it runs on the machine that owns the credential; `--machine
mini|macbook` reaches the other one over ssh.

```
claude-relogin me              # log in on this machine behind the scenes, approve in the browser, get a notification
claude-relogin me --ask        # push an approval dialog to the MacBook; its one click starts the same thing
claude-relogin me --visible    # debugging: a Terminal window / core terminal that stays open, no notification
claude-relogin me --dry-run    # print exactly what would run, run nothing
```

1. **Where it runs.** The login Keychain is only reachable from the GUI session (never `ssh mini 'claude …'`).
   - *MacBook:* no window. A detached worker runs `CLAUDE_CONFIG_DIR=<dir> BROWSER=scripts/claude-login-browser.sh claude
     auth login --claudeai` (`CLAUDE_CONFIG_DIR` stays unset for `iu`; token env vars are stripped). Its output, with
     anything token-shaped redacted, goes to `~/Library/Logs/claude-relogin.log`. If that cannot complete (the CLI fails,
     the Keychain is locked, or there was no output for 10 minutes because the callback never arrived), it opens a
     Terminal window with the interactive login, and closes exactly that window (by id) after success. The windowless
     worker only starts in the Aqua GUI session (`launchctl managername`; `ssh iumac` lands in it, measured); from any
     other session it goes straight to that Terminal path via osascript (`launchctl asuser` would need root). The log is
     owner-only (mode 600), redacted (`sk-ant-…`, `Bearer`, and the value of any `code`/`state`/`*token`/`*secret`
     key), and rotated by `log-rotate.sh`.
   - *mini:* a terminal in the mini's herdr-core runs the same command interactively: `hc run --bg --no-parent --rm
     --name relogin-<id>` with labels `herdr.space=<the dotfiles space>` (rd's rule: the `herdr-app` doc entry for the
     folder, else the stable id from the full root; an unreadable doc refuses rather than guesses) and `herdr.tab=tb-relogin-<id>`,
     so the app shows it as the tab `relogin <id>` (named best-effort through the doc once the app has adopted it).
     The core is a launchd GUI-session child, which is why the Keychain works (`ssh mini` is not enough). After success
     the command exits and the terminal removes itself (`--rm`); the watcher sweeps it a few seconds later with `hc rm`
     (never a live one). A failed login drops into `exec $SHELL -l` in that terminal, left open for the manual fallback;
     `--visible` always keeps the shell. **A second relogin while the terminal waits does not refuse:** the helper keeps the
     approval URL in `~/.cache/claude-accounts/<id>.relogin-url` (mode 600; created empty when the login starts, removed
     on any exit of the login process), so the repeated call opens the same page again in the account's browser, notifies the
     MacBook (approve; in the code fallback also where the code goes) and exits 0 with the same words. A terminal with no URL file
     (its login is over: a failed one left at its shell) is closed (`hc kill`, `hc rm`) and replaced by a fresh login; if it will not
     close the call refuses and names `hc kill relogin-<id>`. A finished terminal is removed first. `launchctl print` checks the core runs before
     any `hc` call (an `hc` call starts a stray core otherwise); with no core it stops and says so. From the MacBook the hop is still one ssh to the
     mini, where this script then talks to the local core.
   - *Waiting for the terminal:* the opener polls for a result file (`mktemp`, owner-checked, never a symlink) and for
     the terminal's existence (`hc get`: not found or `finished` = gone). A probe that could not ask (osascript or hc failing, timing out, answering garbage)
     never counts as "closed": the terminal is gone only after 3 clean "absent" answers in a row, and that is
     reported by notification, never silently. After 60 minutes without a result it notifies "did not finish" and
     leaves the window/terminal open.
2. The CLI calls the helper with the authorize URL (redirect_uri `http://localhost:<port>/callback`, random port, bound on
   127.0.0.1 only and kept open next to the CLI's paste prompt: checked 2026-11-22). The helper opens it in the browser signed
   in to that account, registry field `loginBrowser` (`iu` Google Chrome, `me` Helium; no field = the system default, and it
   says so). On the MacBook that is `open -a <app> <url>`: the callback lands on that machine's CLI, nothing to paste.
   **On the mini the MacBook forwards the callback port.** The helper calls the gate verb `login-forward` (`ssh iumac
   login-forward`, stdin: app, port, the ORIGINAL URL). The MacBook refuses unless the URL is https, the port is 1024-65535
   and the one in the URL's loopback `redirect_uri`, and nothing listens on it there; then it runs `ssh -N -L
   127.0.0.1:<port>:127.0.0.1:<port> mini` (no ControlMaster: the forward must die with the verb), opens the page in the
   account's browser and answers `forwarded`. The forward lives while the verb's stdin is open, which the mini keeps open for
   as long as the login's marker file (`~/.cache/claude-accounts/<id>.relogin-url`) exists, and at most an hour (the helper
   timeout `IUMAC_GATE_FORWARD_MAX`). The browser's callback to `localhost:<port>` reaches the mini's listener: no code
   exists, and the login ends on the approve click. The MacBook's notification says `Approve in Helium: the approval page is
   open and the login finishes by itself.` A registry that cannot be read never falls back to a guessed browser: the helper
   prints the URL instead.
3. **You approve in that browser.** That is all (after the e-mail login, when the browser's claude.ai session has ended).
   Nothing drives the browser or reads mail: automating the login itself is out of bounds (Anthropic's terms), a human
   always approves. If you lost the page, run `claude-relogin <id>` again (or click the chip again): it opens the page
   again and repeats the notification.
   **Fallback: the forward cannot be opened** (MacBook unreachable, the port taken there, the open refused). The helper then
   swaps the URL's redirect_uri for the platform's code page (`https://platform.claude.com/oauth/code/callback`, the manual
   URL the CLI itself prints; state and PKCE challenge stay, so the code completes this very login) and opens that with
   `ssh iumac open-url`. The page shows a code, and a native dialog with a text field opens on the MacBook right after
   (gate verb `login-code`: title `Claude login <id>: paste the code from the page`, 15 min). What is pasted goes to the
   login's prompt with `hc send --force relogin-<id> <code>`; it travels as stdin and argv only, is never logged or written to
   a file, and a text that is no code (8-600 characters of `A-Za-z0-9._~#%/+=:-`) is dropped. A cancelled, empty or timed-out
   dialog sends nothing and says so; `claude-relogin <id>` again reopens it. Pasting at the prompt in the tab `relogin <id>`
   of the Herdr app works as well. The page and its URL file are the same for a repeated trigger, which opens the page (and
   the dialog, in this mode) again.
4. It then runs `claude-account refresh --ids <id>` and sends a native notification to the MacBook (locally there, over
   ssh from the mini): `Claude login me: renewed, valid until <date>`, or `Claude login me failed - retry with:
   claude-relogin me (log: <path>)`. The text is built from the id, a date and the log path only, never from CLI output.
   "Renewed" is proven: the Keychain item's `refresh_expires_at` is read before the login and again after it
   (`claude-account expiry --json --ids <id>`) and must be newer afterwards (or there was none before). A login that
   exits 0 without moving it is a failure with the text `login finished but the Keychain login did not change (still valid until
   <date>)`, on the usual failure path: notification, and on the mini the terminal stays open (seen 2026-10-27: a
   "renewed" report while the reader still saw the old item).

A registered but **disabled** account is accepted: its first login is how a new account comes out of the dark, and
`expiry --ids <id>` reads it before `enabled` is flipped (§Adding an account).

If ssh to the MacBook fails, the helper prints the code-paste URL and the CLI prompt is still there: open the URL
yourself and paste the code at the prompt in the tab `relogin <id>`. **Manual fallback** (no script at all): on the machine that owns the login, in a core terminal or Terminal,
`CLAUDE_CONFIG_DIR=$HOME/.claude-me command claude` (`iu`: unset it), `/login`, press `c` to copy the URL, open it in the
right profile, approve, paste the code, then `claude-account refresh --ids <id>` and `make claude-accounts-verify`.

**The ask (keepalive path).** The hourly `claude-account refresh --all` asks for a re-login by itself: when a refresh ends
`auth-failed` for an account on this machine, or `login/<id>` has a known end of life within 7 days (an unreadable item never
asks), it runs `claude-relogin <id> --ask --reason …` detached. That waits until the MacBook is in use (the gate's `in-use`
verb says `active`: screen unlocked and input within 5 minutes; `idle` or `locked` is waited out, polling every 2 minutes for
at most 24 h, and a MacBook that cannot be asked is not waited for), then asks through `scripts/ask-human.sh`: from the mini
over `ssh iumac`, on the MacBook directly (`HUMAN_QUEUE_MAC_HOST=local`). The command is `bash
"$HOME/SourceRoot/dotfiles/scripts/claude-relogin.sh" <id> --machine <m>`, byte for byte a template of the auto-run class
`claude-relogin` (`config/macbook-auto-classes.tsv`, `needs active`, slot `<ID>`): once the owner granted that class on the
MacBook (`human-queue.sh consent grant claude-relogin`, remote-dev.md §Auto-run) the login starts with no dialog, the
approval page is already open and one notification says what opened and why; without the grant the native dialog asks and one
click on Run starts it. The MacBook's own keepalive does the same through the grant file, no ssh. At most one ask per account
per 24 h and one dialog per machine per hour. Both slots are claimed atomically (exclusive create of
`~/.cache/claude-accounts/<id>.relogin-ask.json` and `relogin-ask.cap`, so two keepalive runs never ask twice) and given back
when the ask process fails to start (logged `ask failed`, retried next run), so a 24 h mute only follows an ask that really
started. One account's failure never stops the others; a second account due in the same hour is deferred to the next run. An
unanswered dialog falls back to the human queue and its ntfy notification, as every `ask-human` request does.

**Adding an account**

1. Registry entry in `config/claude-accounts.json` with `"enabled": false` (`dir`, `plan`, `homeLanes`, `loginBrowser`; `units` only to override the plan default).
2. `make claude-accounts-setup` on both machines (the config dir with its links and rendered `settings.json`).
3. `claude-relogin <id>` on the mini and `claude-relogin <id> --machine macbook` (logins are per machine; a disabled account is allowed).
4. `claude-account expiry --ids <id>` on each machine: `plan_detected` must show the plan you registered.
5. Set `"enabled": true`.
6. `make setup` (per-account MCP registration), then `make claude-accounts-verify`.

**Platform (API credit) block**

Each account may carry a `platform` block: the API credit its subscription grants, read by the agent-workflows inference gateway (`agent-workflows/docs/gateway.md` §Picking a pool). The picker, launchers and statusline ignore it.

The credit: one per subscription (Ultra $200 `iu`, Max $100 `me`, `me2`), granted to one linked Console organization, expiring at the end of that subscription's billing cycle (no rollover). It pays API keys of the linked org only (Messages, Batches, Agent SDK), never interactive Claude Code, which stays on the subscription and outside the gateway. No API returns the balance, so the gateway meters itself and reconciles against the Admin API. All three Console orgs carry no payment method and a monthly spend limit equal to the credit, so a drained pool refuses and never bills.

The gateway (`127.0.0.1:7794`, `com.jkrumm.agent-workflows-gateway`) holds one API key per enabled pool plus the personal IU key. A Claude request from agw, its OpenCode server, Hermes, `oc` or modelpick goes to the soonest-expiring eligible pool, else to IU; a Claude-Code-shaped request never goes to a pool. Each request is one `usage.records` row `source='gateway'` (`billing='api_credit'`, `account` = the pool, on credit) plus a `usage.gateway_picks` row. usage-tracker's credit pass fills `usage.platform_cost` from the Admin API and closes `usage.credit_cycles` per cycle (metered, reconciled, unspent); Argo's usage page shows the payers `iu-credit`, `me-credit`, `me2-credit` and a Credits tab.

| Pool | Credit | `cycleDay` | State |
|-|-|-|-|
| `iu` | Ultra $200 | 21 | enabled |
| `me` | Max $100 | 27 | enabled |
| `me2` | Max $100 | 30 | enabled |

| Field | Meaning |
|-|-|
| `creditUsd` | monthly credit of the plan (200 / 100) |
| `cycleDay` | the credit's **expiry** day (1–31) from Console → Billing, not the subscription's payment day. The cycle runs from the expiry day of the previous month to the expiry day, and the meter resets there. `null` = unknown: the gateway meters a rolling 31-day window (the sum of the pool's own rows over the last 31 days), which can never under-count the real cycle; the pool stays usable |
| `headroomUsd` | a pool counts as full at `meter + headroom ≥ credit`: a buffer against a mid-session "credit balance is too low" refusal, not a guarantee (concurrent requests can overrun it). The hard stop is the org's own refusal, because no payment method is on file |
| `enabled` | pool switch, independent of the account's own `enabled` |
| `apiKeyRef` | `op://` ref of the org's API key; the gateway resolves it through `secrets-run` |
| `adminKeyRef` | `op://` ref of the org's Admin key, for reconciling the meter against the cost API |

**Enable rule.** A pool is used only when `platform.enabled` is true and its `apiKeyRef` resolves through `secrets-run` (so the ref must also be in the mini's `headless.refs`, sealed by `make secrets-seed`). A ref that does not resolve disables that pool and logs why; the gateway still starts. Refs live in `op://mini/claude-platform/` (`API_KEY_<ID>`, `ADMIN_KEY_<ID>`). `iu` and `me` are enabled with real keys. `me2` is enabled since 2026-11-04 (keys seeded, `cycleDay` 30). The gateway reads this file only at start, so every edit to it needs `launchctl kickstart -k gui/$(id -u)/com.jkrumm.agent-workflows-gateway` (a gateway deploy does not restart it when its build is unchanged).

**Enable `me2` (owner steps):**

1. Replace the placeholder `API_KEY_ME2` / `ADMIN_KEY_ME2` in `op://mini/claude-platform/` with the real keys of the linked Console org (no payment method on file: a drained org then refuses instead of billing), then `make secrets-seed`.
2. Fill `cycleDay` with the credit's expiry day from Console → Billing (the credit's expiry, not the payment day; `null` meters a rolling 31 days).
3. Set `platform.enabled` to `true`, then restart the gateway: `launchctl kickstart -k gui/$(id -u)/com.jkrumm.agent-workflows-gateway`. `curl -s 127.0.0.1:7794/health` lists `me2` under `pools` with `eligible: true`.

**Troubleshooting**

| Symptom | Likely cause | Fix |
|-|-|-|
| `auth/me` WARN, heartbeat `account me NOT logged in` | login revoked or aged out | `claude-relogin me` (§Re-login) |
| `login/<id>` WARN or FAIL, heartbeat `<id> login valid until … (N d left)` | the 30-day refresh token is near its end | `claude-relogin <id>` on that machine; the keepalive has already asked once per 24 h |
| `login/<id>` WARN `login expiry unreadable` | Keychain locked (headless session), or the item has no `refreshTokenExpiresAt` | unlock the GUI session and rerun; `claude-account expiry` shows the reason |
| `claude-relogin` prints the URL and a paste hint | `iumac` sshd is down or its `open-url` refused, or `open` failed on the MacBook | open the URL in the account's browser yourself and paste the code at the CLI prompt in the tab `relogin <id>` |
| the terminal says `could not forward the callback port … (port-busy)` | something already listens on that port on the MacBook, or its ssh to the mini failed (`forward`, `ssh`) | nothing to fix: the code dialog on the MacBook is the flow then; the reason word names the cause |
| the mini login waits after the approve click, no dialog | the page showed a code (fallback) and the dialog was cancelled or timed out | `claude-relogin <id>` again reopens the page and the dialog |
| a warn login did not start by itself | the MacBook was idle or locked (the ask waits for it), the class `claude-relogin` is not granted (a dialog asks instead), or `auto-run.off` exists | `human-queue.sh consent list` on the MacBook; `ssh iumac in-use` says what the gate sees |
| no notification after a re-login, no window either | the windowless MacBook login is still waiting for your approval, or failed | `~/Library/Logs/claude-relogin.log` says which; a stuck one falls back to a Terminal window after 10 minutes without output, or run `claude-relogin <id> --visible` |
| the re-login dialog never appears | MacBook asleep or unreachable | the request stays in the human queue (`make human-queue` on the MacBook) and ntfy; or run `claude-relogin <id>` there |
| `plan/<id>` WARN "Keychain tier … says ultra, registry says 'max'" | the account was upgraded or the registry plan is wrong | set `"plan"` in `config/claude-accounts.json` (the default units follow it) |
| `plan/<id>` WARN "not detectable" | Keychain item unreadable (locked) or without `rateLimitTier` | unlock the GUI session and rerun; `claude-account expiry --json` shows `tier` |
| a stale expiry or 401 right after a fresh login, `security find-generic-password -s 'Claude Code-credentials…'` without `-a` shows `"acct"<blob>="unknown"` | a Keychain twin: a process that ran without `USER` filed a second item under acct `unknown` next to the real one (acct = `$USER`) | lookups here pass `-a $USER`; delete the twin: `security delete-generic-password -s 'Claude Code-credentials' -a unknown` (add the `-<hash>` suffix for a non-default account) |
| notification `login finished but the Keychain login did not change` | the CLI exited 0 but the item the reader sees was not rewritten (Keychain twin above, a locked Keychain, a login in the wrong browser profile) | check the twin row above, then `claude-relogin <id> --visible` |
| log `refresh: peer usage unavailable` / `unreadable` | the other machine is asleep or unreachable over ssh, or answered garbage | nothing: the run continues on its own endpoint; `ssh mini claude-account usage --json` (MacBook) / `ssh iumac account-usage` (mini) shows why |
| `attribution/me-rows` FAIL | usage-tracker has not ingested, or the join lost the account | `cd ~/SourceRoot/usage-tracker && bun run src/cli.ts ingest`, rerun |
| `pick/*` all `iu`, reason `interactive-fallback` or `spill` | `me` has no fresh sample or is auth-failed | `claude-account usage`, `claude-account refresh --ids me` |
| a `me` session shows `IU` quota | session started with `CLAUDE_CONFIG_DIR` unset (resumed without the `jk.claude.config` label) | restart the session through `c --account me` |
| `quota/<id>` WARN "no usable quota sample" | neither `.claude.json` (only live sessions write `cachedUsageUtilization` now) nor the picker's `~/.cache/claude-accounts/<id>.sample.json` holds the plan's windows | `claude-account refresh --ids <id>`; an account whose sample is complete passes without the field |
| `usage` shows `auth FAILED` right after a fresh `/login` | the mark only clears on a verdict, a sample or a statusline record | `claude-account refresh --ids <id>` (`auth status` loggedIn=true clears it) |
| keepalive exits 1, log `no fresh sample and no auth verdict` or `logged in but still without a fresh sample` | neither the endpoint (Keychain locked / 429 / network) nor `claude auth status` answered, or only the verdict did and the stored sample is over 6 h old | `~/Library/Logs/claude-accounts-keepalive.log` says which; a locked Keychain on the mini needs the GUI session unlocked, retry `claude-account refresh --all` |
| log `usage endpoint HTTP 401, renewing the access token via claude mcp list` | the idle account's Keychain access token expired (expected after hours idle); the run renews it and retries once | nothing, unless it repeats every hour with `no sample` after it: then the refresh token is dead, check `auth/<id>` and re-login |
| an account's sample is hours old on the MacBook | keepalive agent not installed there (`launchctl list \| grep claude-accounts`) | `make setup` or `make claude-accounts-keepalive-setup` on that machine |
| `usage` shows `src oauth` samples but old ages for an account | its refresh is failing quietly (429, Keychain) | run `claude-account refresh --ids <id>` and read the stderr line |

## Attribution (usage-tracker → Argo)

- `hooks/session-env.ts` adds `account` to its line: what `claude-account account` says for the session's
  `CLAUDE_CONFIG_DIR`, `null` when it cannot say.
- usage-tracker carries it as the `account` column on `session_env` and `usage_record`. `billing` keeps its meaning (`max` =
  sunk, `iu` = metered); account is a separate dimension.
- The claude-code collector needs no extra root: `projects/` and `logs/` are shared.

## Displays

| Surface | Change |
|-|-|
| Claude Code statusline | Native `rate_limits` already comes from the session's own account, so the own numbers are correct for free; the `IU`/`ME` badge stays at the front. After the duration, one final segment (files only, never a spawn in the render): every enabled account as `<id> <5h>/<wk>` in registry order, e.g. `iu 2/90 · me 41/22 ↺90m · ∑76%`. The own account is bold with the live stdin numbers (and its 5h reset countdown while line 1 fits 130 columns); the others come from `/tmp/claude_sl/usage_accounts.json`, grey when the sample is over 1 h old, `✗login` when the login failed, absent without figures. `∑` is the plan-weighted weekly pool (weight = the plan multiple, `max20x` 20 / `max5x` 5, all 1 when one is unknown; the same formula as Tinycast's `usage/summary.ts`), only with more than one account. Numbers use the context thresholds. An account's mode is one mark right after its id (`me2↓ 4/0`): drain ↓, reserve ◆, paused ‖; normal, an override past its end and an unknown kind show none. The mark comes from `mode` in the same file: `fetch_usage.py` adds `mode` and `forecast` per account from `claude-account status --json` when it rewrites the file, so the render still only reads a file and spawns nothing. The routing reason (`CLAUDE_ACCOUNT_REASON`, see Account marker) and a pace hint are not rendered. `usage_accounts.json` is rewritten in the background at most once a minute by `fetch_usage.py --accounts` (20 s cap). Tests: `scripts/statusline.test.sh` |
| Herdr app (`jk-status`, `jk-details`) | per-account `5h/7d %` and the `∑` pool from `claude-account usage --json`, the usage popup, and `⚠` chips from `claude-account health --json`. `claude-account status --json` is read beside the usage (merged by id, only `mode` and `forecast` used): the bar chip carries the mode mark after the id (`me2↓ 4/0`, same marks as the statusline); the popup names the mode in words (`drain until reset`, `reserve for fable`) and, for an account that will not be full at its reset (no `forecast.full_at`, `waste_percent` > 0), one line `ends the week at 0%, 100% unused at reset`. A failed status read shows no marks. Tests: `scripts/herdr-mods-accounts.test.ts` |
| Tinycast (MacBook, `extension/src/usage/quota.ts`) | read both accounts from Argo `GET /agents/overview` (`latest.snapshot.quota`), local `fetch_usage.py` as fallback; show both accounts, each with 5h/7d and reset |
| Heartbeat (`devhost-health-check.sh` `check_quota`) | `quota` shows every enabled account (WARN never pages, as today), each with the mode mark after its id and, when it will not be full at its reset, the same forecast words after its numbers (`me2↓ 5h 4% · 7d 0% — ends the week at 0%, 100% unused at reset`), both from `claude-account status --json`; a failed status read leaves the row as before. No limit or threshold of its own: modes and forecasts are `packages/accounts`' (`docs/accounts.md` in the software-factory repo). Test: `scripts/devhost-heartbeat.test.sh`. In `claude auth`, `iu` dead = FAIL; `me` dead = WARN, because the picker routes around it. The same check grades login expiry from `claude-account expiry` (its `severity`): anything but PASS is a WARN (never pages): inside 7 days, an unreadable item, or a check that could not run (helper missing, failing or answering garbage: `login expiry check could not run (<reason>)`, reason also on stderr). Expiry never raises past the existing `iu` policy: a dead keychain login with a working cached token stays the accepted state (WARN at worst); FAIL only where `check_claude_auth_iu` fails too |
| Hermes digests | inherit from the heartbeat; no change |

## Login logistics

- **Per machine, per account:** the mini and the MacBook keep separate Keychain items, so every machine needs its own
  login for each account it uses (a pick on the MacBook for `me` needs `me` logged in there). Never copy credentials
  between machines or dirs. `claude-relogin <id> --machine mini|macbook` logs in on the machine that owns the credential.
- **Where it runs:** in a GUI-session terminal on that machine (a herdr-core terminal on the mini, Terminal on the MacBook);
  the login Keychain is only reachable from the GUI session; never `ssh mini 'claude …'`. `claude-relogin` opens it.
- **Browser:** the registry's `loginBrowser` names the app signed in to the account (`iu` Chrome, the work session; `me`
  Helium and `me2` Safari, the personal ones). It lives on the MacBook, so a login on the mini has the MacBook forward the login's
  callback port to the mini (`login-forward`) and ends on the approve click; only when that fails the code page opens and a
  dialog on the MacBook takes the code (§Re-login).
- **How often:** the access token (8 h) is renewed by the keepalive (a 401 runs `claude mcp list`), but the refresh token ends 30 days after the login
  (`refreshTokenExpiresAt`, not extended by rotation; what the server does past that date is unproven, one report says 55
  days). Plan a re-login every ~30 days, or sooner after a revoke. `claude-account expiry` and the `login/<id>` rows say
  when, and the keepalive asks once per 24 h from 7 days out.
- **1Password:** an item for `me`'s login email. No token fallback for `me`: a dead
  login is a WARN and a re-login.
- **Tinycast (MacBook)** reads the mini's quota; it needs no login of its own.
- **Hygiene:** real identity, own card, no VPN hopping. Use `me` at normal intensity
  on day one; ban reports cluster right after a purchase or upgrade.
