# Research: 2026-10-22-cockpit-ux-patterns

Job `03918158-71e1-4452-8964-87a4adc72dc9` · depth standard · status ok

**Query:** Blume (blume.codes) agent-fleet cockpit UX in 2026 and two or three open-source equivalents for supervising many coding agents and projects (e.g. Vibe Kanban, Claude Squad, Conductor, agent-deck, Omnara, Sculptor, Nimbalyst, Paperclip, open-source "agent cockpit" dashboards): extract concrete UI patterns — how they show agent state (running/idle/stuck/needs input), how a task/delivery page is laid out (brief, runs, diffs, checks, review, decision), how they adapt the layout to the situation (quiet vs incident vs many in flight), per-project pages, notification/attention design, mobile use, and any published screenshots or docs describing those screens. For each: licence, maturity, what is worth copying for a solo developer's control plane built on a custom React UI kit, and what to avoid.

## Bottom line

**Blume in 2026 is a narrow desktop sidecar, not a fleet cockpit**: it ships an eight-item left rail (Deliveries, Projects, Agents, Usage, Improve, then Plugin, Feedback, Settings), renders agent state as a live continuously re-sorted session list with five states (running, idle, error, approval, todo), and shows only numeric count badges for attention — but **Deliveries and Projects, the two screens the query cares most about, have no published screenshot, doc or changelog showing their layout**, and no responsive/mobile posture exists at all (desktop only, with a "Send Download Link" email handoff on phones).

**For a solo developer's React control plane, copy four things and skip the rest**: Vibe Kanban's *row-level state indicators + grouped/flat sidebar toggle* (Running / Idle / Needs Attention with a raised-hand icon), Conductor's *ambient status matrix instead of banners* plus the ⌘⌥L "next chat needing attention" jump, cmux's *four-layer attention stack* built because OS notification bodies carry no context, and agent-deck's *two-axis grouping* (policy groups vs. parent lineage) with an escalation-only Telegram/Slack bridge.

**Licence/maturity triage**: Vibe Kanban (Apache-2.0, v0.1.44, 28,427★, last push 2026-09-19), agent-deck (MIT, v1.16.30, 1,138★), Nimbalyst (MIT client repo only — the sync Worker is a separate project, v0.81.7, 819 open issues), Paperclip (MIT, 105,890★, v2026.1012.0) are safe to borrow from; **Conductor is closed-source commercial** (0.91.0, 15 Oct 2026) so copy patterns not code; **Sculptor asserts MIT in GitHub metadata but has no LICENSE file at repo root** — treat as medium confidence.

**The gap nobody fills**: no product publishes explicit calm vs. incident vs. many-in-flight layout design writing. The de-facto pattern across all of them is *one shell that never changes shape* — ambient row/tab status + one attention queue + detail only on selection — with only counts and hidden-by-default columns varying.

---

## 1. Blume (blume.codes): what is actually on screen

**Posture.** A desktop app for macOS, Windows and Linux; no web dashboard and no mobile app. The marketing site detects mobile user agents and swaps the download CTA for an email-based "Send Download Link" handoff. Its own product mock describes the posture: *"One narrow sidecar that watches your harnesses, tracks the hidden files behind them, and keeps your rulebook honest"* — a panel docked beside your terminals, not a full-screen console. The founder's launch screenshots confirm it: *"Two Claude Code terminals and a Codex session, with Blume on the right tracking all three"* [(product preview)](https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana), [(launch post)](https://dev.to/pederaa/i-built-blume-it-turns-your-coding-agent-corrections-into-rules-3oa5).

**Shell.** Single left rail in this order: `Deliveries`, `Projects`, `Agents`, `Usage`, `Improve` (badge **2**), then a lower group `Plugin`, `Feedback`, `Settings`; the `blume` wordmark carries its own badge (**3**). Main pane is single-column, opened by a breadcrumb header row with `Back`, a `Beta` chip and `Share feedback`. Global search is `⌘F` across conversations, messages, projects, setup artifacts and suggestions, with keyboard filters, landing on the exact source with the match highlighted [(preview)](https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana), [(blog)](https://blume.codes/blog/you-already-told-your-agent-that).

**Agent state — the one screen with real detail.** v1.0.56 (27 Jul 2026) lists exactly the states rendered: *"Running, idle, error, approval, and todo"*, states that Codex todo progress and Claude approval waits are represented, and that ordering is steadier with *"the whole panel flickers less"* — i.e. a **live, continuously re-ordered session list**, not a grid. The view is characterised as showing *"what each coding agent is doing right now, and the exact moment one finishes or needs your approval"*. State sits **per session row, inside a cross-project rail** — there is no separate fleet grid.

**Improve (the only fully verifiable layout).** Title + one-line purpose → two count chips (`Signals 3 found`, `Clusters 1 forming`) → a **Signal rates** card subtitled "Share of your messages · last 30 days" with `View details` and three percentile rows (Corrections 63rd percentile ↓41%, Steering 48th ↓52%, Frustration 61st ↓79%) over a Jun 18 / Jul 1 / Today axis → an `IMPROVEMENTS 2` card list, each row = title, `Proposed` chip, scope label (`Demo · Acorn workspace` / `Global setup`), evidence count (`3 signals`), with per-item **Apply / Snooze / Dismiss**. The list closes with `Show resolved improvements (2)` — **the only in-place collapse/expand affordance verifiable anywhere in the product** [(preview)](https://product-preview.blume-codes.com/product-preview/?flower=purple-bluebell), [(preview)](https://product-preview.blume-codes.com/product-preview/?flower=blue-forgetmenot). Worth copying: a percentile-plus-trend row is a far better "how am I doing" gauge than a raw event count, and scope + evidence count on a card lets one list span global and project contexts.

**Setup** is one cross-project inventory of CLAUDE.md files, skills, hooks and MCP servers across harnesses and projects, each artifact getting a type-aware detail page with relationships, diagnostics and history. **Usage** shows per-provider remaining quota across Claude, Codex and Cursor side by side.

**Attention.** Only numeric count badges — `3` on the wordmark, `2` on Improve. No inbox, banner, toast, menu-bar presence or push surface is documented on any retrieved page. That is a genuine gap relative to every other tool here.

**Layout adaptation: unverified.** No empty state, incident banner, density mode, triage view, sorting control or grouping behaviour is documented for Deliveries, Projects or Agents, and the official preview renders each screen only as a PNG so pixel layout of the non-Improve screens could not be read. Docs are two short setup guides; there is no UI walkthrough [(docs)](https://blume.codes/docs).

**Verdict.** Copy: the docked-sidecar posture, count badges on nav items, ⌘F search that lands on the matched source, and the evidence-count-on-card pattern. Avoid: modelling the whole product on Improve-style analytics while leaving the delivery triage screen undocumented — the information architecture has not been pressure-tested at fleet scale in public.

---

## 2. Vibe Kanban — Apache-2.0, the best-documented layout of the set

**Two generations coexist.** Legacy `core-features/*` pages still describe task + attempt, and the current nav has dropped that section entirely (`creating-task-attempts` now 404s), so the issue→workspace→session model is the current UI surface.

**Detail page = a four-panel workspace**: left workspace sidebar; centre-left conversation; centre-right a **Changes / Logs / Preview** toggle (file tree + inline diffs + inline comments; process tabs with stdout/stderr + log search; preview browser with device modes); right sidebar with a git block (branch, target branch, uncommitted count, commits ahead/behind), an xterm.js terminal and per-workspace notes. Panel visibility toggles from the navbar or command bar and **layout proportions persist per workspace** — a cheap, high-value pattern for a React kit [(interface)](https://vibekanban.com/docs/workspaces/interface).

**State visualisation — the pattern to steal.** Sidebar rows carry indicators: **Running** (actively processing), **Idle** ("waiting for input"), **Needs Attention** (pending approval, **raised-hand icon**), **Pinned**, a blue dev-server dot, and a PR-status badge. The sidebar switches between a **flat list and an accordion grouped by status**, with search, pin and archive. This is the cleanest single answer in the corpus to "how do I show running/idle/stuck/needs-input without a grid" — one row, one glyph family, plus a grouping-mode toggle [(interface)](https://vibekanban.com/docs/workspaces/interface).

**Review loop.** Legacy but instructive: completed tasks land in **In Review**, the **Diff icon** opens all agent changes, hovering a line + `+` adds a line comment, comments across files are **collected and sent as one message**, after which the task returns to **In Progress**. Any approval-requiring action gets an **inline row with tick/cross** beneath the action. Triple-dot → **View Processes** lists agent sessions, dev servers and build scripts with per-process logs [(review)](https://vibekanban.com/docs/core-features/reviewing-code-changes), [(monitoring)](https://vibekanban.com/docs/core-features/monitoring-task-execution). The batched-comment behaviour is worth copying verbatim: it stops review becoming a chat firehose.

**Density and dormant work.** Board = column-per-status, colour-indicated headers, six default statuses, filter bar (search/priority/assignee/tags/sort), multi-select with an accent ring and a bottom bulk-action bar, empty columns showing an empty state with a `+`. **Critical detail: Backlog and Cancelled are hidden as columns by default while remaining status tabs** — dormant work collapses out of the default view without being deleted [(kanban)](https://vibekanban.com/docs/cloud/kanban-board), [(projects)](https://vibekanban.com/docs/cloud/projects.md). List view groups issues into **collapsible status sections with counts**, rows showing ID, title, workspace indicator and age, selection checkbox revealed on row-edge hover [(list view)](https://vibekanban.com/docs/cloud/list-view).

**Projects and mobile.** Org → project → board, with a *separate* global Workspaces view for running agents; sidebar = square project icons with two-letter abbreviations + tooltip, header project dropdown, per-project colour. Remote access is pairing-code → `cloud.vibekanban.com` in the phone browser → "Link a host" [(getting started)](https://vibekanban.com/docs/getting-started), [(remote)](https://vibekanban.com/docs/remote-access).

**Maturity**: Apache-2.0, 28,427★, 3,031 forks, 543 open issues, not archived, last push 2026-09-19; GitHub release tag `v0.1.44-20260424091429` published 2026-04-24; npm `vibe-kanban` 0.1.44 published 2026-09-19, node >=20.19.0 [(GitHub)](https://github.com/BloopAI/vibe-kanban), [(npm)](https://www.npmjs.com/package/vibe-kanban). **Note the split**: the GitHub release is five months stale while npm is current — read the npm stream as the live one.

**Copy**: row indicators with a glyph per state, flat↔grouped toggle, per-workspace persisted panel proportions, hidden-by-default dormant columns, batched diff comments. **Avoid**: running tasks and running agents in two different top-level places (Projects vs Workspaces) — that is why it has no single cross-project "needs you" surface.

---

## 3. Conductor — closed-source, the best attention mechanics

**Detail page = workspace tabs**: chat/composer; **Diff Viewer (⌘⇧D)** with file list, unified/split toggle, commit filtering, line comments that become composer attachments, GitHub review threads that can be resolved, mark-file-viewed (⌃V); **Checks tab**; terminal (Big Terminal Mode); Notes; Actions; Checkpoints (revert per turn) [(diff viewer)](https://www.conductor.build/docs/reference/diff-viewer).

**The Checks tab is the single strongest "task/delivery page" idea in the corpus**: it collects merge-readiness in one place — git status, PR metadata, CI/status checks, deployments, GitHub comments and review threads, Todos — and **Conductor blocks or discourages merge when required work is still open**. Documented flow: confirm branch → open/update PR → fix failing checks → send unresolved comments to the agent → complete todos → merge [(checks)](https://www.conductor.build/docs/reference/checks). For your delivery unit, this is the pattern that turns "brief, runs, diffs, checks, review, decision" into one gate rather than six tabs.

**Actions as suggested next steps**, keyboard-bound: ⌘⇧P create PR, ⌘⇧Y commit+push, ⌘⇧M merge, ⌘⇧X fix errors, ⌘⇧R review, ⌘⇧A archive, ⌘⇧D diff. And the jump: **⌘⌥L = "Next chat needing attention"**; ⌘1–9 switch workspace, ⌘⌥↑/↓ move between workspaces [(shortcuts)](https://www.conductor.build/docs/reference/keyboard-shortcuts). One keystroke from anywhere to the one blocking item is worth more than any inbox.

**State.** v0.35.0 (11 Feb 2026) grouped workspaces by status (backlog / in progress / in review / done), labelled by PR title. v0.44.0 (24 Mar 2026) put GitHub status (merged, failing CI, conflicts) at a glance on the sidebar, revealed metadata + next actions on hover *without leaving the current chat*, and **shows when an agent needs permission** [(0.35.0)](https://www.conductor.build/changelog/0.35.0-workspace-status), [(0.44.0)](https://www.conductor.build/changelog/0.44.0-new-sidebar-rebuilt-composer-codex-checkpoints).

**Situation-adaptive — the anti-pattern is documented as a bug.** A **Workspace status matrix** (Experimental) gives distinct indicators for routine runs, attention, errors, running PR checks and merged PRs, shown in Home, the sidebar and workspace tabs; notifications now show the chat's title, not the branch. Crucially: *"an error in the workspace tab bar no longer replaces the whole workspace with an error screen"* — full-screen escalation was the defect, ambient status is the design. Same family of fixes: sidebar jumping when archiving the last workspace, empty gap accumulating in the status-grouped sidebar, project filter leaking across organisations [(changelog)](https://www.conductor.build/changelog).

**Mobile** is two-pronged: a Conductor iOS app (chat and merge PRs with cloud workspaces) and **Remote control** (Experimental) pairing by QR to drive local Mac workspaces, E2E-encrypted via Conductor's relay, local workspaces only, disabled under enterprise privacy [(remote control)](https://www.conductor.build/docs/reference/remote-control). Cloud adds a sandbox panel with status/CPU/memory, Open via SSH, one-way sync, port forwarding, sleeping-after-4h and an "Unresponsive" state [(cloud)](https://www.conductor.build/docs/cloud/working-with-cloud-workspaces).

**Maturity**: 0.91.0 "A (mostly) boring update", 15 Oct 2026, preceded by 0.90.0 "Conductor for iOS" (2 Oct 2026), near-weekly since 0.0.16 (18 Jul 2025) — still pre-1.0, high cadence. macOS app plus iOS app plus paid Cloud/Teams/Enterprise; **no source repository linked from the docs**, i.e. closed-source commercial (pricing text itself was not readable, so the plan/pricing specifics are unverified) [(changelog.md)](https://www.conductor.build/changelog.md), [(llms.txt)](https://www.conductor.build/llms.txt).

**Copy**: Checks-as-merge-gate, suggested-next-action shortcuts, ⌘⌥L jump, status matrix instead of banners, hover-for-metadata-and-actions. **Avoid**: scoping errors to the whole workspace; any global filter store that spans orgs.

---

## 4. Open-source cockpits worth reading

**agent-deck (`asheshgoplani/agent-deck`) — MIT, v1.16.30, 1,138★.** *Name collision is real*: at least four unrelated projects use "agent-deck"; these findings cover `asheshgoplani/agent-deck` only (Go/tmux TUI + web UI). Licence is plain MIT, no riders [(LICENSE)](https://github.com/asheshgoplani/agent-deck/blob/HEAD/LICENSE). Alive and shipping weekly: v1.16.30 published 2026-10-18, last push 2026-10-21 [(repo)](https://github.com/asheshgoplani/agent-deck).

- **State = exactly four, glyph + colour + meaning**: `●` green Running, `◐` yellow Waiting "Needs your input", `○` gray Idle, `✕` red Error. **No dedicated stuck state** — stuckness is handled socially by a "conductor" session watching heartbeats (default 15 min) as a secondary safety net, plus a transition notifier daemon firing on `running -> waiting|error|idle`.
- **Two grouping axes, deliberately separated**: groups carry *policy* (`max_concurrent`, `default_path`, per-group Claude account/config); dispatch lineage is a separate `--parent <id>` link, with the documented rule *"Don't encode dispatch relationships in a group name"*. This is the cleanest data-model advice in the corpus for a control plane at 20 agents.
- **Fleet tab has an aggregation toggle** — one card per group by default, switched to a **Status | Groups** kanban of what each session is doing (from its status annotation), and *the browser remembers the choice*.
- **Attention**: tmux status-bar rail `⚡ [1] frontend [2] api [3] backend` with number-key jump; `! @ # &` text-labelled state filters inside fuzzy search (not icon-only); conductor bridges to Telegram/Slack **only when a response contains `NEED:`**; browser push is `--push` VAPID-gated and *"only fires while the tab is unfocused"* [(README)](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md).

**Nimbalyst — MIT client repo, v0.81.7, 1,957★, 819 open issues.** `LICENSE` and `LICENSING.md` both assert MIT *for the repository*, while the sync Worker behind `wss://sync.nimbalyst.com` is "a separate project" — so the MIT claim does not cover the collaboration backend [(LICENSING.md)](https://github.com/nimbalyst/nimbalyst/blob/HEAD/LICENSING.md), [(repo)](https://github.com/nimbalyst/nimbalyst). It ships a **session kanban** as a first-class surface with bidirectional session↔file linking ("link sessions to files and files to sessions… group files touched by a session") — the board row is the *session*, not the task. Its mobile companion is the clearest published articulation of the needs-you split: *"see which agents need you and which are still working"*, reply by text or voice and the agent resumes, "queue next tasks" to keep the pipeline full, and push *"agents tell you when they need you"*. Real captured UI is committed to the repo (`.github/assets/sessions-kanban-dark.webp`, `nimbalyst-hero-files-dev-dark.png`, `developers-dark.webp`) [(README)](https://github.com/nimbalyst/nimbalyst/blob/HEAD/README.md). **Avoid**: its surface area — WYSIWYG editors for markdown, mockups, Mermaid, Excalidraw, CSV, data models, Monaco code editing, ghostty terminal, MCP client/servers, an Extension SDK with a shared EditorHost contract. That is a decade of scope for a solo dev.

**Paperclip (`paperclipai/paperclip`) — MIT, 105,890★.** LICENSE at repo root is plain MIT, no rider. Latest release v2026.1012.0 (2026-10-12), last push 2026-10-22 [(LICENSE)](https://github.com/paperclipai/paperclip/blob/HEAD/LICENSE), [(repo)](https://github.com/paperclipai/paperclip). **Its UI surfaces, state model and notification handling were not readable in this pass — no screen-level claims are made.**

**Sculptor (`imbue-ai/sculptor`) — licence uncertain.** GitHub metadata reports `MIT` (240★, sculptor-v0.49.0, 2026-10-21) but **there is no `LICENSE` file at the repo root**, so the SPDX string is not confirmable from in-repo text; a search snippet of its README says "We know it's not truly open source…" (snippet only, not read verbatim). Treat as MIT-by-metadata at best [(repo)](https://github.com/imbue-ai/sculptor). UI not verified beyond the CI-babysitter pattern already established.

**Omnara (`omnara-ai/omnara`) — Apache-2.0, 3,085★, `omnarad v0.2.9` (2026-10-21)**, self-described as *"The open-source managed agent platform. A self-hostable alternative to Claude Managed Agents and OpenAI's Agents API"* [(repo)](https://github.com/omnara-ai/omnara). Its own features page returned HTTP 451, so claims about its dashboard screens rest on third-party survey evidence and are provisional.

**The rest of the field** — cmux, conductor-remote, Orca, Pushary — supply the horizontal mechanics below.

---

## 5. Horizontal mechanics to build into a React kit

**Attention must be layered, because OS notifications are context-free.** cmux is the worked example: a **blue ring on the pane**, a **lit tab with the latest notification text in the sidebar**, a **notification panel listing all pending items**, and a macOS notification — four layers. Its stated motive is the whole lesson: Claude Code's notification body *"is always just 'Claude is waiting for your input' with no context, and with enough tabs open I couldn't even read the titles anymore."* Transport is agent-side (OSC 9/99/777 + a `cmux notify` CLI + hooks), not UI-side. Shortcuts encode the queue: ⌘⇧U jump to latest unread, ⌃⌘U mark-as-oldest-unread-and-jump, ⌘I panel [(cmux)](https://github.com/manaflow-ai/cmux).

**Tier by consequence, not by event.** Pushary's comparison documents the split: approve with Face ID from the iPhone lock screen and deny with one tap, but *"risky commands still open the app"* — the notification carries the actual command and only low-risk ones are one-tap actionable (medium confidence, vendor comparison). A third-party survey of 11 wrappers reports Happy Coder pushing *specifically* on permission-needed or error, and Omnara shipping iOS/Android plus one-tap approve [(Pushary)](https://pushary.com/vs/conductor), [(survey)](https://github.com/deathemperor/infinitus/issues/129).

**Bind push to the durable store, not your app process.** `conductor-remote` watches Conductor's on-disk SQLite for turns ending and sends Web Push directly — *"no Conductor process involved, and it works with the app closed"* — with a payload of workspace name, repo and the agent's last line, deep-linking to the workspace [(conductor-remote)](https://github.com/hyldmo/conductor-remote). Anything that only notifies while your UI is open is useless at 20 agents.

**Situation adaptation: one shell, varying density.** Verified mechanics are small and concrete, not manifesto-length: hidden-by-default Backlog/Cancelled columns; ambient row/tab status instead of banners; empty-state reliability treated as a bug class (*"Fixed the Dashboard appearing empty in cloud organizations"*, *"opening a shared cloud workspace briefly showing 'No open chats'"*). **No product publishes explicit calm/incident/many-in-flight design writing** — that genre of source could not be located or read at all. The de-facto pattern is one ambient channel (row/tab status) + one attention queue (panel/unread marker) + detail only on selection: the shell never changes shape with fleet size, only the counters do.

**Per-project scoping is where the state leaks.** Vibe Kanban: org → project → board, sessions in a separate global Workspaces view (so no single cross-project "needs you"). Conductor: flat workspace list with sections + a project filter + an org switcher, and its changelog documents the failure — *"Fixed a project filter chosen in a local organization hiding every workspace in a cloud organization's sidebar"*, plus *"⌘1–9 skips workspaces hidden in collapsed sidebar sections"*. cmux avoids the switcher entirely: the workspace is the only container, project behaviour is config. **For a solo dev: scope keys, not a global store.**

**Mobile keeps status + one decision and drops the diff workspace.** Every tool that shipped mobile kept "read state, answer, merge/approve" and left multi-panel review to desktop. Small-screen cuts are explicit: conductor-remote hides a button below 400px *"to keep the controls on one row"*. Practical constraints: iOS web push needs Home-Screen install and HTTPS (a plain LAN IP is not a secure context) — plan a native wrapper or accept Safari tabs never get push. And phone-to-Mac dies on power state: macOS Maintenance Sleep and lid-close both break the link regardless of keep-awake apps.

---

## 6. Traps at ~20 agents on a custom React kit

1. **Context-free notifications force a second surface** — budget the in-app inbox because the OS payload can't carry the message.
2. **Custom toasts are a permanent bug source**: Conductor needed fixes for stacked notifications collapsing on hover and content overflowing a collapsed stack.
3. **Filter/selection state leaks across scopes** the moment you have projects × orgs.
4. **Never let one component's error take the screen**, and never build an unbounded "needs you" feed — unread marker + jump-to-latest scales, a feed does not.
5. **Sidebar↔list coupling** (jump-on-archive, collapsed-section numbering, layout shift on count changes) only appears at 20+ items, never in a 3-item demo.
6. **Never build on another app's private IPC**: conductor-remote's sidecar write path broke when Conductor *"changed the private -v2- IPC"*, leaving UI-driving as the only path.
7. **Don't swap the whole screen per state** — it multiplies your test matrix; the products that scale vary density, not layout.

---

## 7. What remains unverified

- **Blume's Deliveries and Projects layouts, and any empty state / density mode / incident banner / triage view.** The nav items exist; no screenshot, doc or changelog shows the screens.
- **Blume's attention surfaces beyond count badges** — no inbox, banner, toast, menu-bar or push surface is documented.
- **Paperclip's and Sculptor's UI surfaces** — licence and metadata only; **Omnara's** rest on third-party survey evidence only.
- **Sculptor's actual licence text** — no LICENSE file at repo root.
- **Conductor's pricing and a formal closed-source statement** — the docs index lists Pricing/Enterprise/Teams, but the pricing page was not readable.
- **Screenshot-level verification of any of these UIs** — all layout claims come from prose and changelog text, not inspected pixels.
- **Published design writing on calm vs. many-in-flight dashboards** — no source of that kind was located.

## Citations

- [https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana](https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana](https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana](https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana) — confidence high
- [https://blume.codes/blog/you-already-told-your-agent-that](https://blume.codes/blog/you-already-told-your-agent-that) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=purple-bluebell](https://product-preview.blume-codes.com/product-preview/?flower=purple-bluebell) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=blue-forgetmenot](https://product-preview.blume-codes.com/product-preview/?flower=blue-forgetmenot) — confidence high
- [https://blume.codes/blog/you-already-told-your-agent-that](https://blume.codes/blog/you-already-told-your-agent-that) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=blue-forgetmenot](https://product-preview.blume-codes.com/product-preview/?flower=blue-forgetmenot) — confidence high
- [https://dev.to/pederaa/i-built-blume-it-turns-your-coding-agent-corrections-into-rules-3oa5](https://dev.to/pederaa/i-built-blume-it-turns-your-coding-agent-corrections-into-rules-3oa5) — confidence high
- [https://dev.to/pederaa/i-built-blume-it-turns-your-coding-agent-corrections-into-rules-3oa5](https://dev.to/pederaa/i-built-blume-it-turns-your-coding-agent-corrections-into-rules-3oa5) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=purple-bluebell](https://product-preview.blume-codes.com/product-preview/?flower=purple-bluebell) — confidence high
- [https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana](https://product-preview.blume-codes.com/product-preview/?flower=orange-lantana) — confidence medium
- [https://blume.codes/](https://blume.codes/) — confidence high
- [https://blume.codes/docs](https://blume.codes/docs) — confidence high
- [https://vibekanban.com/docs/workspaces/interface](https://vibekanban.com/docs/workspaces/interface) — confidence high
- [https://vibekanban.com/docs/workspaces/interface](https://vibekanban.com/docs/workspaces/interface) — confidence high
- [https://vibekanban.com/docs/core-features/reviewing-code-changes](https://vibekanban.com/docs/core-features/reviewing-code-changes) — confidence high
- [https://vibekanban.com/docs/core-features/monitoring-task-execution](https://vibekanban.com/docs/core-features/monitoring-task-execution) — confidence high
- [https://vibekanban.com/docs/cloud/projects.md](https://vibekanban.com/docs/cloud/projects.md) — confidence high
- [https://vibekanban.com/docs/cloud/list-view](https://vibekanban.com/docs/cloud/list-view) — confidence high
- [https://vibekanban.com/docs/getting-started](https://vibekanban.com/docs/getting-started) — confidence high
- [https://vibekanban.com/docs/remote-access](https://vibekanban.com/docs/remote-access) — confidence high
- [https://github.com/BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban) — confidence high
- [https://www.npmjs.com/package/vibe-kanban](https://www.npmjs.com/package/vibe-kanban) — confidence high
- [https://www.conductor.build/docs/reference/checks](https://www.conductor.build/docs/reference/checks) — confidence high
- [https://www.conductor.build/docs/reference/diff-viewer](https://www.conductor.build/docs/reference/diff-viewer) — confidence high
- [https://www.conductor.build/docs/reference/keyboard-shortcuts](https://www.conductor.build/docs/reference/keyboard-shortcuts) — confidence high
- [https://www.conductor.build/changelog/0.44.0-new-sidebar-rebuilt-composer-codex-checkpoints](https://www.conductor.build/changelog/0.44.0-new-sidebar-rebuilt-composer-codex-checkpoints) — confidence high
- [https://www.conductor.build/changelog/0.35.0-workspace-status](https://www.conductor.build/changelog/0.35.0-workspace-status) — confidence high
- [https://www.conductor.build/changelog](https://www.conductor.build/changelog) — confidence high
- [https://www.conductor.build/changelog](https://www.conductor.build/changelog) — confidence high
- [https://www.conductor.build/docs/reference/remote-control](https://www.conductor.build/docs/reference/remote-control) — confidence high
- [https://www.conductor.build/docs/cloud/working-with-cloud-workspaces](https://www.conductor.build/docs/cloud/working-with-cloud-workspaces) — confidence high
- [https://www.conductor.build/changelog.md](https://www.conductor.build/changelog.md) — confidence high
- [https://www.conductor.build/llms.txt](https://www.conductor.build/llms.txt) — confidence medium
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/LICENSE](https://github.com/asheshgoplani/agent-deck/blob/HEAD/LICENSE) — confidence high
- [https://github.com/asheshgoplani/agent-deck](https://github.com/asheshgoplani/agent-deck) — confidence high
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md) — confidence high
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md) — confidence high
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md) — confidence high
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md) — confidence high
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md) — confidence high
- [https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md](https://github.com/asheshgoplani/agent-deck/blob/HEAD/README.md) — confidence high
- [https://github.com/nimbalyst/nimbalyst/blob/HEAD/LICENSING.md](https://github.com/nimbalyst/nimbalyst/blob/HEAD/LICENSING.md) — confidence high
- [https://github.com/nimbalyst/nimbalyst](https://github.com/nimbalyst/nimbalyst) — confidence high
- [https://github.com/nimbalyst/nimbalyst/blob/HEAD/README.md](https://github.com/nimbalyst/nimbalyst/blob/HEAD/README.md) — confidence high
- [https://github.com/paperclipai/paperclip/blob/HEAD/LICENSE](https://github.com/paperclipai/paperclip/blob/HEAD/LICENSE) — confidence high
- [https://github.com/paperclipai/paperclip](https://github.com/paperclipai/paperclip) — confidence high
- [https://github.com/imbue-ai/sculptor](https://github.com/imbue-ai/sculptor) — confidence medium
- [https://github.com/omnara-ai/omnara](https://github.com/omnara-ai/omnara) — confidence high
- [https://github.com/manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — confidence high
- [https://vibekanban.com/docs/settings/general](https://vibekanban.com/docs/settings/general) — confidence high
- [https://github.com/hyldmo/conductor-remote](https://github.com/hyldmo/conductor-remote) — confidence high
- [https://github.com/hyldmo/conductor-remote](https://github.com/hyldmo/conductor-remote) — confidence high
- [https://github.com/hyldmo/conductor-remote](https://github.com/hyldmo/conductor-remote) — confidence high
- [https://github.com/hyldmo/conductor-remote](https://github.com/hyldmo/conductor-remote) — confidence high
- [https://pushary.com/vs/conductor](https://pushary.com/vs/conductor) — confidence medium
- [https://github.com/deathemperor/infinitus/issues/129](https://github.com/deathemperor/infinitus/issues/129) — confidence medium
- [https://www.onorca.dev/](https://www.onorca.dev/) — confidence medium
- [https://blume.codes/](https://blume.codes/) — confidence medium

## Unverified (as reported by the job)

- {"topic": "Blume's Deliveries and Projects screen layouts (fleet grouping, sorting, empty state, incident banner, density mode, in-place expansion, triage view)", "url": null, "reason": "The official preview renders each screen only as a PNG and the fetch returns only the Improve screen's text DOM, so the pixel layout of the other screens could not be read; no published screenshot, doc or changelog shows their layout. (The page itself WAS retrieved elsewhere in this run and backs citations \u2014 this entry records an unverified topic, not an unusable source.)"}
- {"topic": "Blume blog post 'How Blume codebase improvements work' (15 Jul 2026), which appears to describe the Improve row's Configure control", "url": "https://blume.codes/blog/how-blume-codebase-improvements-work", "reason": "Only a search-result snippet was seen; the page itself was never fetched, so its layout detail cannot be cited."}
- {"topic": "Paperclip's built UI surfaces, state model, grouping level and notification handling", "url": "https://github.com/paperclipai/paperclip/blob/HEAD/README.md", "reason": "Not retrieved \u2014 only the LICENSE and GitHub API metadata were read, so no screen-level claims about Paperclip are made."}
- {"topic": "Sculptor's UI surfaces and its self-described licence caveat", "url": "https://github.com/imbue-ai/sculptor/blob/HEAD/README.md", "reason": "Not retrieved \u2014 only repo metadata was read. The 'we know it's not truly open source' line is a search snippet only, so the licence claim stays at medium confidence."}
- {"topic": "Sculptor licence file (SPDX text)", "url": "https://github.com/imbue-ai/sculptor/blob/HEAD/LICENSE", "reason": "No file at path LICENSE on the default branch, while GitHub metadata reports MIT \u2014 the licence string cannot be confirmed from in-repo text."}
- {"topic": "Omnara's own feature/docs pages (dashboard screens, mobile apps, Apple Watch, push behaviour)", "url": "https://www.omnara.co/features", "reason": "HTTP 451 Unavailable For Legal Reasons on every fetch path; Omnara screen claims therefore rest on a third-party survey issue only."}
- {"topic": "Conductor pricing, plan tiers and an explicit closed-source statement", "url": "https://www.conductor.build/markdown/pricing", "reason": "Page text was not readable; licence/commercial status is inferred only from the docs index listing Pricing/Enterprise/Teams pages."}
- {"topic": "Conductor v0.85.0 'Sections, routines, and a new model picker' \u2014 sidebar density/section behaviour", "url": "https://www.conductor.build/changelog/0.85.0-sections-routines-and-a-new-model-picker", "reason": "Only the changelog index title was seen; the page body was never read."}
- {"topic": "Vibe Kanban 'Creating Tasks' page (task panel and attempt list)", "url": "https://www.vibekanban.com/docs/core-features/creating-tasks", "reason": "Fetch returned a truncated raw Mintlify JSON payload; the page body was not read."}
- {"topic": "Published design patterns for situation-adaptive agent dashboards (calm vs single-incident vs many-in-flight)", "url": null, "reason": "No source of that kind was located or read; no product publishes explicit calm/incident/many-in-flight layout design writing, so the adaptive-layout section rests on changelog-borne mechanics and inference."}
- {"topic": "Screenshot-level verification of any of these UIs", "url": null, "reason": "Docs screenshots are images and were not visually inspectable; all layout claims come from prose descriptions and changelog text, not from viewing pixels."}
- {"topic": "The name 'agent-deck' is not unique \u2014 helderme/agentdeck, brushknight/agents-deck and claude-world/agent-deck are separate projects", "url": "https://github.com/helderme/agentdeck", "reason": "Search snippets only; those repositories were not fetched, so no screen-pattern claim about them is supported."}
- {"topic": "agent-deck's Fleet board section and README content past 80,000 characters", "url": "https://raw.githubusercontent.com/asheshgoplani/agent-deck/HEAD/README.md", "reason": "The verbatim read was truncated at 80,000 of 90,478 characters mid-sentence in the Fleet board paragraph."}
