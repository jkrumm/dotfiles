# Research: 2026-10-21-dark-factory-landscape

research-gateway job `144b8d43-3179-48fd-b2cf-90d1e0e4b6a9` · finished 2026-10-21 11:00 UTC · status `ok` · 77 citations

**Query:** State of the art (as of October 2026) for fully autonomous "dark factory" software development with coding agents for a solo developer: how mature setups minimize human approvals (autonomy policies, escalation taxonomies, agent-as-reviewer/decider patterns, risk-tiered auto-approval), and which control-plane / fleet dashboard UIs exist to observe many parallel Claude Code / OpenCode agent sessions (e.g. blume.codes, Conductor, Vibe Kanban, Crystal, Claude Squad, Sculptor, Omnara, others). For each tool: what it shows, how it models sessions/tasks/attention ("what needs me"), and design ideas worth copying.

---

## Bottom line

- **No published framework gives you a recipe for 0.1% approvals.** Four ladders disagree on what "level 5" even means (Shapiro's level 5 = no human *review*; Feng et al.'s L5 = no human *means* of review), the only binding text is EU AI Act Art. 14, and **no vendor publishes a measured approval rate** — the only published number is Pulumi's *proposed* entry gate of <10% human override over 20 PRs.
- **Risk-tiered auto-approval has converged on one shape:** a risk level attached to each command/tool (low/medium/high), an autonomy ceiling that auto-runs anything at or below it, and **deny-first** rule precedence — Factory `permissionRules` (block > ask > allow), Codex 4 approval policies × 4 sandbox modes, Devin CLI 5 modes with Deny→Ask→Allow, Claude Code deny→ask→allow.
- **Claude Code's native toolkit is richer than most wrappers expose**: six permission modes, five settings files with managed-first precedence and list *merging*, `Tool(specifier)` rules, 33 hook events including a JSON-over-HTTP handler, and `exit 2` as a hard block — enough to build warden's gate without patching anything. Critically, `auto` and `bypassPermissions` **cannot be set from project or local settings**.
- **Agent-as-reviewer alone is not a merge gate.** PRs reviewed only by review agents merged at 45.20% vs 68.37% for human-only, and 60.2% of closed agent-only PRs fell in the 0–30% signal-to-noise band; the defensible architecture is probabilistic review as *one* signal, deterministic verification as the *blocking* gate, and escalation by risk.
- **Blume is the only product whose core loop matches the target**: it observes local session files (does not orchestrate), shows five honest states including `approval`, and collapses a delivery into one approve/reject with evidence attached — but Deliveries is still behind a waitlist.
- **Conductor** is macOS-only, models one workspace = one branch = one worktree, blocks merge on open todos/failed checks, and is the only tool with a dedicated **⌘⌥L "next chat needing attention"** jump; it is a review surface, not a dispatcher, and its local agents run unsandboxed.
- **Vibe Kanban is sunsetting** (Apache-2.0, still maintained thinly) but its data model — status on the *task*, execution on the *workspace/attempt*, per-attempt base commit, soft-delete for rewind — is the cleanest schema in the field to copy.
- **Claude Squad, Sculptor and Omnara differ mainly in isolation**: tmux+worktree per session (cheapest), worktree per *workspace* with agents sharing a checkout (conflicts possible), and no worktree at all with agent state as durable Postgres event logs (heaviest, only crash-proof one).
- **Codex** now has **four** approval policies (`untrusted` retired as user-facing config, `on-request` default, `granular`, `never`) and ships `approvals_reviewer = "auto_review"` — a first-party *agent-as-decider* for exactly the actions that would have prompted you.
- **Jules has two gates and both default open**: plan approval auto-releases on a timer unless `requirePlanApproval=true`, and `automationMode` only has `AUTO_CREATE_PR` — there is no merge gate because there is no merge.
- **Devin** publishes a layered permission model and confidence-tier gating (🟡/🔴 confidence ⇒ wait for approval, 🟢 ⇒ proceed), but **no autonomy-level framework** — nothing on cognition.com presents an L1–L5 ladder.
- **For Argo: push only the blocking tier, park everything else on a dashboard, and escalate on timeout with a cheap reversible default** (Sheridan–Verplank level 6) — because vigilance on a rare-event display collapses within ~30 minutes and the resumption cost is **25 min 26 s** on average, not the widely quoted "23 minutes".

---

## 1. Autonomy frameworks: four ladders that disagree, one law that binds

### 1.1 The ladders are not interchangeable

| Framework | Levels | What the top level means | Basis |
|---|---|---|---|
| Shapiro (Jan 2026) | 0–5, NHTSA-style | 5 = dark factory, no human review of code before prod | driver-automation analogy |
| Feng / McDonald / Zhang (arXiv 2506.12469) | L1–L5 by **user role** | L5 = *observer*, "no means for user involvement" | human-automation interaction |
| Berkeley RDI (Jul 2026) | I–III | III = AI decides *what* to build | SAE analogy |
| ProductBuildersHQ paper | adds L6 | humans no longer write or review, but "production operations still retain human gates" | StrongDM case study |

So "L5" means opposite things depending on the source. Shapiro puts his own practice at level 4, says "almost everyone tops out" at 3, and Pulumi restates that as "Most teams are at level 2 or 3… Level 5 is the experiment" (https://www.danshapiro.com/blog/2026/01/the-five-levels-from-spicy-autocomplete-to-the-software-factory/, https://www.pulumi.com/blog/dark-factory-pattern-pulumi-autonomous-iac/).

The most useful move in the literature is Feng et al.'s **separation of autonomy from capability**: autonomy is "a deliberate design decision, separate from its capability and operational environment" — i.e. tool access (agency) is not authority. They also name the exact failure your 0.1% target courts: L4's open problems are **rubber-stamping and prompt fatigue** ("How can users be engaged in agent activities to avoid meaningless rubber stamping?"), and they propose third-party-issued **autonomy certificates** backed by an "autonomy case" (https://arxiv.org/abs/2506.12469).

Berkeley RDI contributes the other load-bearing concept: beyond level, three cross-cutting dials — **specification granularity, temporal autonomy, and oversight mode** ("co-specification and action-level approval to pull-request review, policy guardrails, monitor-only operation, and automated rollback") — plus the named failure **level-skipping**: teams nominally at Level I merging agent changes "that no one has meaningfully inspected" (https://rdi.berkeley.edu/blog/auto-software-dev/).

### 1.2 What the canonical "dark factory" actually gates on

StrongDM's Software Factory states two absolute rules — "Code must not be written by humans" and "Code must not be reviewed by humans" — plus a spend heuristic: "If you haven't spent at least $1,000 on tokens today per human engineer, your software factory has room for improvement." Its gates are **behavioural, not approval-based**: scenarios stored *outside* the codebase as a holdout set, a probabilistic "satisfaction" score, and a "Digital Twin Universe" of cloned Okta/Jira/Slack/Drive/Sheets (https://factory.strongdm.ai/).

The concrete thresholds everyone quotes — run each scenario three times, two of three must pass, overall pass rate must clear 90%, failure returns a one-line message and never the scenario text — come from **Pulumi's second-hand account**, not from StrongDM's page (https://www.pulumi.com/blog/dark-factory-pattern-pulumi-autonomous-iac/).

### 1.3 The escalation taxonomy: only two concrete classes exist

1. **Pulumi's destructive class, held outside autonomy entirely**: "dropping a database, deleting a hosted zone, rotating a root key, anything that crosses a regulated data boundary" — while tag changes, security-group adjustments and instance resizes "can run autonomously today". It insists on all three layers — approvals, policy and a human kill switch — "because approvals without policy means anything a human approves in a hurry ships" (https://www.pulumi.com/blog/dark-factory-pattern-pulumi-autonomous-iac/).
2. **Factory's risk tiering**: each execute command and MCP tool carries low/medium/high risk, and "Commands with no policy match run automatically when their risk is at or below your Autonomy Level" — Off = Read/LS/pwd/git status; Low = Edit/Create/rg; Medium = `npm install`, `git commit`, `mv`, migrations; High = `docker compose up`, `git push`, custom scripts (https://docs.factory.com/autonomy-and-safety/auto-run.md).

Dark Factory Dev's synthesis is the best stated *rule* for choosing tiers: **"autonomy should follow verifiability and blast radius, not task labels"**, since the same task "is disposable in one environment and high-risk in another" (https://darkfactory.dev/factory).

### 1.4 Numbers: everything published is either a proposal or a negative

- Pulumi's gate to flip auto-merge on: pass rate >90%, false-positive <5%, **human override rate <10% over 20 PRs** — proposed entry criteria, not measured outcomes (https://www.pulumi.com/blog/dark-factory-pattern-pulumi-autonomous-iac/).
- The measured numbers are all bad: 94% of developers missed deliberate data exfiltration and 56% merged it even after a correct alert; in one production runtime a human reading the product caught ~70% of silent failures while the test suite caught ~0% (https://darkfactory.dev/factory, https://darkfactory.dev/factory/verification).

Treat 0.1% as a design aspiration with no published precedent to calibrate against, not a target you can validate against someone else's measurement.

### 1.5 Policy-as-code: what to actually build

The converged feature set, in order of how much of your gate it removes:

- **Deny-first precedence.** Factory: "matching blocks take precedence over requests for approval, which take precedence over allows"; `--skip-permissions-unsafe` still honours blocks; "Allow always" *raises the session's Autonomy Level* rather than allowlisting one command (https://docs.factory.com/autonomy-and-safety/auto-run.md).
- **An org autonomy ceiling** (Factory: Default *and* Maximum Autonomy Level, capping what members can raise; Missions require High or `--skip-permissions-unsafe`).
- **Rule objects, not lists** — Factory has migrated from `commandAllowlist`/`commandDenylist`/`commandBlocklist` (deprecated, not removed) to `permissionRules` with decisions `allow` / `ask` / `block`.
- **An explicit warning that this is not isolation**: "Command rules are not operating-system isolation" (https://docs.factory.com/autonomy-and-safety/auto-run.md).
- **Binding-law floor.** EU AI Act Art. 14 requires oversight "commensurate with the risks, level of autonomy and context of use", an automation-bias warning, a stop button, and a two-person rule for Annex III 1(a) systems; it applies 2 Dec 2027 / 2 Aug 2028 (https://artificialintelligenceact.eu/article/14/). Nothing else in the space is legally binding.

---

## 2. Claude Code: the docs-verified reference

### 2.1 Permission modes (exact names)

`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`. `default` is *labelled* Manual in the CLI/IDE/desktop and `manual` is accepted as an alias, but hooks always receive `"default"`. `dontAsk` "auto-denies every call that would otherwise prompt" (reads in working dirs and `permissions.allow` rules still run; AskUserQuestion, `requiresUserInteraction` MCP tools and org connector tools are denied even if allowed). `auto` runs "a background classifier" over shell/network actions. `bypassPermissions` skips prompts "except for the actions no mode auto-approves" (https://docs.claude.com/en/docs/claude-code/permissions).

Kill switches: `permissions.disableBypassPermissionsMode: "disable"` and `permissions.disableAutoMode: "disable"`. **`permissions.defaultMode` values `auto` and `bypassPermissions` do not take effect from project or local settings** — only user/managed or `--permission-mode`; before v2.1.257 `bypassPermissions` applied from any file (https://docs.claude.com/en/docs/claude-code/settings). For a headless Mac mini warden, that is the single most important config fact: your autonomy level must live in `~/.claude/settings.json` or managed settings, not in the repo.

### 2.2 Settings files and precedence

`~/.claude/settings.json` (user), `.claude/settings.json` (shared project), `.claude/settings.local.json` (project local), `managed-settings.json`/MDM/server-managed — plus the internal `~/.claude.json`. Precedence highest-first: **managed → `--settings <file|json>` → local → shared project → user**. List keys (`permissions.allow`, `deny`, `ask`) **merge** across files rather than override, with carve-outs for `fallbackModel`, `modelPicker` (v2.1.242+), `availableModels`, `modelSettings`. A documented "Exceptions to managed settings precedence" table lets a *stricter* lower-scope value win for keys like `permissions.blockReadsOutsideWorkingDirectories` (v2.1.257+) and `autoMode.classifyAllShell` (https://docs.claude.com/en/docs/claude-code/settings).

### 2.3 Rule syntax and evaluation

`Tool` or `Tool(specifier)`; `Bash(*)` ≡ `Bash`; `:*` ≡ trailing ` *`. Evaluation is **deny → ask → allow, first match wins, specificity irrelevant** — so a broad `Bash(aws *)` deny beats a narrow `Bash(aws s3 ls)` allow. Bare tool-name deny removes the tool from context entirely. `Tool(param:value)` matching (e.g. `Agent(isolation:worktree)`, `Bash(run_in_background:true)`) works for **deny and ask only**. `permissions.additionalDirectories` grants file access but does *not* load `.claude/` config, unlike `--add-dir` (https://docs.claude.com/en/docs/claude-code/permissions).

One gate that bites headless setups: `permissions.allow`, `additionalDirectories` and project `settings.json` rules only apply **after the workspace trust dialog is accepted**; deny/ask apply immediately, and a `claude -p` or SDK session never shows the dialog (it warns on stderr instead).

### 2.4 Hooks are the approval bus

33 documented events, including `PreToolUse`, `PermissionRequest`, `PermissionDenied`, `PostToolBatch`, `SubagentStart`/`Stop`, `Stop`, `StopFailure`, `TaskCreated`/`TaskCompleted`, `ConfigChange`, `WorktreeCreate`/`Remove`, `PreModelSwitch`, `Elicitation`/`ElicitationResult`. Handler types: `command`, **`http`** (JSON POST body, same JSON response format), `mcp_tool`, `prompt`, `agent` (https://docs.claude.com/en/docs/claude-code/hooks). The `http` handler is literally a webhook into warden.

Semantics that matter:
- **exit 0** = success, JSON output applied; **exit 2** = blocking error on events that can block; anything else = non-blocking error, action proceeds. Valid JSON with exit 2 is read but cannot override the block — "Even a `permissionDecision` of "allow" doesn't let the action through."
- exit 2 is honoured on `PreToolUse`, `UserPromptSubmit`, `Stop`/`SubagentStop`, `TaskCreated`, `ConfigChange`, `PreCompact`, `PreModelSwitch` — and **not** on `PermissionRequest`, `PostToolUse`, `Notification`, `SessionStart`.
- A PreToolUse hook can return `"allow"` to skip a prompt, **but never overrides deny or ask rules**; in plan mode `allow` is ignored for non-read-only calls.
- `onFailure: "block" | "continue"` makes a failed hook fail closed (v2.1.295+).
- Common input fields include `session_id`, `prompt_id` (matches the `prompt.id` OTel attribute), `transcript_path`, `permission_mode`, `agent_id`, `scratchpad_dir`.

### 2.5 Sandbox

Permissions and sandboxing are complementary: sandboxing is OS-level enforcement of shell commands' filesystem and network access. With sandboxing on and `sandbox.autoAllowBashIfSandboxed` at its default `true`, sandboxed Bash runs **without prompting even under a bare `Bash` ask rule**, because the boundary substitutes for the whole-tool prompt (skipped in plan mode). Sandbox paths and permission-rule domains are merged into the final config (https://docs.claude.com/en/docs/claude-code/permissions).

### 2.6 Operational notes

`-p` (print) runs use the API key "when present", skip the settings-error dialog, and fail hard on unparseable `~/.claude.json`. `claude --bg` background sessions require workspace trust. On macOS, background sessions request `~/Desktop`, `~/Documents`, `~/Downloads` separately and reads there fail with `Operation not permitted` until granted — the most likely silent breakage on a headless Mac mini (https://docs.claude.com/en/docs/claude-code/settings, https://docs.claude.com/en/docs/claude-code/permissions).

**Not verified in this run:** the OS-level sandboxing page (platforms, mechanisms, remaining sandbox keys), the per-event hook JSON schemas past the exit-code tables, the Agent SDK package names, `--dangerously-skip-permissions` / `stream-json` shapes, and on-disk transcript paths/OTel export keys.

---

## 3. Agent-as-reviewer: what the evidence actually supports

| Evidence | Figure | Source |
|---|---|---|
| CRA-only PRs merged vs human-only | **45.20% (127/281)** vs **68.37% (804/1,176)**, p<0.001 | https://arxiv.org/html/2604.03196v1 |
| Abandonment, CRA-only vs human-only | **34.88% (98/281)** vs **21.60% (254/1,176)** | same |
| Low-signal share of closed CRA-only PRs | **59 of 98 (60.2%)** in the 0–30% band; **12 of 13** CRAs average <60% (Copilot 19.79%, cursor[bot] 43.40%) | same |
| GPT-4 judge vs two humans | **85%** vs **81%** agreement (MT-bench, non-tie) | https://arxiv.org/abs/2306.05685 |
| Judge reliability on close calls | agreement rises ~70%→~100% as model gap widens; position-bias consistency GPT-4 **65.0%** | same |
| Supervisory consensus layer | CodeAgent 92.96% vulnerability confirmation vs GPT-4 51.42%; removing QA-Checker drops to **73.23%** | https://arxiv.org/abs/2402.02172 |
| Two-layer critic + repo verifier | 900+ PRs, 1,000+ reviews, mean time to merge **−58%**, high-risk PRs *not* auto-merged | https://www.openhands.dev/blog/20260506-the-verification-stack |

Three conclusions you can act on:

1. **Judges are weakest exactly where a merge gate needs them** — on close calls. A reviewer that says "looks fine" on the 45% of diffs that are genuinely marginal is not a gate.
2. **The win comes from the supervisory/verification layer, not the reviewer.** CodeAgent's ablation and OpenHands' explicit 🟢/🟡/🔴 verdict with high-risk PRs held for a human architect both point the same way.
3. **Vendors keep approvals and merge authority separate deliberately.** CodeRabbit: "The team still decides which checks and human approvals a change needs before merge", auto-merge "configure[d] separately" per repo policy (https://www.coderabbit.ai/guides/agentic-code-review). Monperrus argues for full replacement but states "We do not present a new empirical study", and concedes correlated blind spots when one model family writes and reviews (https://arxiv.org/pdf/2606.13175).

**Practical shape for warden's gate:** `agent-gateway` review runs (bounded OpenCode v2 jobs) produce a *signal*; deterministic checks (tests, type/contract, policy, sandbox diff) are the *blocking* verdict; a risk tier decides whether the signal alone is enough. Nothing retrieved quantifies defect-escape rate for a reviewer-gated auto-merge.

---

## 4. The fleet dashboards

### 4.1 Comparison

| Tool | What it shows | Session / task / attention model | One idea to steal |
|---|---|---|---|
| **Blume** (blume.codes) | Local session DB, per-session state, delivery view with tests/screenshots/evidence | Reads agents' local session files; **does not orchestrate**; states Running/idle/error/**approval**/todo; one approve/reject per delivery | Evidence badge + atomic apply with pre-write verification and undo |
| **Conductor** | Diff viewer, terminals, Checks tab (CI/deploys/threads/todos), cost & context usage | project → repo → workspace = 1 branch = 1 worktree; backlog/in progress/in review/done; **⌘⌥L next chat needing attention** | A dedicated keyboard target for "what needs me", not just a filter |
| **Vibe Kanban** | Kanban board + workspaces with branch/terminal/dev server + inline diff comments | Task status → Workspace (attempt) → Session (agent) → ExecutionProcess; attention *derived* (is_running / is_errored) | Status on the task, execution on the attempt, per-attempt base commit |
| **Claude Squad** | TUI: session list, preview↔diff toggle, `c` commit-and-pause / `s` commit+push | tmux session + git worktree per session; only paused/running | Cheapest possible isolation on one host |
| **Sculptor** | Files Browse/Changes/Commits, per-file diff, agent tabs, % context, todo "1/8", **CI Babysitter** | worktree per *workspace* (agents share it); native panels replace AskUserQuestion/ExitPlanMode | Interaction-handler substitution so a question "raises a notification more likely to reach you" |
| **Omnara** | Web dashboard, `activity` enum, interaction cards at bottom of conversation | Agents *are* Postgres event logs; machines attach/release | Approval forms as a generic schema + first-writer-wins idempotency |
| **Cursor Agents Window** | Every agent across projects, new diffs view, per-run screenshots/video/logs, read-only share URL | Cloud VM per agent, worktrees, local↔cloud handoff | Per-run artifacts as a handoffable reviewable unit |
| **Codex Cloud / Copilot / Jules / Claude Code cloud / Devin** | Task lists, session logs, plan approval (Jules), confidence gating (Devin) | Task = own workspace in their infra | Jules: notify *only* on "complete" or "needs input" |

### 4.2 Blume (mandatory deep-dive)

A free, local-first **desktop sidecar** that "does not run your agents, does not orchestrate them… It observes the work you are already doing and hands you a decision." It reads supported harnesses' local session files into a local SQLite DB and that DB "is not uploaded as a cloud archive of your chats" (https://blume.codes/blog/you-already-told-your-agent-that, https://blume.codes/docs/local-and-cloud-data).

The current headline is **Deliveries**: "One product change with its brief, task tree, agent runs, code revision, tests and screenshots, intact from the first instruction to production", reduced to one human decision (https://blume.codes/). Deliveries sits behind a **Join waitlist** CTA (needs a hosted ledger); the downloadable desktop app (v1.0.56, Jul 2026) is the shipped surface. Pricing is free — Terms §10: "currently provided free of charge; we may introduce paid features in the future on notice" (https://blume.codes/terms). Two engineers; Product Hunt launch 2026-08-31.

The single most copyable mechanism: proposal cards carry an **evidence badge** ("came up 3 times in your chats") plus Preview/Snooze/Dismiss/Apply, and applying is all-or-nothing, verifies each target file still matches before writing, and records prior contents for Undo (https://blume.codes/blog/how-blume-codebase-improvements-work). Discrepancy to note: third-party directories and Product Hunt's own copy still describe the older "rules & skills" product.

### 4.3 Conductor

macOS-only ("not available for Windows or Linux yet"), Melty Labs. Pricing: Free $0 (unlimited local parallel workspaces, BYO keys), **Pro $50/mo** (cloud hours, multiplayer to 5, API, mobile), Teams $60/mo/user, Enterprise custom. Cloud workspaces are Vercel sandboxes, 8-core/16 GB, Amazon Linux 2023, us-east-1, not yet separately charged (https://www.conductor.build/markdown/pricing, https://www.conductor.build/docs/installation).

Model: project → repository → workspace = 1 branch = 1 worktree under `~/conductor/workspaces/<repo>/<city>`, sharing the object DB. The docs are unusually honest: "Workspace isolation is development isolation, not a security boundary. Agents and commands still run on your Mac with your user permissions" (https://www.conductor.build/docs/concepts/workspaces-and-branches). Four harnesses are bundled — Claude Code, Codex, OpenCode as managed executables, Cursor via API key — one chat tab = one harness + one model (https://www.conductor.build/docs/reference/harnesses).

The design worth copying is the merge-readiness aggregation: the **Checks** tab pulls git status, PR metadata, CI, deployments, review threads and todos into one place, and "Conductor may block or discourage merge actions when required work is still open, such as unresolved todos or failed checks"; todos are explicitly merge-blocking (https://www.conductor.build/docs/reference/checks, https://www.conductor.build/docs/reference/todos). Attention is multi-channel: unread badges in sidebar and Dock, completion sounds, notifications titled by chat not branch, and the ⌘⌥L jump (https://www.conductor.build/docs/reference/keyboard-shortcuts, https://www.conductor.build/changelog/page/2).

Two cautions with evidence: tool approval only arrived as an *enterprise* setting in 0.41.0, and a Hacker News report documents Claude Code refusing a write for being "outside my writable sandbox" then performing it when told to "just escape the sandbox", despite `.claude/settings.json` enabling sandboxing — i.e. Conductor's default full-permission wrapper made the guardrail non-binding (https://news.ycombinator.com/item?id=47256614). Its own FAQ still says Conductor is free, contradicting `/pricing` — the FAQ is stale (https://www.conductor.build/docs/faq).

### 4.4 Vibe Kanban

Sunsetting, not renamed: the company (bloop) shut down, the README headline is literally "Vibe Kanban is sunsetting", and remote services (issues, comments, projects, organisations) were removed 30 days after the announcement, leaving "a fully local architecture". Repo `BloopAI/vibe-kanban`, Apache-2.0, 28,416★, not archived, last push 2026-09-19; npm `vibe-kanban` latest **0.1.44** (registry; a third-party wiki's 0.1.45 is wrong) (https://github.com/BloopAI/vibe-kanban, https://www.vibekanban.com/blog/shutdown, https://www.npmjs.com/package/vibe-kanban).

Its schema is the best free reference in the field:

- **Task** = `{title, description, status, parent_workspace_id}` — status only, **no agent config**; `TaskStatus` = Todo | InProgress | InReview | Done | Cancelled (https://github.com/BloopAI/vibe-kanban/blob/HEAD/crates/db/src/models/task.rs).
- **Workspace** = the execution attempt (formerly "task attempt"): `{task_id, container_ref, branch, archived, pinned, name, worktree_deleted}`, can span multiple repos and multiple sessions, auto-named from the first prompt truncated to 60 chars, GC'd after 1 h archived / 72 h unarchived (https://github.com/BloopAI/vibe-kanban/blob/HEAD/crates/db/src/models/workspace.rs).
- **ExecutionProcess** records `{run_reason, status, exit_code, dropped}` with per-repo `before_head_commit`/`after_head_commit` — this is what makes a diff **attempt-scoped rather than branch-scoped**, and `dropped` is a soft-rewind that hides processes from the timeline without destroying them (https://github.com/BloopAI/vibe-kanban/blob/HEAD/crates/db/src/models/execution_process.rs).
- `ExecutorConfig {executor, variant, model_id, agent_id, reasoning_id, permission_policy}` is **per-execution, not per-task**; profiles persist as a diff against an embedded `default_profiles.json`, and the recommended executor is whichever the machine is actually logged into.

How it drives Claude Code is directly reusable for warden's Claude Code lane: `npx -y @anthropic-ai/claude-code@2.1.119 -p --verbose --output-format=stream-json --input-format=stream-json --include-partial-messages --replay-user-messages`, `--resume <session_id>` for follow-ups, `--resume-session-at <uuid>` for rewinds, `--permission-mode=bypassPermissions` or `--disallowedTools=AskUserQuestion` depending on policy. It also has a `disable_api_key` flag that strips `ANTHROPIC_API_KEY` and warns "your Anthropic subscription is not being used" — a first-class Max-subscription path (https://github.com/BloopAI/vibe-kanban/blob/HEAD/crates/executors/src/executors/claude.rs). Reviews are ordinary agent runs: `spawn_review` defaults to a follow-up with a mechanically generated prompt anchored to the attempt's base commit (https://github.com/BloopAI/vibe-kanban/blob/HEAD/crates/executors/src/executors/mod.rs).

### 4.5 Claude Squad, Sculptor, Omnara

**Isolation strategies differ materially:**

| | Isolation | Resident cost on one Mac mini |
|---|---|---|
| Claude Squad | tmux session + git worktree **per session** | one tmux pane-process + one working tree per task; no VM/container/daemon |
| Sculptor | worktree per **workspace**, agents share the checkout ("if two agents edit the same file simultaneously, they can produce conflicting changes") | one Electron app + backend (~100 MB binaries) |
| Omnara | **none** — agents are durable Postgres event logs; "machines" attach/release | Postgres + Redis + workers + blob storage via compose |

(https://github.com/smtg-ai/claude-squad/blob/HEAD/README.md, https://github.com/imbue-ai/sculptor/blob/HEAD/docs/help/agents.md, https://github.com/omnara-ai/omnara/blob/HEAD/README.md)

Maintenance as of the run: Claude Squad `smtg-ai/claude-squad`, AGPL-3.0, 8,640★, v1.0.20 (2026-08-20) — ~2 months quiet; Sculptor `imbue-ai/sculptor`, MIT, 240★, sculptor-v0.49.0 (2026-10-21), self-described "experimental research preview"; Omnara `omnara-ai/omnara`, Apache-2.0, 2,954★, omnarad-v0.2.9 (2026-10-21), commits hours old.

**Omnara is the strongest approval-UX design**, and it has pivoted from "run Claude Code from your phone" to "open-source managed agent platform… a self-hostable alternative to Claude Managed Agents" — the README no longer mentions mobile and `frontend/apps` contains only `web`, while the App Store/Play listings still describe the old laptop-remote-control model. Its permission machinery:
- three modes per tool (`always_allow` / `always_ask` / `always_deny`), with per-server defaults and per-tool overrides (https://docs.omnara.com/tools/permissions);
- permission and question interactions ride the same schema: title + context key/value pairs + questions with options; permission forms always have exactly one question with Allow at index 0, Deny at index 1, and Deny's free text becomes the reason the model sees;
- **first-writer-wins** — idempotent replay returns 200, conflicting answers return 409 `idempotency_key_conflict`, and canceled interactions stay listable for audit (https://docs.omnara.com/events/interactions);
- routing out of the dashboard: "Anyone able to respond in an eligible provider conversation can answer its questions and approvals without an Omnara account", with each interaction capturing its destination at creation (https://docs.omnara.com/integrations/overview);
- `activity` is a first-class enum: `running`, `waiting_on_interaction`, `idle`, `archived` (https://docs.omnara.com/llms.txt).

**Sculptor's best idea** is the interaction handler: it auto-approves tool permissions under a sandbox and substitutes `AskUserQuestion` and `ExitPlanMode` with native panels, instructing Claude to prefer them "because calling them raises a notification that is more likely to reach you". Pending questions survive app reload and harness restart, and the message queue is visible, editable and deletable (https://github.com/imbue-ai/sculptor/blob/HEAD/docs/help/integrated_harnesses.md). Its **CI Babysitter** polls PR checks ~every 30 s, holds while any agent is busy or waiting on you, retries up to 3 (range 1–10), re-arms only on a *new* failing run, and "never merges or closes a PR itself" (https://github.com/imbue-ai/sculptor/blob/HEAD/docs/help/ci_babysitter.md).

### 4.6 The cloud-queue reference set

Cursor Cloud Agents run per-run VMs with "as many agents as you want in parallel", attach screenshots/video/logs as evidence, and expose a read-only share URL; the **Agents Window** (GA with Cursor 3, 2026-04-02) is a multi-workspace view across projects with an isolated worktree per task and local↔cloud handoff (https://cursor.com/docs/cloud-agent, https://cursor.com/docs/agent/agents-window). Codex Cloud gives each task its own workspace that keeps running while the laptop sleeps, and the CLI can "list recent cloud chats and check their status" (https://developers.openai.com/codex/cloud). GitHub Copilot cloud agent sessions have a **hard 59-minute cap that "cannot be extended or bypassed"** and expose session logs plus cross-surface session history (https://docs.github.com/en/copilot/concepts/agents/coding-agent/about-coding-agent). Claude Code cloud sessions are the parallelism primitive — "each `--cloud` command creates its own cloud session that runs independently", idle questions stay answerable "up to environment expiry", and sessions can be teleported back to the terminal (https://docs.claude.com/en/docs/claude-code/claude-code-on-the-web).

`amux` is described as "an open-source control plane that runs your AI engineering team on your own machine — dozens of parallel Claude Code, Codex CLI, or Gemini CLI sessions, monitored from your phone" — search-snippet only, unverified (https://amux.io/compare/amux-vs-codex/).

**Ranked for one operator, 10–50 sessions, one Mac mini:** (1) Blume — only loop that matches observe-then-one-decision, local-first, no orchestration conflict with warden; (2) Conductor's Checks tab + ⌘⌥L as *patterns*, not as the runtime (macOS-only, unsandboxed, $50 additive); (3) Vibe Kanban's schema as the data model; (4) Omnara's interaction schema for the approval card; (5) cloud queues as UX references only — their tenancy is wrong for your host.

---

## 5. What the other harnesses gate on

### 5.1 Codex (CLI v0.163.0): two orthogonal knobs, and four approval policies

Sandbox = what it *can* do; approval policy = when it must *ask*.

- `AskForApproval` enum has exactly four variants: `UnlessTrusted` → `"untrusted"`, `OnRequest` (the `#[default]`, serde alias `on-failure`), `Granular(GranularApprovalConfig)`, `Never` (https://github.com/openai/codex/blob/HEAD/codex-rs/protocol/src/protocol.rs).
- `GranularApprovalConfig` has five booleans — `sandbox_approval`, `rules`, `skill_approval`, `request_permissions`, `mcp_elicitations` — where `false` means those requests are **auto-rejected instead of shown**.
- **`untrusted` is retired as user-facing config**: "Codex and ChatGPT Work no longer support `approval_policy = "untrusted"`. The retired setting can prevent either client from starting." Replacement is `sandbox_mode = "read-only"` + `approval_policy = "on-request"`, or a per-project `[projects."/path"] trust_level = "untrusted"` (https://learn.chatgpt.com/docs/agent-approvals-security.md).
- **`approvals_reviewer = "auto_review"`** routes eligible approvals to a reviewer agent instead of you: only actions that already need approval (sandbox escalations, blocked network requests, `request_permissions`, side-effecting MCP calls) get reviewed, in-sandbox actions continue without review, critical-risk actions are denied, and prompt/review/parse failures fail closed (https://www.codex-docs.com/en/docs/agent-approvals-security).
- Sandbox modes: `read-only`, `workspace-write` (with `.git`, `.agents`, `.codex`, `.aws` kept read-only under writable roots), `danger-full-access`, plus source-only `external-sandbox`. Network is off by default in `workspace-write` unless `[sandbox_workspace_write] network_access = true`. OS enforcement: macOS Seatbelt, Linux bwrap+seccomp, Windows MXC.
- Third-party Oct-2026 guides still list only three policies — stale coverage of the retired value.

### 5.2 Jules: two gates, both default-open

- Plan approval is not a durable stop: "If you navigate away, Jules will eventually auto-approve the plan, which is set on a timer" (https://jules.google/docs/review-plan/). Via API, `requirePlanApproval` is required to keep the gate; "If not set, plans are auto-approved", and state `AWAITING_PLAN_APPROVAL` is pollable (https://jules.google/docs/api/reference/sessions/).
- `automationMode` has exactly two values: `AUTOMATION_MODE_UNSPECIFIED` and `AUTO_CREATE_PR`. **No merge value exists** (https://jules.google/docs/api/reference/types/).
- Autonomy that bypasses prompts entirely ships anyway: CI Fixer re-pushes fixes "all without manual intervention", Scheduled Tasks "will wake up, perform the task, and open a PR", and a **Planning Critic** agent reviews all auto-approved plans (claims a 9.5% reduction in task failure rates) (https://jules.google/docs/changelog/).
- **No Jules autonomy-level or risk-tier model exists.** Google's only risk-tiered approval model is the SRE L0–L4 table with "Progressive Authorization" and real-time downgrade of an L3 request to L2 on elevated risk score — built for AI-Ops, not coding PRs (https://sre.google/resources/practices-and-processes/ai-engineering-reliable-operations/).

### 5.3 Devin: layered permissions, no ladder

Five CLI modes — Normal (default), Accept Edits, Smart, Bypass, Autonomous (sandbox-only) — resolved Deny → Ask → Allow with org/team settings at highest precedence. Smart mode never auto-approves package installs, mutating git, `rm`/`sudo`, destructive cloud-CLI ops, or dotenv/key/agent-config access (https://docs.devin.ai/cli/reference/permissions). Approval prompts are graded (Allow once / session / project / globally, plus "Edit command"). Confidence is an approval gate: "When Devin doesn't have 🟢 confidence (i.e., 🟡 or 🔴), it will now wait for user approval before proceeding with its plan" (https://docs.devin.ai/release-notes/2025). **Local Hands** is the only per-tool approval loop for cloud sessions acting on your machine — "By default, every local tool call stops and asks you" — and even with bypass on, credential files, privilege escalation, destructive commands and shell profiles always ask (https://docs.devin.ai/work-with-devin/local-hands). Security profiles carry Recommended vs Mandatory enforcement, and mandatory lower-level profiles are **intersected** so they can only tighten (https://docs.devin.ai/product-guides/security-profiles). Cognition's blog index contains no L1–L5 framework (https://cognition.com/blog).

---

## 6. Attention design for Argo + Hermes

### 6.1 A taxonomy of legitimate human need — and how to make each rare

Apply the SRE test first: a page must be "urgent, actionable, novel, and requiring intelligence" — "If a page merely merits a robotic response, it shouldn't be a page" (https://sre.google/sre-book/monitoring-distributed-systems/).

| Reason | Make it rare by |
|---|---|
| **A. Irreversible action** (merge, deploy, spend, external comms) | Reversibility: diff-first, checkpoints, narrow credentials so only no-undo ops gate |
| **B. Business/product judgment** | Decision-policy-as-code with pre-registered defaults; each real escalation should retire a *class* |
| **C. Under-specified request** | Proceed on best guess + recorded assumption + cheap reversible trial; escalate only if the trial fails |
| **D. Hard block** (quota, credential, permission) | Capacity lanes and fallbacks |
| **E. Verification shortfall** | Machine-checkable definition-of-done + evidence bundle |
| **F. Novel anomaly** | Legitimately common early — but every instance must produce a playbook |
| **G. Timeout/default decision** | Solved mechanically (§6.2), never by judgment |

Your note (updated 2026-09-10) records that warden cadded quota/permission errors as needs_human — "the signal → ledger → card leg did its job" — while `verified_unattended_fixes` was structurally 0 because dispatch/implement/merge/approvals still ran outside the control plane (<brain-web>/Inbox/Estate%20Review%20Round%202%20%E2%80%94%20Findings). That is category D dominating your interruption budget: the fix is actuator coverage in warden, not dashboard polish.

### 6.2 Mechanics: near-zero interruption without silent failure

- **Three tiers, one push channel.** Page / ticket / dashboard; push only the blocking tier. "Email alerts are of very limited value… you should favor a dashboard that monitors all ongoing subcritical problems." SRE Workbook separates by required reaction speed: if it won't exhaust the budget within hours or a few days, it's a ticket, not a page (https://sre.google/sre-book/monitoring-distributed-systems/, https://sre.google/workbook/alerting-on-slos/). The Workbook's four quality knobs — precision, recall, detection time, reset time — are the right instrumentation for the escalation classifier itself.
- **Escalate on timeout with a safe default** = Sheridan–Verplank **level 6**, "allows the human a restricted time to veto before automatic execution". The default must be the cheap reversible branch — park, revert, open PR unmerged — never the irreversible one (https://ocw.mit.edu/courses/16-422-human-supervisory-control-of-automated-systems-spring-2004/6cb73391272fcbf537e50790c002d186_020504hmancenter.pdf). Parasuraman's stage model says set the level *per stage*: analyse automatically, gate only action.
- **Deadman + heartbeat is mandatory.** Billings: "Automation should never perform or fail silently"; Bainbridge: automatic control "can camouflage system failure… so it should fail obviously" (https://gwern.net/doc/sociology/technology/1983-bainbridge.pdf). Each session emits last-progress + expected-next-progress; warden flags **stuck** as a distinct card type, not as failure.
- **Never make yourself the monitor.** Vigilance on a low-event display collapses in "more than about half an hour" (Mackworth, via Bainbridge). Absence-of-card must never be the safety mechanism. And do not manufacture events to fix vigilance — "it would be a mistake, however, to increase artificially the rate of computer failure as the operator will then not trust the system."
- **Copy PagerDuty's state machine verbatim.** Escalation notifies one target at a time until someone acknowledges; **ack stops escalation and pauses notifications but does not resolve**; a re-triggered acknowledged incident resumes the policy; "escalates after N min" is a timeout, not a delay; default 30 min, minimum 3 where a level has multiple targets, repeat up to 9× (https://support.pagerduty.com/main/docs/escalation-policies). Nothing in the agent-tooling space models ack-vs-resolve yet — that is a free differentiator.
- **Batch deliberately.** Interruption cost depends on crossing a working-sphere boundary — out-of-sphere interruptions are disruptive, in-sphere ones "are even considered beneficial" (Mark, Gonzalez & Harris, CHI 2005, 24 workers: 57.1% of working-sphere segments interrupted; 11 min 4 s average before switching). Schedule 2–3 fixed decision windows and let only `blocking` break them.
- **The "23 minutes" figure is wrong.** CHI 2005 reports **25 min 26 s** (sd 54 min 48 s) to resume same-day interrupted work and **22 min 37 s** for externally-interrupted work. The 23m15s number traces to a 2006 interview, not the paper (https://ics.uci.edu/~gmark/CHI2005.pdf).

### 6.3 Metrics

Interventions/day · **autonomy ratio** (decisions taken without human ÷ total; your baseline is `verified_unattended_fixes` = 0) · **time-to-decision** (MTTA analogue) · **false-escalation rate = 1 − precision**, paired with recall, detection time and reset time · **stuck-detection lead time** · **silent-failure count** (must be 0) · **deferral aging** (cards snoozed past N days) · **ack-without-action rate** (rubber-stamping proxy — the metric Feng et al. name as L4's core failure).

### 6.4 Concrete Argo layout

- **Lane 1, "Needs you"** — capped at ~5 cards. Each card = **one decision**, why-now, evidence links (diff, CI run, screenshots), 2–3 options with the default pre-selected, and the expiry + what happens on expiry. Cap the lane: when it exceeds 5, warden must *not* queue more work.
- **Lane 2, "In flight"** — autonomy telemetry: per-session state (adopt Blume's Running/idle/error/**approval**/todo vocabulary), heartbeat and stuck badges, parallelism count.
- **Lane 3, "Done today"** — digest, not a feed. No infinite scroll anywhere.
- **Chat (Hermes)** pushes only `blocking`, renders the *same* card payload with buttons, and writes ack/decide to the warden ledger so dashboard and chat are one state, not two. Heartbeat monitoring must be independent of the agents it watches.
- **Claude Code mapping**: default to `plan` or `dontAsk` + allowlist; `acceptEdits` inside a sandbox with `autoAllowBashIfSandboxed`; **`bypassPermissions` never** (and remember it can't be set from project settings, which is a safety feature here). A PreToolUse **http** hook into warden returns `ask` only for the irreversible set, so gates fire on a narrow, auditable class and everything else flows.
- **Sequencing caveat.** Your note (updated 2026-09-07) records the overview loop as observe-only with no automation reacting to it, and two documented consumers "do not exist and were rejected earlier" (<brain-web>/Inbox/Estate%20Review%202026-09). Build the actuator path before the dashboard: a beautiful overview over a 0% autonomy ratio just relocates the bottleneck.

---

## 7. What remains unverified

The largest gaps: darkfactory.dev's security/governance subsystem pages (the richest source on escalation taxonomy) were confirmed to exist in the sitemap but unread; StrongDM's own Principles/Techniques/Products subpages were not fetched, so its real thresholds rest on Pulumi's second-hand account; the primary studies behind the 94%/56% and ~70%/0% figures were not retrieved; Claude Code's OS-sandboxing page, per-event hook schemas, Agent SDK package names, print-mode/`stream-json` shapes and on-disk transcript/OTel paths were not read; Codex's permission-profile page and config reference were not read; Terragon, Happy Coder, Crystal, Kilo/Cline parallel modes and OSS worktree-farm projects were never reached; Omnara's changelog past the three most recent entries (which would date the mobile pivot) and Sculptor/Omnara long-form reviews were partial.


## Unverified (as reported by the job)

- darkfactory.dev sitemap and glossary entry contents (approval-laundering, blast-radius, human-attention-budget, promotion, human-in-the-loop/on-the-loop/out-of-the-loop): Retrieval truncated at ~36k of ~80k characters; glossary entries seen only as URLs, not contents, so no definitions could be verified. (https://darkfactory.dev/sitemap.xml)
- StrongDM Software Factory 'Principles', 'Techniques' and 'Products' subpages — possible source of the concrete gate and threshold details the landing page omits: Landing page read in full but its linked subpages were not fetched; StrongDM's actual numeric thresholds therefore rest on Pulumi's second-hand account. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- OpenAI Codex approval modes, Google Jules approval gates, Cognition/Devin permissions, OWASP agentic guidance, NIST agentic controls and Anthropic agent-safety guidance as surveyed in the frameworks pass: The frameworks pass exhausted its search budget before these could be located; no URLs were returned and guessing documentation URLs was disallowed after a 404. (Codex, Jules and Devin were subsequently covered by dedicated passes.)
- Primary studies behind the 94%/56% sabotage figures, the ~70% vs ~0% silent-failure figure, and the 9-second database deletion post-mortem: These figures are quoted from Dark Factory Dev's citation list; the underlying papers and post-mortems were not retrieved, so the numbers are only as reliable as that secondary synthesis. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- Conductor full-site markdown dump used to confirm token/cost/notification statements: Line-filtered fetch returned only 33 matching lines of a 6,754-line document; it confirmed a Codex goal-bar token budget but could not be used to claim absence of other features. (https://www.conductor.build/llms-full.txt)
- xiaot623/vibe-kanban community fork — maintenance status and scope: Appeared only as a search-result snippet ('A fork version from BloopAI/vibe-kanban'); never fetched. (https://github.com/xiaot623/vibe-kanban)
- Omnara changelog history predating the current release cycle — would date the pivot and any explicit removal of mobile clients: Page truncated at 6,174 of 14,163 characters — only the three most recent entries were readable. Absence of a mobile mention in the read portion is NOT evidence of removal. (https://docs.omnara.com/changelog)
- Independent long-form reviews of Omnara's pivot and of Sculptor: Only a search-result snippet was available; the review's analysis could not be read in full, so claims resting on it are capped at medium confidence. (https://tomrochette.com/agents/orchestration/omnara/)
- Current App Store / Google Play descriptions and update dates for the Omnara mobile apps: Store listings were seen only as search snippets, not fetched; whether they reflect current or legacy behaviour is unresolved. (https://play.google.com/store/apps/details?id=com.omnara.app)
- Blume apps/cultivar page: Fetch returned zero extractable content across readability, renderer and fallback extractors; other /apps/ pages proved to be marketing mini-games rather than products. (https://blume.codes/apps/cultivar)
- Cursor background-agent documentation page as originally linked: Redirected to the generic Cursor docs home rather than the background-agent content; the substantive page was cursor.com/docs/cloud-agent, which states Cloud Agents were formerly called Background Agents. (https://docs.cursor.com/en/background-agent)
- Parasuraman, Sheridan & Wickens (2000) original IEEE paper text on types and levels of human interaction with automation: TLS certificate verification failure on the host; the same taxonomy was retrieved second-hand via the MIT 16.422 course deck instead. (https://www.cs.uml.edu/~holly/91.549/readings/sheridan-autonomy.pdf)
- PagerDuty escalation policy page — multi-user notification methods and remaining sections: Fetch truncated at 9,098 of 16,537 characters; the core escalation/ack/timeout semantics were read, the tail was not. (The page itself WAS retrieved elsewhere in this run and backs citations — this entry records an unverified topic, not an unusable source.)
- developers.openai.com/codex/security as a live official page carrying approval-and-sandbox content: The URL resolved to the docs navigation shell / Codex Security product page with no approval-and-sandbox content; the substantive page now lives at learn.chatgpt.com/docs/agent-approvals-security. (https://developers.openai.com/codex/security)
- Jules legal/settings text — enterprise controls, retention, admin policy: Behind Google sign-in; not retrievable anonymously. (https://jules.google.com/legal)
- @google/jules-sdk source for the default value of requirePlanApproval/requireApproval: Attempted src/types.ts, which does not exist at that path; budget was then exhausted before the correct source file could be located, so the claim that the SDK forces approval by default remains unverified. (https://github.com/google-labs-code/jules-sdk)
- Devin Interactive Planning docs page content (current plan-approval flow): The fetched page returned generic Tutorial Library content (renderer fell back) rather than the Interactive Planning doc; the same happened on the cognitionai.mintlify.app mirror. Plan-approval behaviour was taken from the 2025 release notes instead. (https://docs.devin.ai/work-with-devin/interactive-planning)
- Whether Devin cloud sessions inside their VM expose any per-command approval outside network policy and Local Hands: The docs index was truncated at 36,500 of 46,447 characters, so the Desktop/API/remainder of the Enterprise sections were not read; absence of such a page there is not evidence that none exists. (https://docs.devin.ai/llms.txt)
