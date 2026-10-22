# Spike 05: artifact review (plannotator Inbox, a review service, human-review)

Status: spike result, input to the artifact-review ADR (`../../adr/`). Date: 2026-10-22. Time box: 2 h.
Scratch tree: `~/.local/share/factory/spikes/05-review/` (not committed). Everything here re-runs with `scripts/run-all.sh`.

## Context and problem statement

The factory produces plans, reports and diagrams: Markdown mostly, sometimes standalone HTML (archify diagrams). The owner
reviews them when he has time and decides business questions only (target at most 0.1 % of items). Constraints that came with
the brief and from the owner's earlier discussion (findings-2026-10-22.md, "Artifact review"):

- Review is never a blocking gate. Comments are a signal. An agent that asked proceeds on timeout with a default it stated.
- Comments reach agents as data (API, file, CLI output), durably, not as pasted chat.
- One inbox across sessions and projects, grouped by project. He likes plannotator's.
- Argo is the per-project dashboard and has to show reviews. He also wants to use this from the phone over the tailnet.
- The security boundary (tailnet plus his GitHub identity) is fixed and is not argued here.
- One system of record per entity, one event log, delete before adding.

Question: which review surface, and which contract between that surface and the agents?

## Decision drivers

1. Markdown first, HTML second. 2. Inbox across projects and sessions, attention-ordered. 3. Comments anchored to quoted text, with
threads and resolution. 4. Durable, readable by agents through an API, a file or a CLI, across restarts of tool and agent.
5. Never a gate: bounded waits, a default on timeout, late comments still land. 6. Argo integration (embed or API).
7. Phone usability over the tailnet. 8. Ops cost, licence, maturity and churn, exit cost.

## Considered options

- **A. plannotator 0.28.26** (backnotprop/plannotator; one release binary; MIT OR Apache-2.0). Two surfaces: `annotate` (a blocking
  review gate per file) and the **Inbox** (one window per machine where agents leave messages, questions and attachments).
  The earlier research (2026-10-21) described `annotate` and called the Inbox "MCP: Inbox only". The Inbox turned out to be the point.
- **B. The review service sketched on 2026-10-21.** Bun plus SQLite plus a per-repo docs dir; `rv submit` and `rv wait`
  (blocking long poll returning `feedback`, `closed`, `superseded` or `timeout`, acknowledged delivery); comments anchored to quoted
  text with threads and resolve; project-grouped inbox; Mermaid in v1; Argo as the dashboard. Built here as a 97-line prototype plus a spec.
- **C. petergyang/human-review 0.8.2** (MIT, one runtime dependency). `human-review <file>` opens a browser review; `human-review poll`
  blocks until the owner presses Send. The sketch's `rv wait` contract mirrors its `poll` contract one to one (feedback, closed, superseded, timeout, ack).

## Criteria matrix

Ratings: yes, partly, no, build (we would have to build it). Evidence for every cell is in "Observed behaviour".

| Criterion | A. plannotator 0.28.26 | B. review service (build) | C. human-review 0.8.2 |
|-|-|-|-|
| Markdown | yes. A comment on a selected phrase reached the agent as `(lines 79-80) Feedback on: "..."` | build (marked plus own anchoring) | yes. Selection comments carry quote plus prefix and suffix; element comments carry a label plus CSS selector |
| HTML | yes. Raw page in a sandbox with an Annotate mode; the archify diagram renders (webfont blocked by the page CSP) | build, the hardest part (sandboxed frame plus injected annotator) | yes. Rendered with an injected SDK; edits to plain HTML autosave into the file itself |
| Inbox | yes. Project sidebar, six attention sections, search, drafts, archive | build (about 400 lines of UI); prototype has the grouped query | no. One server, per-target sessions, every list route answers 404 |
| Project grouping | yes. Git root, worktrees fold into the repo (checked); else the folder | yes. Manifest slug | no |
| Durable comments, agent read-back | yes. Append-only JSONL, versioned envelope, global sequence; survives SIGKILL; MCP stdio and HTTP (`wait_for_reply`, `read_thread`, `search`) or plain files | yes. SQLite; 14 of 14 checks including two SIGKILLs | yes. Atomic `state.json`; survives SIGKILL; `status` works with the server dead |
| Non-blocking (timeout plus default) | yes in the Inbox: `wait_for_reply` returns `waiting` after at most 50 s. `annotate --gate` blocks forever (no timeout flag; tab closed means `dismissed` after 30 s) | yes. `rv wait --timeout --default` | partly. `poll --timeout` works, but a review nobody opens is closed after 60 to 120 s and the agent is told to stop |
| Argo integration | partly. Link out only (framing denied); data by JSONL tail, loopback window API or MCP over HTTP | yes. Same store, API and components | no |
| Phone | partly. Responsive at 390 px, no overflow, question cards fit; comment targets are 28 px; the vendor tailnet path refuses tagged devices (this host and the phone are tagged), so a door of our own is needed | build and own | no. The document column collapses to 38 px at 390 px |
| Ops cost | one 143 MB binary, no dependencies, 50 to 135 MB resident, started by the first agent call; the phone door adds a LaunchAgent, a Caddy block and a heartbeat; version pins to maintain | service, LaunchAgent, Caddy block, heartbeat, backup; 2.2 to 2.8k lines to own | `npx` per call; detached server exits after 45 min idle; nothing durable as a service |
| Licence | MIT OR Apache-2.0 (the GitHub field says Apache-2.0 only) | ours | MIT |
| Maturity, churn | 9.6k stars; 34 releases in 30 days; one maintainer (1,616 commits, next contributor 18) | n/a | 1.4k stars; 8 releases, none since 2026-09-17; one author (50 commits) |
| Verdict | adopt, behind an owned contract | do not build now; build only on a tripwire | reject as a surface; copy ideas |

A wins every row that is expensive to build (inbox, HTML, anchoring UI, phone layout), loses two rows that are cheap to fix with glue
(Argo embed, phone door), and is the only existing option designed for asynchronous, away-from-keyboard review. C fails inbox, phone and
the "nobody answers" semantics. B is the right shape for the contract and the wrong thing to build as a UI.

## Observed behaviour

### Method and isolation

Every run used the scratch tree only. plannotator is the release binary (sha256 checked) run through `scripts/pn`: `HOME` and the data dir
inside the scratch tree, no browser, update check and auto-update off, agent auto-connect off, share portal off, tailnet publication off,
local mode forced. human-review is `human-review@0.8.2` from npm with a local prefix and lifecycle scripts off, run through
`scripts/hr` (its `open` call is shimmed, so no browser starts). All listeners were on loopback (fixed ports 39201 to 39221, plus the
Inbox's own port), every process was stopped at the end, and the real-home footprint was checked before and after:
no plannotator mention in `~/.claude.json`, `~/.claude/settings.json`, Codex or OpenCode config, no `~/.plannotator`,
no `~/.human-review`, no rule file or binary installed, and no tailnet serve mapping points at a scratch port (`evidence/summary.txt`).
The artifacts under review are copies of `BRIEF.md` and of the archify diagram `episode-lifecycle.html` (712 KB, four scripts, inline SVG).
Two runs used a real browser through the DevTools protocol (desktop 1280 x 800 and an emulated 390 x 844 touch phone); their agent-side
read-back is stored. Timings are from this machine and are indicative.

### A. plannotator 0.28.26

| ID | Exercise | Observed | Evidence |
|-|-|-|-|
| P1 | `annotate BRIEF.md --gate --json --result-file` from project folder proj-alpha; nobody answers; then feedback is posted | Blocks until someone decides: no timeout and no flag for one (still alive after 6 s here and for 50 s or more in manual runs; the Claude Code hook entry carries a 4-day timeout). On feedback it prints `{"decision":"annotated","feedback":"<markdown>"}` to stdout and to the result file (identical), then exits. Before exiting it appends the full structured annotations to `feedback/proj-alpha/index.jsonl` and writes `records/<ts>-annotate-feedback.md` plus a copy under `history/`. The result file refuses to overwrite an existing one | `plannotator-exercise.log` P1 |
| P2 | `annotate` on the HTML diagram, save a draft, SIGKILL, run the same command again | Rendered raw (`renderAs: html`). The blocked call just dies with empty stdout. The draft is on disk and returns when the same command is re-run. `plannotator sessions` lists live review sessions only | P2 |
| P3 | Open the review, close the tab (the lease stream drops), no decision | `{"decision":"dismissed"}` 31.5 s later (30 s grace). A review nobody ever opens never ends | P3 |
| I1 | Inbox: three messages from three agent sessions in two projects; two attachments (Markdown and HTML); a question with `Recommended:`, one with `Holds up:`. Agent waits 3 s; the "human" picks and replies through the window API; agent waits again | Two projects; sections Holding up work, Waiting on you, New since you looked; attachments detected as `markdown` and `html`. `wait_for_reply` returned `{status: waiting, cursor}` at its 3 s deadline (4.4 s including about 3.5 s of stdio start-up) and, after the reply, `replied` with the answer text ("Answer: Event log first (your recommendation)") | I1, `inbox-list.json` |
| U1 | Real browser, desktop: open the thread and the attached `BRIEF.md`, select a phrase, Comment, type, Send | The selection toolbar needs a `selectionchange` (a synthetic `mouseup` cleared the selection). The comment sits in a Draft until Send. After Send the UI says "Saved for An agent. It sees it when it next reads this thread" (no wake for an MCP-only agent). The agent receives the words, the file path, line numbers and the quote | `real-ui-inbox-readback.txt` |
| I2 | SIGKILL the Inbox; the next agent call restarts it; `read_thread` | The person's reply is there; new process; same port as before (not promised by the docs). Records are `{v:1, seq, at, kind, id, record}` with a global `seq` across files | I2 |
| I3 | Agent in a git worktree of a repo vs the main checkout | Same project id: worktrees fold into the repository | I3 |
| I4 | The door | Foreign `Host` refused (403). Framing denied (`X-Frame-Options: DENY`, `frame-ancestors 'none'`). Streamable-HTTP MCP works statelessly with explicit `project_path` and `agent_session`; a request carrying an `Origin` is refused. With `PLANNOTATOR_ALLOWED_HOSTS=<door host>` the window answers that host, other hosts stay 403, and `/mcp` still refuses the proxied host | I4 |
| U2 | Phone (390 x 844, touch): list, thread, question card, attachment viewer | No horizontal overflow (one inline code span spills 25 px inside the document scroller). Project navigation is a drawer behind "Toggle Sidebar" (44 px rows). The notification prompt takes a fifth of the list. Viewer toolbar on top, floating dock at the bottom; the Comment button is 28 x 28 CSS px | `shots/inbox-phone-list.png`, `inbox-phone-viewer.jpg` |
| U3 | HTML attachment in the viewer | The archify sequence diagram renders, with Annotate mode, a comment counter and a file switcher. One console error: the page's webfont is blocked by the Inbox CSP, so a fallback font is used. The viewer bar overlays the diagram's own toolbar | `shots/inbox-html-attachment.jpg` |
| T | Tailnet identity (read only) | This host and the one iOS peer are tag-owned. The vendor path (`inbox --tailscale`) lets in only the login that owns the machine and answers tagged peers 403 (`tailnet_identity_required`); a tagged machine has no owner and needs `inboxTailscaleAllow` set. Not exercised: it would publish a serve mapping | T, vendor docs, `packages/shared/inbox/tailnet.ts` |

Other facts: the Inbox MCP surface is 7 tools and 23,069 bytes of definitions (about 5.8k tokens if registered as MCP;
`inbox-mcp-size.json`), which is why the adapter below talks to it without registering it. Mermaid fences render in the Markdown
viewer (a `MermaidBlock` component is bundled; source reading, not exercised). The vendor's `adr/implementation/inbox-mobile.md` describes a
native iPhone app, a LAN listener and a hosted relay; none of it is documented as shipped. Idle memory 50 to 135 MB resident.

Evidence IDs (P1, I2, T) are sections of `evidence/plannotator-exercise.log`; U rows are the two real-browser runs.

What an agent gets back, in each of the ways A offers:

- Blocking `annotate --gate --json`: stdout and `--result-file`, one JSON object with the feedback as Markdown.
- Files: `feedback/<project>/index.jsonl` (gate decisions) and `inbox/projects/<name>-<hash>/{messages,questions,annotations}.jsonl`.
- MCP over stdio or loopback HTTP: `wait_for_reply` (50 s chunks), `read_thread` (with a cursor for "only what is new"), `search`.
- A wake-up message into an interactive Claude Code session through the plugin (documented, not exercised).

### C. human-review 0.8.2

| ID | Exercise | Observed | Evidence |
|-|-|-|-|
| A | `human-review BRIEF-a.md`, then `poll` with defaults; nobody opens the page | `{"status":"closed","reason":"window_closed"}` with the instruction "Stop waiting, do not run the poll command again": after 120 s in the first run and 60 s in the re-run (a session no tab connected to within 60 s is dropped by a sweep that runs every 60 s, so it races the threshold). Not a timeout and not "proceed": the agent is told to stop | `human-review-exercise.log` A |
| B | Selection comment and element comment, Send, `poll` | `poll` returned 0.01 s after Send with `status: feedback`, each comment's `quote` plus `anchor {prefix, quote, suffix}` (or `{selector, label}` for elements), `overall_note`, and a `next_step` text addressed to the agent. `--ack` and then a bounded poll returned `timeout`, not a replay | B |
| C1 | Unsent comment, SIGKILL the server | `status` with the server dead reads `state.json` and reports the unsent comment; re-open reports `leftover` | C1 |
| C2 | Send, SIGKILL before the agent polls | `status` says feedback is waiting; a fresh `poll` delivers the batch including the earlier draft | C2 |
| E | Any list or inbox route | Every list route answers 404: one server, per-target sessions, no inbox | E |
| U4 | Real browser, desktop: load, comment, Send | The page renders in an iframe sandboxed with `allow-scripts allow-forms allow-modals` (no same-origin), so the automation could not build a text selection there; an element comment was used. After Send the UI says "Sent, agent is not listening" and shows the poll command to paste. The poll read it back | `real-ui-human-review-batch.json` |
| U5 | Phone (390 x 844, touch) | The document column is 38 px wide next to a 351 px feedback rail; the title letters stack vertically; touch targets are 18 to 30 px | `shots/human-review-phone.png` |
| U6 | HTML diagram | Renders with its SDK injected; toolbar Dark, Classic, Present, Export. Plain HTML files autosave edits into the file; self-rendering pages do not (`edits_saved: false`) | |

Evidence letters (A to E) are sections of `evidence/human-review-exercise.log`; U rows are the two real-browser runs.

Other facts: Markdown is rendered with `marked`; Mermaid fences render in the browser from a pinned CDN build (needs internet at
view time). One server per machine on a random or fixed loopback port, token header required on every API route and a strict `Host`
check. The server exits after 45 minutes idle; state is pruned after 30 days. Idle memory 25 to 65 MB resident.

### B. Review service: spec, prototype, effort

**Data model** (SQLite, one file, WAL).

| Table | Columns | Notes |
|-|-|-|
| project | slug (PK), repo_path | slug comes from the project manifest; groups the inbox |
| artifact | id (PK), project, path, rev, sha256, kind (md or html), status (open, superseded, closed), created_at | one open revision per (project, path); identical content resubmitted is a no-op; changed content creates rev+1 and supersedes the open revision |
| comment | id (PK), artifact_id, parent_id, quote, prefix, suffix, body, author (human or agent), created_at, resolved_at, acked | anchor is a W3C TextQuoteSelector: the quote plus about 32 characters of context each side; a thread is the parent chain; comments are resolved, never deleted |
| event | seq (PK, autoincrement), at, kind, artifact_id, comment_id, payload | append-only outbox for the factory event log: artifact.submitted, artifact.superseded, comment.added, comment.resolved, feedback.delivered, feedback.acked, artifact.closed |

State machines: artifact `open -> superseded | closed`; comment `open -> resolved`; delivery `pending -> delivered -> acked`. Feedback that
was delivered but not acked is redelivered (at least once; comment ids make handling idempotent). Invariants: feedback is delivered
before any terminal status; a wait never outlives its caller's deadline (the server answers in chunks of at most 25 s and the client
loops, which also hides a server restart from the waiting agent); on supersede, unresolved comments move to the new revision when their
quote still matches exactly once and are otherwise marked outdated.

**HTTP API** (loopback, JSON).

| Call | Purpose |
|-|-|
| `POST /artifacts {project, path}` | `rv submit`; returns `{id, rev, unchanged?}` |
| `GET /artifacts/:id/wait?timeout=&ack=` | long poll; returns `{status, comments, cursor}` with status `feedback`, `closed`, `superseded` or `timeout`; `ack` acknowledges everything up to a cursor |
| `POST /artifacts/:id/comments` | `{quote, prefix, suffix, body, parent_id, author}` from the UI, an agent reply or a scripted stand-in for the human |
| `POST /comments/:id/resolve`, `POST /artifacts/:id/close` | resolve a comment; end a review |
| `GET /inbox` | project-grouped rows with open comments and undelivered feedback |
| `GET /events?after=<seq>` | the outbox for the projector (specified, not in the prototype) |

CLI: `rv submit <project> <file>`, `rv wait <id> [--timeout s] [--default text] [--ack cursor]`, `rv comment | resolve | close | inbox`.
`wait` exits 0 on timeout and prints the caller's default, so an unanswered review is a normal outcome and never a failure.

**Prototype.** `rv/rv.ts` is 97 lines of Bun and `bun:sqlite`; `rv/rv-demo.sh` runs 14 checks and all pass: a blocking wait is released
by a quote-anchored comment about 0.3 s after it lands; unacked feedback is redelivered and acked feedback is not; after the ack the
wait gives up on its deadline and prints the agent's default (3.1 s for a 3 s deadline); SIGKILL of the server twice (a new pid owns
the port each time, asserted), once with a wait in flight, which still receives the comment posted after the restart; a resubmitted
changed file supersedes and releases the old waiter; close releases the waiter; identical resubmits are idempotent; the grouped inbox
query returns rows per project.

**What finishing it takes.** Sizes are lines of TypeScript, TSX and CSS, tests excluded; they are estimates, not measurements.

| Component | Size | Risk |
|-|-|-|
| Store, API, supersede with re-anchoring, event outbox (the prototype grown up) | 300 | low; the prototype is the proof |
| `rv` CLI with a `--json` schema for the generated AGENTS.md routing block | 150 | low |
| Markdown renderer (marked) with stable block ids, sanitising, bundled Mermaid | 150 | low; human-review loads Mermaid from a pinned CDN build, which fails offline |
| HTML artifact frame: sandboxed iframe plus an injected annotator over postMessage | 250 | high; archify pages rewrite their own DOM and ship their own toolbar |
| Anchoring UI: selection to TextQuoteSelector, highlights, re-anchoring after edits, popover, thread panel, resolve | 600 to 800 | high; the part the vendor spent months on; iOS touch selection is the sharp edge |
| Inbox UI: project groups, attention sections, search (SQLite FTS5), phone layout, notifications | 400 to 500 | medium; notifications on iOS likely need a home-screen app (to verify) |
| Argo Reviews panel (basalt-ui) and read-model endpoints | 150 to 250 | low if Argo moves to the mini, medium across hosts |
| Ops: LaunchAgent, Caddy block, heartbeat, `.backup` job, architecture.md entries | about 100 of config | low |
| Tests: boundary tests through the API, browser tests for selection anchoring | 300 | medium |

Total 2.2 to 2.8k lines, roughly three waves. The contract and the event outbox are the cheap 20 %; the anchoring and phone UI are the expensive 80 %.

### A behind the contract (adapter experiment)

Question: can the sketch's contract sit on top of the Inbox, so agents and AGENTS.md never learn vendor tool names and no 23 KB of
tool definitions enters a context? `rv/rv-pn.ts` is 51 lines of Bun. It speaks Streamable-HTTP MCP to the loopback Inbox (port read
from the registry file), starts the Inbox when it is down, and maps: `send_message` (thread named by the file path, file attached,
idempotency key from path plus content plus default) to `submit`; `wait_for_reply` in chunks of at most 50 s to `wait`, with
`replied` as `feedback`, `acknowledged` (thumbs-up) as `approved`, `resolved` as `closed` and the deadline as `timeout` plus the caller's
default. `rv/rv-pn-demo.sh` passes 6 of 6: identical resubmit replays; a 4 s bounded wait returns the default after 4.1 s; a reply typed
by the "human" arrives as `feedback`; SIGKILL of the Inbox while the agent waits, after which the adapter restarts it (about 2 s) and
still delivers the reply. Gap: `superseded` has no Inbox equivalent for files (it supersedes questions); the adapter can derive it by
comparing the thread's newest agent message with the one the wait started from (not built).

## Corrections to the 2026-10-21 research

The research report (`../../research/2026-10-21-review-tools.md`) was right about the field and stale on three points that change the decision.

1. "No documented endpoint an agent can poll for a finished plan review's comments; MCP is Inbox only." The Inbox is a complete agent
   inbox: `send_message`, `read_thread`, `wait_for_reply`, `search`, `resolve_message`, over stdio and Streamable HTTP, with durable
   append-only storage. `annotate --gate` also writes each decision to `feedback/<project>/` before it exits (P1).
2. "Comments die with the session." True only for external annotations. Submitted decisions and Inbox messages, questions and
   annotations are on disk and survive SIGKILL (P1, I2).
3. "`--tailscale` is never added by hooks, so hook reviews are phone-invisible." The sharper blocker for this tailnet is that the
   vendor tailnet path admits only the Tailscale login that owns the machine and refuses tagged devices; this host and the phone are tagged (T).

Also: 0.28.25 was current on 2026-10-21 and 0.28.26 shipped the next morning, and `human-review`'s workflow, listed as unverified, is
now verified (live-tab model, section "C").

## Decision outcome

**Chosen: A behind an owned contract.** Adopt the plannotator Inbox as the review surface. Own the three-verb `rv` contract
(`submit`, `wait`, `status`) as the only thing agents and AGENTS.md know. Feed Argo and the reconcilers from the Inbox's JSONL through a
projector into the factory event log. Do not build B's UI and store now. Reject C as a surface.

**Confidence: 70 %.** 90 % that C is out. About 70 % that adopting A beats building B over twelve months. The 30 % is single-maintainer
churn (34 releases in 30 days), the stability of the phone door across a reboot, and whether the owner's real phone use needs more than
questions and thumbs-up.

Why:

1. The expensive 80 % of B (anchoring UI, HTML frame, inbox, phone layout) exists in A and was exercised end to end: a real-UI comment
   became agent-readable text with its line numbers, the phone viewport has no overflow, the archify diagram renders.
2. The cheap 20 % that matters to the factory (the contract and the event outbox) is 50 to 100 lines and stays ours; `rv-pn.ts` shows A
   can sit behind it, crash included.
3. A is non-blocking by design: nothing holds a session; the answer is pulled or arrives as a message; `Recommended:`, `Stopped:` and
   `Holds up:` are first-class and answer Argo's question "what needs me, and what happens if I ignore it".
4. Exit is cheap: append-only JSONL with a versioned envelope and a global sequence, plus the contract being ours.

How a review flows (target, all non-blocking):

1. The producer runs `rv submit <project> <file> --default "<what I do if nobody answers>"`. It returns at once with a thread id. The
   AGENTS.md rule is: submit and continue; `rv wait` only when a business decision is genuinely needed, and always bounded.
2. The owner reads in the Inbox (Argo links to the thread), comments on a quote, picks an option, presses thumbs-up, or marks it read.
3. Delivery: pull with `rv wait <thread> --timeout N` or `rv status --project P`; push into an interactive Claude Code session through the
   vendor plugin (documented, not exercised here); and a reconciler path: a projector tails `inbox/projects/*/*.jsonl` by `seq` into the
   event log as `review.*` events, a level-triggered rule opens Condition `review_feedback_unhandled` when a person message is newer than
   every agent read, and routes it to the mother or lead that owns the artifact. A late answer after a default was applied becomes
   `review.late_feedback`, never a stop.
4. Identity: the adapter passes `agent_session = <project>/<role>` so a thread survives agent restarts (the Inbox otherwise binds a reply
   to the sending session). Project is the repository root; worktrees fold in.
5. Argo shows a Reviews panel per project from the log (open threads, Stopped, Holds up, "sent, unread by any agent") with an "Open in
   Inbox" link to the door. No iframe.

Consequences, good: no UI to build; the owner keeps the inbox he likes; project grouping and worktree folding come free; durable by
construction. Bad, and what we do about it:

- One maintainer, daily releases. Pin the binary by checksum, keep `PLANNOTATOR_UPDATE_CHECK=0` and auto-update off, bump through a make
  target that runs the adapter and projector contract tests first (the collie pin is the precedent).
- Phone path. The vendor `--tailscale` path refuses tagged devices, so the door is ours: a supervised Inbox (LaunchAgent), a Caddy block
  and `PLANNOTATOR_ALLOWED_HOSTS` for the door host. Tested locally with Host headers (I4); the port was the same across restarts in every
  run here but the docs promise nothing, so the heartbeat compares Caddy's upstream with the registry file. The agent door `/mcp` stays loopback.
- Wake-on-reply exists only for interactive Claude Code sessions with the plugin. Headless agents pull; orphaned replies go through the reconciler.
- One Inbox per machine and the agent door answers only on that machine. Agents on the MacBook cannot use the mini's Inbox without a tunnel; the factory is mini-centred, so accepted.
- No iframe in Argo (framing denied): counts and links only.

**Tripwires to build B instead** (three waves; data imports from the JSONL): a version bump breaks the adapter or projector twice in a
quarter; the door cannot be kept stable across a reboot, or the owner's real phone tasks need what the phone UI lacks (28 px comment
targets, touch selection untested); Argo needs per-comment read models the JSONL cannot give; no release for 45 days or a licence change.

Follow-ups, not decided here: `rv` CLI with a pinned install and contract test; Inbox LaunchAgent, door, heartbeat and architecture.md
entry; JSONL projector, Argo Reviews panel and the reconciler rule.

**Confirmation.** The decision holds while three checks pass: `rv/rv-pn-demo.sh` (the contract test) against every pinned plannotator
version before a bump; the projector replays the JSONL from `seq` 0 and reproduces the Inbox's per-project counts; and `make doctor`
finds Caddy's upstream equal to the registry port with the Inbox answering its health route.

## What to copy from the rejected options

From C (human-review), whichever way the ADR lands:

- The `poll`, `status` and `--ack` contract and its four outcomes `feedback`, `closed`, `superseded`, `timeout`: this is `rv`.
- An "agent listening" indicator: the review UI says "Sent, agent is not listening" and prints the command to start a poll. Argo should
  show "sent, unread by any agent" the same way, so silence is never mistaken for being read.
- The anchor triple `{prefix, quote, suffix}` (a W3C TextQuoteSelector) and the 3.6 KB MIT `anchor-text.js` behind it, if B is ever built.
- `status` that works from the state file while the server is dead; atomic tmp-and-rename state writes; pruning after 30 days; idle exit.

From B (the sketch), kept as the owned layer: the `event` outbox with a sequence cursor; `superseded` as a first-class outcome for
waiters (the Inbox has none for files); `--default` on `wait`.

From A, as vocabulary for our own schemas even where we do not use its code: question fields `Recommended:`, `Stopped:`, `Holds up:`,
`Replaces:`; `supersedes`; idempotency keys; thumbs-up as "read, no reply needed"; Mark read as "set aside, do not wait on these" delivered
to the agent; a content-addressed copy of the version sent next to the file as it is now; append-only JSONL with a global sequence as an event source.

## Not verified, residual risk

- The Claude Code wake path (plugin, version 2.1.287 or later, interactive sessions only). Plugins were off limits for this spike.
- Real touch selection on an iPhone. The UI runs used synthetic selections and an emulated viewport; comment targets measured 28 px.
- Port stability of the Inbox across a reboot and under launchd (stable across process restarts in every run here).
- HTML comment anchoring on an interactive page (rendering and the Annotate mode were checked, a saved comment was not).
- Scale: the Inbox sets no size limits and the JSONL grows; no test beyond a handful of threads.
- plannotator's native iPhone app and its hosted relay: the repository contains the relay and the wire contract but the app is not
  publicly documented as shipped; a third-party relay was out of scope. `plannotator review` (diff review) was out of scope.
- The Inbox's `external annotations` API and Obsidian hand-off.

## Reproduce

```sh
scripts/run-all.sh             # about 8 minutes: setup if missing, the four exercise scripts, evidence logs, summary and footprint check
scripts/plannotator-exercise.sh   # option A (about 4 minutes); run the others the same way:
scripts/human-review-exercise.sh  # option C (about 3 minutes)
rv/rv-demo.sh                     # option B prototype, 14 checks
rv/rv-pn-demo.sh                  # the contract on the Inbox, 6 checks
scripts/churn.sh                  # maturity numbers from GitHub and npm
```

`scripts/setup.sh` installs into the scratch tree only: the plannotator release binary (sha256 sidecar verified) and `human-review@0.8.2`
through npm with a local prefix, lifecycle scripts off and the private registry config bypassed. The two UI runs (a real browser driven
over the DevTools protocol, desktop and an emulated 390 x 844 phone) are not scripted; their agent-side read-back is stored in
`evidence/real-ui-*`.

## Evidence index

| File | What it holds |
|-|-|
| `evidence/plannotator-exercise.log` | P1 to P3, I1 to I4 and T for option A |
| `evidence/human-review-exercise.log` | A to E for option C |
| `evidence/rv-demo.log`, `evidence/rv-pn-demo.log` | the 97-line prototype (14 checks) and the adapter on the Inbox (6 checks) |
| `evidence/inbox-list.json`, `evidence/inbox-mcp-size.json` | the Inbox list model (projects and sections) and the MCP definition size |
| `evidence/real-ui-inbox-readback.txt`, `evidence/real-ui-human-review-batch.json` | what each tool's agent side received after a real-browser comment |
| `evidence/shots/` | desktop and phone screenshots (downscaled) |
| `evidence/churn.txt` | maturity numbers from GitHub and npm metadata |
| `evidence/summary.txt`, `evidence/setup.txt` | pass and fail counts per log with the footprint check, and the installed versions with checksums |
| `scripts/`, `rv/` | wrappers, exercise scripts, the prototype and the adapter |
