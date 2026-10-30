# Claude Code runtimes: verified facts for long-running, parallel sessions

Research date: 2026-10-25. Scope: first-party Claude Code (interactive, `claude -p`, background sessions, teams, workflows, cloud, Remote Control) and the Claude Agent SDK, for a solo developer on a Mac mini under personal Claude Max subscriptions.

## Bottom line

- One harness, several entry points. Interactive sessions, `claude -p`, Agent SDK sessions (the SDK spawns the `claude` CLI), background sessions and cloud sessions share the same JSONL transcript format. `-p` and SDK sessions are hidden from the session picker and from `claude --continue`, but resume by ID.
- Subscription use is documented as allowed for your own use. The support article "Use the Claude Agent SDK with your Claude plan" (update dated Oct 7, 2026) says: "You can still use the Claude Agent SDK, `claude -p`, and third-party apps with your subscription limits." The restrictions in the legal pages target developers who offer claude.ai login or plan credentials to their own users. A personal orchestrator on your own Max account fits the first statement. The docs do not use the words "personal automation", so treat that reading as an interpretation.
- Billing trap: `claude -p` and the Agent SDK always use `ANTHROPIC_API_KEY` when it is set. The authentication page says: "In non-interactive mode (`-p`), the key is always used when present." Check with `claude auth status --text` before a headless run.
- First-party equivalents exist for the herdr-plus-hooks setup: agent view and `claude --bg` (research preview), `/remote-control` for phone access, and cross-session messaging (on by default in v2.1.224 and later on macOS, Linux and WSL 2).
- Idle detection: the only documented "idle, waiting for input" hook is Notification `idle_prompt`, which fires about 60 seconds after a turn if you have not typed and no background agent is running. Stop fires at every turn end; its `background_tasks` and `session_crons` arrays separate "done" from "paused waiting for background work".
- Agent teams are experimental, off by default, and interactive-only (`-p` and SDK sessions do not spawn teammates). In-process teammates are not restored on `--resume`.
- Limits: Pro and Max have a five-hour session limit and a weekly limit, shared by Claude and Claude Code. Interactive, `-p` and SDK runs on subscription login all draw from these. The official pages read do not publish numeric quotas.

## Method and confidence

- Sources were fetched on 2026-10-25 from code.claude.com, support.claude.com and anthropic.com. Quotes come from WebFetch extractions (a summarizing model), not raw page text. Spot-check any quote before reusing it externally.
- Press articles were used only to find dated policy events. They are marked unverified in section 9.
- Anything without a primary source is listed in section 9.

## 1. First-party ways to run agents in parallel

| Option | What it is | Launch | State and transcript | Human attach or steer | Limits and status |
|-|-|-|-|-|-|
| Subagents | Workers inside one session with their own context; they return a result | Automatic delegation, `@`-mention, `claude --agent <name>`, `/agents` | `~/.claude/projects/{project}/{sessionId}/subagents/agent-{agentId}.jsonl` | `/tasks` opens a transcript for 30 s after finish; foreground permission prompts pass through; mid-run message injection is not documented | Nesting 3 layers by default; 20 concurrent by default (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`); no experimental label on the page |
| Agent view and background sessions | Full sessions that run without a terminal, managed on one screen | `claude agents`; `claude --bg "<prompt>"`; `/bg`, `/fork` | Transcript via `claude --resume`; state under `~/.claude/jobs/<id>/state.json` and `~/.claude/daemon/roster.json` (not a stable interface) | Yes: `claude attach <id or name>`, `claude logs`, peek-and-reply, `claude stop`, `claude respawn` | Research preview. Runs on your machine. Idle sessions unattached for about an hour are stopped (`Ctrl+T` pins). Machine restart stops them. Each uses subscription quota independently. `--bg` cannot be combined with `-p` |
| Agent teams | Lead plus teammates with a shared task list and direct messaging | Set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, then ask in natural language | `~/.claude/teams/{team}/config.json` (removed at exit); `~/.claude/tasks/{team}/` (kept); mailboxes at `~/.claude/teams/{team}/inboxes/{agent}.json` | Agent panel: arrows select, Enter opens and messages, Esc interrupts, `x` stops | Experimental, off by default. Interactive only. No resume of in-process teammates. One team per session. No nested teams. Significantly more tokens than a single session |
| Dynamic workflows | A JavaScript script that Claude writes and the runtime runs, orchestrating many subagents | Prompt "use a workflow" or the `ultracode` keyword (interactive); `/deep-research` is bundled; `/workflows` to watch | Script under `~/.claude/projects/<session>/`; saved copies in `.claude/workflows/` or `~/.claude/workflows/` | `/workflows` view: `p` pause, `x` stop, `r` restart; no mid-run user input | Available on all paid plans (Pro: enable in `/config`). 16 concurrent agents by default; 1,000 agents per run. In `-p` and SDK runs the launch needs an allow rule for `Workflow`, auto mode, or a host approval |
| Projects | One ongoing conversation that starts "threads" | claude.ai/code or the desktop app | Cloud-side; details not read | Yes, from claude.ai/code | Public beta on Pro and Max (per the agents overview). Details not verified |
| Cross-session messaging | Claude passes text messages between your own sessions | Automatic when useful, or prompt it; `/list-agents` shows reachable sessions | Same machine: per-session Unix socket, not through Anthropic servers | Previews in the transcript; `crossSessionInbound` set to `accept`, `hold` or `refuse` | On by default at v2.1.224 and later (macOS, Linux, WSL 2); v2.1.234 on native Windows. Cross-machine and cloud messages go through Anthropic servers and need claude.ai sign-in. A `-p` session binds a socket unless run with `--bare` |
| Cloud sessions | Session on an Anthropic-managed VM | `claude --cloud "<task>"`; `claude -p "<msg>" --cloud <session-id>` queues a message | Anthropic-hosted; `claude --teleport` pulls one back (one-way) | Yes, from claude.ai/code and the mobile app | Pro, Max, Team, Enterprise. Needs claude.ai sign-in; an API key is not sufficient. Shares rate limits with all Claude Code usage |

Quotes:

- Agent view: "Agent view, opened with `claude agents`, is one screen for all your background sessions: what's running, what needs your input, and what's done." Status: "Agent view is in research preview." Source: https://code.claude.com/docs/en/agent-view.md
- Subagents: "By default, a subagent can spawn subagents of its own, up to three layers below the main conversation." Source: https://code.claude.com/docs/en/sub-agents.md
- Agent teams: "Agent teams are experimental and disabled by default." and "Spawning teammates also requires an interactive session. In non-interactive mode with the `-p` flag, including Agent SDK sessions, Claude doesn't spawn teammates." Source: https://code.claude.com/docs/en/agent-teams.md
- Overview: "Claude Code has five ways to work on several tasks at once: subagents, agent view, agent teams, dynamic workflows, and projects." Source: https://code.claude.com/docs/en/agents.md

## 2. Headless mode (`claude -p`)

| Flag or behavior | Verified behavior |
|-|-|
| `-p` / `--print` | Runs one prompt and exits. Exit 0 on success, non-zero on failure. A failure inside the run (for example missing auth) prints as the result on stdout |
| SIGTERM | Exits with code 143. The turn in progress is left unfinished and no result is recorded. Send SIGINT (or call `interrupt()` in the SDK) first to end the turn cleanly |
| `--output-format json` | One JSON object with `result`, `session_id`, `total_cost_usd` (client-side estimate) and a per-model cost breakdown; `structured_output` when `--json-schema` is set |
| `--output-format stream-json` | Newline-delimited events; add `--verbose`, and `--include-partial-messages` for token deltas. The last line is a `result` message. `system/init` reports model, tools, MCP servers and plugins. `system/api_retry` reports retries |
| `--input-format stream-json` | Accepts stdin input. The SDK streaming page shows the user-message envelope `{"type":"user","message":{"role":"user","content":...},"parent_tool_use_id":null}`. The CLI envelope is not separately documented (unverified) |
| `--resume <session-id, name or transcript .jsonl path>` | Continues that session; a prompt passed with it is sent as the next turn. Works from any directory (cross-project lookup by ID) |
| `--continue` | Most recent conversation in the current directory. Without `-p` it skips `-p` and SDK sessions; `claude -p --continue` includes them |
| `--session-id <uuid>` | Sets the session ID; must be a valid UUID |
| `--fork-session` | With `--resume` or `--continue`, creates a new session ID that starts with a copy of the history |
| `--no-session-persistence` | Nothing is saved and the session cannot be resumed. Print mode only |
| `--bare` | Skips hooks, skills, plugins, MCP servers, auto memory, CLAUDE.md and subagent discovery. Never reads OAuth credentials or the keychain; needs `ANTHROPIC_API_KEY` or `apiKeyHelper`. The docs say it "will become the default for `-p` in a future release" |
| Without `--bare` | "a `-p` session runs the hooks in a project's `.claude/settings.json` and connects the servers in its `.mcp.json`, even in a folder you've never trusted" |
| Permissions | Since v2.1.302, `-p` runs start in Manual mode when nothing sets a mode; calls needing approval are denied unless a `PermissionRequest` hook or `--permission-prompt-tool` approves. Options: `--permission-mode auto`, `dontAsk`, `acceptEdits`; `--permission-prompts none` (v2.1.259+) |
| `--max-turns`, `--max-budget-usd` | Turn limit; spend cap based on the client-side estimate |
| Background work | A run waits for background commands, subagents, workflows and Monitor watches. Default cap: 10 minutes of idle waiting (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`), after which partial output is dropped |

Resume matrix:

| Direction | Works | How | Source |
|-|-|-|-|
| Headless then interactive | Yes | `claude --resume <session-id>` (or name, or transcript path). Not shown in the picker or in `--continue` | https://code.claude.com/docs/en/sessions.md |
| Interactive then headless | Yes | `claude -p --resume <session-id> "prompt"`, or `claude -p --continue` (most recent, including interactive) | https://code.claude.com/docs/en/headless.md |
| Running background session | Attaches | `claude --resume <id>` opens it through `claude attach`. With `-p`, `--bg` or output-format flags it exits 1 and prints the attach command | https://code.claude.com/docs/en/sessions.md |
| Same session in two terminals without `--fork-session` | Interleaves | Messages from both interleave into one transcript | https://code.claude.com/docs/en/sessions.md |

Quote: "Claude Code leaves sessions created with `claude -p` or the Agent SDK out of the session picker and out of `claude --continue`. You can still resume one by passing its session ID to `claude --resume <session-id>`." Source: https://code.claude.com/docs/en/sessions.md

## 3. Agent SDK: authentication and policy

Packages: TypeScript `@anthropic-ai/claude-agent-sdk`; Python `claude-agent-sdk`. The SDK bundles a native Claude Code binary and spawns the `claude` CLI, so CLI credential precedence applies. Source: https://code.claude.com/docs/en/agent-sdk/quickstart.md

| Credential | Works with the SDK | Evidence |
|-|-|-|
| `ANTHROPIC_API_KEY` | Yes; the documented default | Quickstart: "Set your API key" |
| Subscription login from `/login` (Pro, Max OAuth) | Ranks last in CLI precedence. The SDK docs do not describe it separately; the support article says SDK usage draws from subscription limits | Authentication precedence list |
| `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` | Documented as the path for "CI pipelines and scripts where browser login isn't available." One-year token; model requests only (no Remote Control, no connectors). Not read in `--bare` | https://code.claude.com/docs/en/authentication.md. SDK-specific use not stated (unverified) |
| Bedrock, Vertex AI, Foundry | Yes | Quickstart |

Policy quotes (verbatim as extracted):

1. Agent SDK overview and quickstart: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK. Use the API key authentication methods described in the Quickstart instead." Sources: https://code.claude.com/docs/en/agent-sdk/overview.md and https://code.claude.com/docs/en/agent-sdk/quickstart.md
2. Legal and compliance: "Developers building products or services that interact with Claude's capabilities, including those using the Agent SDK, should use API key authentication through Claude Console or a supported cloud provider. Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users." Source: https://code.claude.com/docs/en/legal-and-compliance.md
3. Legal and compliance: "OAuth authentication is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications." Same source.
4. Legal and compliance: "Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription, including where a platform hosts Claude Code as described under *Can customers offer Claude Code in their products?* above." Same source.
5. Legal and compliance: "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent SDK." Same source.
6. Legal and compliance: "Anthropic reserves the right to take measures to enforce these restrictions and may do so without prior notice." Same source.
7. Support article (update dated Oct 7, 2026): "You can still use the Claude Agent SDK, `claude -p`, and third-party apps with your subscription limits." Source: https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
8. Consumer Terms (shown as effective Oct 8, 2025): automated or non-human access is restricted "Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it." Source: https://www.anthropic.com/legal/consumer-terms

Interpretation (mine, not a quote): the support article's explicit statement is the strongest documented permission for individual use of `claude -p` and the SDK against your own plan. The legal text restricts offering Claude login or plan credentials to others. If the orchestrator ever runs for other people or a team, switch to an API key. The legal page directs questions about permitted methods to sales.

Dated policy events:

| Date | Event | Status in primary sources |
|-|-|-|
| Oct 8, 2025 | Consumer Terms effective date | Shown on https://www.anthropic.com/legal/consumer-terms. The page does not mention the Agent SDK or Claude Code OAuth |
| Undated on page | Legal page wording: OAuth "intended exclusively" for subscription purchasers; developers may not offer claude.ai login | Present on https://code.claude.com/docs/en/legal-and-compliance.md. Insertion date unverified |
| Reported Jan 9, 2026; Feb 2026; Apr 4, 2026 | Max OAuth blocked in third-party clients; wording update; subscription stops covering third-party harnesses (billed as extra usage), starting with OpenClaw | Press only (for example https://gigazine.net/gsc_news/en/20260220-anthropic-third-party-block and https://www.infoworld.com/article/4154435/anthropic-cuts-openclaw-access-from-claude-subscriptions-offers-credits-to-ease-transition.html). Sources conflict on January. Not verified on Anthropic pages |
| June 15, 2026 | "We've paused the previously-announced changes to Claude Agent SDK usage." Current usage: "Claude Agent SDK, `claude -p`, and third-party app usage still draw from your subscription limits." | Support article above. The article does not say what the paused change was |
| Oct 7, 2026 | Monthly API credits for Max and Team. They cover `claude -p` and the SDK only when run with an API key from a linked Console organization. Signed in with your plan, `claude -p` and SDK "still draw from your plan's usage limits and don't use your API credits" | https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans and the support article above |

## 4. Transcripts

| Item | Verified value | Source |
|-|-|-|
| Location | `~/.claude/projects/<project>/<session-id>.jsonl`. `<project>` is the working directory with non-alphanumeric characters replaced by `-`; names over 200 characters are truncated and hashed | https://code.claude.com/docs/en/sessions.md |
| Relocation | `CLAUDE_CONFIG_DIR` moves the whole `~/.claude` tree. `CLAUDE_CODE_PROJECT_DIR_NAME` names the project directory (requires `CLAUDE_CONFIG_DIR`) | sessions page |
| Subagents and tool output | `<session>/subagents/agent-<agentId>.jsonl`; large outputs in `<session>/tool-results/` | https://code.claude.com/docs/en/claude-directory.md |
| Format | JSONL, one object per message, tool use or metadata entry. "The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release." Use `/export`, `-p --output-format json`, hook `transcript_path`, or the SDK's `getSessionMessages()` | sessions page |
| Retention | `cleanupPeriodDays`: "The default is 30 days and the minimum is 1; setting `0` fails with a validation error." Swept at startup. Deletes transcripts, subagent transcripts and tool results older than the period. Not deleted: `history.jsonl`, and auto memory unless empty for the full period. `--bare` sessions skip the sweep | https://code.claude.com/docs/en/claude-directory.md |
| Desktop and Cowork transcripts | `desktopSessionCleanupPeriodDays` gives them their own age limit | claude-directory page |
| List | `claude --resume` or `/resume` picker. Keys: `Ctrl+A` all projects, `Ctrl+W` worktrees, `Ctrl+B` current branch, `/` search, `Space` preview, `Ctrl+R` rename. Active background sessions: `claude agents --json`; with `--all`, finished ones too | sessions and CLI reference pages |
| Search | The picker filters by name, title, summary or first prompt, and accepts a GitHub or GitLab PR URL. Full-text search across transcripts is not a documented feature; grep the JSONL if needed, knowing the format is unstable | sessions page |
| Resume | `claude --resume <name, id or path>`, `claude --continue`, `claude -p --resume <id>` | sessions and headless pages |
| Opt-out | `--no-session-persistence` (print mode); `CLAUDE_CODE_SKIP_PROMPT_HISTORY` (all modes); `persistSession: false` (TypeScript SDK only) | claude-directory page; SDK sessions page |
| Delete | `claude purge <path>` deletes all project state (`--dry-run`, `--yes`, `--all`). `claude rm <id>` removes a background session but keeps its transcript | CLI reference; sessions page |
| Security | Plaintext, not encrypted at rest. Anything a tool reads or prints, including credentials, is written to the JSONL | claude-directory page |

## 5. Hooks

Common input fields (command hooks receive JSON on stdin; HTTP hooks receive it as the POST body): `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `permission_mode` (not every event), `prompt_id`, `scratchpad_dir`, `effort` (object with `level`), and `agent_id` and `agent_type` inside a subagent. Source: https://code.claude.com/docs/en/hooks.md

| Event | Fires when | Event-specific input fields | Exit 2 does | Matcher |
|-|-|-|-|-|
| SessionStart | New, resumed, cleared, compacted or forked session | `source` (`startup`, `resume`, `clear`, `compact`, `fork`), `model`, `agent_type`, `session_title`; on resume or fork also `seconds_since_last_response`, `context_tokens`, `prompt_cache_likely_expired`, `estimated_cache_write_usd` | Cannot block; stderr shown to the user only | `startup`, `resume`, `clear`, `compact`, `fork` |
| UserPromptSubmit | Each submitted prompt | `prompt` | Blocks the prompt; stderr shown to the user, not added to context | none |
| Stop | Main agent finished responding. Not on user interrupt; API errors fire `StopFailure` instead | `stop_hook_active`, `last_assistant_message`, `background_tasks` (array), `session_crons` (array) | Prevents Claude from stopping; stderr becomes Claude's reason to continue. A cap of 8 consecutive continuations applies | none |
| SubagentStop | A subagent finishes | `stop_hook_active`, `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message` | Prevents the subagent from stopping | agent type |
| Notification | Claude sends a notification | `message`, `title`, `notification_type` | Ignored; notifications cannot be blocked | `idle_prompt`, `permission_prompt`, `agent_needs_input`, `agent_completed`, `elicitation_dialog`, `auth_success`, and others |
| SessionEnd | Session ends | `reason`: `clear`, `resume`, `logout`, `prompt_input_exit`, `other` (`bypass_permissions_disabled` was removed in v2.1.234) | No decision control; stderr shown to the user | reason values. Default timeout 1.5 s |

Quotes: Stop: "Runs when the main Claude Code agent has finished responding. Does not run if the stoppage occurred due to a user interrupt." The `background_tasks` and `session_crons` arrays "let hooks distinguish 'session is done' from 'session is paused waiting for background work to wake it back up'." Exit 2 per the table: "Prevents Claude from stopping, continues the conversation."

Idle signal:

- Stop is the end of each turn. By itself it does not mean idle. Empty `background_tasks` and `session_crons` means nothing is in flight or scheduled.
- Notification `idle_prompt` is the documented idle signal: "Claude finished responding about 60 seconds ago and you haven't typed since." Timing: "Expect `idle_prompt` about 60 seconds after Claude finishes responding, and only if you haven't typed since and no background agent, such as a background subagent, is still running. Claude Code doesn't send `idle_prompt` while it waits for a claude.ai usage limit to reset."
- `agent_needs_input` fires when a background session waits for input while agent view is open in a terminal (matcher table).
- `TeammateIdle` applies only to agent-team teammates.
- Whether `idle_prompt` fires in a `-p` run is not documented (unverified). A `-p` run has no typing, and its process exits when the turn ends.

Other verified details: async command hooks (`"async": true`) run in the background; in `-p`, Claude Code kills any still-running async hook at teardown and records it as `cancelled`. On SIGTERM, Claude Code runs SessionEnd hooks, then exits.

## 6. Remote control and cross-device access

| Feature | What it does | Where it runs | Requirements (verified) | Phone or browser can | Status |
|-|-|-|-|-|-|
| Remote Control: `claude remote-control` (server mode), `claude --remote-control` / `--rc`, `/remote-control` / `/rc` | Connects a local session to claude.ai/code or the Claude app | Your machine; "your computer has to stay on and the `claude` process has to keep running" | claude.ai login on Pro, Max, Team or Enterprise; API keys not supported; not on Bedrock, Vertex AI or Foundry; not with `ANTHROPIC_BASE_URL` pointing elsewhere; Team and Enterprise need an admin toggle | Send messages, see the transcript and subagent progress, attach images, `@` file completion from the local project. Reconnects after sleep or network drops | Status label not captured (unverified). Server mode `--capacity` default 32 |
| Cloud sessions: `claude --cloud`, claude.ai/code | Session on an Anthropic-managed VM | Anthropic infrastructure; keeps running after you close the laptop | Pro, Max, Team, Enterprise; claude.ai sign-in; GitHub connection | Yes | Shares rate limits with all Claude Code usage |
| Teleport: `claude --teleport [id]`, `/teleport`, `/tasks` then `t` | Pulls a cloud session and its branch into the terminal | Your terminal (a copy) | Clean git state; branch pushed; same account; same repo | n/a | One-way from the CLI. New work in the terminal does not appear in the cloud session |

Quote: "From the CLI, session handoff is one-way: you can pull cloud sessions into your terminal with `--teleport`, but you can't push an existing terminal session to the cloud." Source: https://code.claude.com/docs/en/claude-code-on-the-web.md

## 7. Usage limits

Verified facts:

- "Both Pro and Max plans have a five-hour session limit and a weekly limit." "Max plans also have a separate weekly limit for Fable." "These limits are shared across Claude and Claude Code, meaning all activity in both tools counts against the same limits." Source: https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan
- Plan tiers named: Pro, Max 5x, Max 20x.
- Usage credits can continue work past the plan limits at standard API rates.
- Monthly API credits (Max and Team): "They don't cover interactive Claude Code sessions or extra usage after you hit your plan's limits." "Doesn't roll over. Unused credits expire at the end of each billing cycle."

| Runtime | Auth | Draws from | Source |
|-|-|-|-|
| Interactive CLI, desktop, web | claude.ai login | Plan five-hour and weekly limits | 11145838 article |
| `claude -p` | claude.ai login (default) | Plan limits: "still draw from your plan's usage limits and don't use your API credits" | 17154008 and 15036540 articles |
| `claude -p` or SDK | API key from a linked Console org | API billing, covered by Max monthly API credits | 17154008 article |
| `claude -p` or SDK | `ANTHROPIC_API_KEY` present in the environment | API billing; the key is always used in `-p` | https://code.claude.com/docs/en/authentication.md |
| Agent SDK | Subscription login or `CLAUDE_CODE_OAUTH_TOKEN` | Plan limits | 15036540 article (Oct 7, 2026 update) |
| Background sessions (agent view) | Your login | "Each session uses your subscription quota independently" | https://code.claude.com/docs/en/agent-view.md |
| Cloud sessions | claude.ai login | Shared with all Claude Code rate limits | https://code.claude.com/docs/en/claude-code-on-the-web.md |
| Dynamic workflows | Any | "Runs count toward your plan's usage and rate limits." | https://code.claude.com/docs/en/workflows.md |
| Agent teams | Any | Each teammate is a separate Claude instance; "significantly more tokens" | https://code.claude.com/docs/en/agent-teams.md |

At the limit: Claude Code shows "Usage limit reached · wrapping up" when it can finish a response in progress; the wrap-up is small and counts toward the weekly limit. `autoContinueAtUsageLimit` controls whether an interactive session waits for the reset. Workflows pause at a limit only in interactive sessions, not in `-p`, SDK or background runs. The docs read do not say what a plain `-p` run does at the limit (unverified).

## 8. What the facts imply for the three options

- Keep interactive herdr sessions for work you steer. They have the widest feature set (Remote Control, `/workflows`, agent teams) and the idle signal.
- Use `claude -p` for scripted one-shot runs. Pin permissions explicitly (`--permission-mode` or allow rules). Use `--no-session-persistence` or `CLAUDE_CODE_SKIP_PROMPT_HISTORY` only if you do not need to resume.
- Use the Agent SDK when you need the harness in code. You host the subprocess, transcripts live on local disk, and sessions need a `SessionStore` to survive a host change.
- Check `ANTHROPIC_API_KEY` before any headless or SDK run: it changes billing.
- Agent teams and agent view are research or experimental. Do not make them the only path for work that must survive.

## 9. Unverified or not found

- Numeric five-hour and weekly quotas for Pro and Max. The official pages read give no counts. Press ratios (5x and 20x of Pro) are unverified.
- The peak-hour change to five-hour drain reported from March 26, 2026 (press only).
- The dates and wording of the January, February and April 2026 policy events. Only the June 15 pause and the October 7 update appear on Anthropic's support pages.
- Whether `idle_prompt` fires during a `-p` run.
- Whether the SDK reads `CLAUDE_CODE_OAUTH_TOKEN` (documented for CLI and scripts in general).
- The CLI envelope for `--input-format stream-json` (the SDK envelope is documented).
- The two ways to extend the 1.5 s SessionEnd timeout (the environment variable name was not captured).
- Where agent-team teammate transcripts are stored (not stated).
- Projects: only the overview description was read.
- Remote Control status label (preview or general availability) and whether it works with background sessions or `-p`.
- Whether cross-session messaging carries a research label (not stated on the page).
- What a plain `claude -p` run does at the usage limit.
- `CLAUDE_CODE_OAUTH_TOKEN` behaviour specific to the Agent SDK.

## 10. Sources

Code.claude.com (Claude Code and Agent SDK docs):

- https://code.claude.com/docs/en/claude_code_docs_map.md
- https://code.claude.com/docs/llms.txt
- https://code.claude.com/docs/en/agents.md
- https://code.claude.com/docs/en/sub-agents.md
- https://code.claude.com/docs/en/agent-view.md
- https://code.claude.com/docs/en/agent-teams.md
- https://code.claude.com/docs/en/workflows.md
- https://code.claude.com/docs/en/cross-session-messaging.md
- https://code.claude.com/docs/en/headless.md
- https://code.claude.com/docs/en/cli-reference.md
- https://code.claude.com/docs/en/sessions.md
- https://code.claude.com/docs/en/claude-directory.md
- https://code.claude.com/docs/en/hooks.md
- https://code.claude.com/docs/en/remote-control.md
- https://code.claude.com/docs/en/claude-code-on-the-web.md
- https://code.claude.com/docs/en/authentication.md
- https://code.claude.com/docs/en/legal-and-compliance.md
- https://code.claude.com/docs/en/costs.md
- https://code.claude.com/docs/en/agent-sdk/overview.md
- https://code.claude.com/docs/en/agent-sdk/quickstart.md
- https://code.claude.com/docs/en/agent-sdk/sessions.md
- https://code.claude.com/docs/en/agent-sdk/hosting.md
- https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode.md

Support and legal (Anthropic):

- https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan
- https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-and-team-plans
- https://www.anthropic.com/legal/consumer-terms

Press (used only to locate dated events; unverified):

- https://gigazine.net/gsc_news/en/20260220-anthropic-third-party-block
- https://www.infoworld.com/article/4154435/anthropic-cuts-openclaw-access-from-claude-subscriptions-offers-credits-to-ease-transition.html
