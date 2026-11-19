# config/zsh — launchers and Claude auth

`config/zsh/claude.zsh`. An already-open shell keeps whatever it loaded at
startup — `source ~/.zshrc` after editing.

| Command | Backend | Model |
|-|-|-|
| `claude` (bare, interactive zsh) | Max subscription, account from `claude-account pick --lane ${USAGE_LANE:-interactive}` unless `CLAUDE_ACCOUNT_PICKED` is set | what the resume hook types into a terminal; `-p`, subcommands and non-interactive shells never pick |
| `c` / `ch` | Max subscription | Opus, effort medium / high |
| `cs` / `cf` | Max subscription (`cf` never picked: on the registry's `fable` account, which every other pick holds back as the last resort — `docs/claude-accounts.md` §Fable mode) | Sonnet high / Fable medium; the four fill the app's + menu |
| `oc` | OpenCode — the local inference gateway on the mini (door token of caller `oc`), IU direct on the MacBook; OpenAI route (`iu/…`, `iu-responses/…`) + Anthropic route (`iu-anthropic/…`) | default per `docs/opencode.md` (`--variant max` / `none`); `-m <provider/model>` (e.g. an `iu-anthropic/…` id) |
| `cx` / `cxa` | Codex on the IU endpoint (Responses API) | models per `docs/codex.md`; `astra '<q>'` = one `pro`-mode call — `docs/codex.md` |

Model-choice rationale for every row: `brain/wiki/engineering/model-routing.md`.

`CLAUDE_ACCOUNT_PICKED=<id>` marks "account already chosen" (set by `c`/`ch`/`cs`/`cf` and `rd`, inherited by children;
iu is `unset CLAUDE_CONFIG_DIR`, so the marker says it was decided; it only counts while it agrees with `CLAUDE_CONFIG_DIR`): one pick-log line per spawn. `CLAUDE_ACCOUNT_REASON` (the picker's reason, display-only) travels with it for the statusline.
`make claude-accounts-setup` pre-trusts `$HOME` in every account's `.claude.json` (`scripts/claude-pretrust.sh`) and copies the default account's trusted folders into the extra ones (`scripts/claude-trust-sync.sh`, never loosens).
Contract and tests: `docs/claude-accounts.md` §Spawn integration, `make claude-launcher-test`.

**Orchestrator principal (mini).** An interactive `claude` session start (so `c`/`ch`/`cs`/`cf` too) with no `FACTORY_TOKEN`,
`FACTORY_SESSION` or `FACTORY_ROLE` gets `FACTORY_TOKEN` = `op://mini/software-factory/FACTORY_ORCHESTRATOR_TOKEN` (via `secrets-run`,
`_claude_run` in `claude-auth.zsh`), so its notes, cancels and wakes are `orchestrator` events, not owner touches. The ref is
listed in dotfiles-private `headless.refs`; absent from the cache the session silently keeps the owner token. The principal
cannot call the factory's nine owner-only routes (verdicts, worth-asking, …): from such a session use the
Console, `factory errand done <id> --confirmed-by "<who confirmed and how>"` to close an Errand its operator confirmed (outcome done only, recorded as the orchestrator), or `FACTORY_TOKEN= factory …` (the CLI then resolves the owner token itself; that call is recorded as the owner).

A `[claude-code:unrecognized_model]` line on stderr for gateway ids is expected
telemetry. `usage-tracker` bills every launcher correctly because the SessionStart
hook logs `ANTHROPIC_BASE_URL`.

**`config/zsh/claude-auth.zsh` holds the one `claude()` function** (account pick on every machine, see above) **and
an ARMED token fallback** (`_claude_auth_run`, mini only, self-gated on the `cache` backend) resolving `op://mini/claude/oauth-token`
into `CLAUDE_CODE_OAUTH_TOKEN` — **never `ANTHROPIC_API_KEY`**, which flips billing
to API credits. It probes the keychain credential first and **uncached** (a cached
verdict once suppressed the fallback for an hour while `claude` ran with no
credential at all), and passes the token by prefix assignment, not `env VAR=…`
(which leaks into `ps auxww`). Only keychain-dead *and* token-dead fails the
heartbeat. **Restore the keychain credential with `/login` in a core terminal on the
mini** (`ssh -t mini hc run claude`) rather than minting a token — that token is a one-year credential with no
refresh and no reliable revocation.


**Keychain-cached by `make setup`:** `CLAUDE_SDK_API_KEY` + `CLAUDE_SDK_BASE_URL`
(from `op://common/anthropic/{API_KEY,BASE_URL}`) — the IU creds behind `cx` and, on the MacBook, `oc` (the mini's `oc` uses the gateway door token instead). `ANTHROPIC_API_KEY` is intentionally
**never exported**: Claude Code falls back to the Max subscription when the key is
absent, and exporting it bills API credits instead.
