# Archive: cq Task Queue Feature (removed 2026-05-18)

The per-repo task queue (`sc-queue.md` + `cq` CLI + Stop-hook injection +
`cqueue/` web dashboard) was ripped out of `dotfiles` on 2026-05-18.
Sideclaw kept the queue code, but it is gated off behind
`SIDECLAW_QUEUE_DISABLED=true` / `VITE_SIDECLAW_QUEUE_DISABLED=true`.

This doc preserves everything needed to bring it back without scavenging git.

## How to restore

1. **Surgical removals here** — copy each block below back into the listed file.
2. **`cqueue/` web dashboard** (~40 files, full Bun/React app) — recover with
   `git show <pre-removal-commit>:cqueue/<path>` or `git checkout
   <pre-removal-commit> -- cqueue/`. The pre-removal HEAD at the time of writing
   was `bf43fda` (`feat(caddy): reverse-proxy metabase.iu-aws.de via prometheus
   VPN sidecar`) — so the removal commit will be `bf43fda+1`.
3. **Sideclaw gate** — unset (or remove) `SIDECLAW_QUEUE_DISABLED` and
   `VITE_SIDECLAW_QUEUE_DISABLED` in `~/SourceRoot/sideclaw/.env`, then
   `make reload`. The queue routes, panel, SSE watcher, and DB table are all
   still present, just short-circuited.

---

## docs/cq.md (deleted)

````markdown
# cq — Claude Code Task Queue

## What It Is

`cq` is a per-repo task queue that automates unattended multi-task Claude Code sessions.
When Claude finishes a task (Stop event fires), the `notify.ts` hook pops the next block
from `queue.md` at the repo's git root and injects it as the next user message via exit
code 2 — keeping the session alive without babysitting the terminal.

**Planned rename:** `queue.md` → `cqueue.md` (more explicit, avoids collision with project queue files).

## Files

| File | Location | Purpose |
|-|-|-|
| CLI | `~/.claude/queue.ts` | `cq` command — add, list, pop, clear, stop |
| Queue file | `{git-root}/queue.md` | Per-repo task list |
| Stop hook | `~/.claude/hooks/notify.ts` | Pops tasks and injects them on Stop |
| Shell alias | `~/.zshrc` | `alias cq="bun ~/.claude/queue.ts"` |

## Queue File Format

Human-editable Markdown at `{git-root}/queue.md`. Tasks separated by `---`.

```markdown
# Claude Queue

/commit --split
---
Implement unit tests for the auth validators.

Focus on edge cases for token expiry.
Relevant: src/auth/validators.ts
---
/check
---
STOP
---
Write CHANGELOG entry
```

### Block Types

| Block | Icon | Behavior |
|-|-|-|
| Lines starting with `/` | ⚡ | Injected as slash command → triggers skill |
| Plain text | ◆ | Injected as user message |
| `STOP` exactly | ⏹ | Ends queue processing — session stops |

**Rules:**
- `#` lines at the very top = file-level comments, ignored by parser
- Blocks can be arbitrarily multi-line (paste links, code, context)
- Last block doesn't need a trailing `---`
- Parser splits on `\n---\n` and trims each block

## CLI Reference

```bash
cq add "text"     # Append single-line task
cq add            # Append multi-line task via stdin (Ctrl+D)
cq edit           # Open queue.md in $EDITOR
cq list           # Show all tasks with index, icon, preview
cq pop            # Print + remove first task (used by Stop hook internally)
cq status         # One-line pending count
cq clear          # Empty the queue
cq stop           # Append STOP sentinel at end
cq help           # Usage reference
```

## Stop Hook Mechanics

The relevant section in `~/.claude/hooks/notify.ts` (inside `handleStopEvent`):

```typescript
const queueFile = findQueueFile(input.cwd);
const nextTask  = queueFile ? popQueueTask(queueFile) : null;

if (nextTask === "STOP") {
  process.stderr.write("[cq] STOPPED — resume with: cq add\n");
  process.exit(0);   // Normal stop — session ends
}

if (nextTask) {
  // JSON decision=block continues session, reason becomes feedback to Claude
  const output = JSON.stringify({ decision: "block", reason: nextTask });
  writeSync(1, output);     // Synchronous stdout write
  process.exit(0);          // Exit 0 — Claude parses JSON and continues
}

// Queue empty — fall through to normal stop notification
```

**Why `writeSync` + immediate `process.exit(0)`?**
Any `await` between the stdout write and `process.exit` risks hanging
(e.g. cmux notify, osascript). A hanging hook gets killed by Claude Code,
dropping the queued task. `writeSync` is synchronous and guaranteed to flush
before `process.exit`.

**`findQueueFile`** resolves the queue path by running
`git rev-parse --show-toplevel` from `input.cwd`, then appending `queue.md`.
Returns `null` if not in a git repo — queue injection is silently skipped.

**`popQueueTask`** reads the file, splits on `\n---\n`, trims blocks,
removes the first block, writes the rest back atomically, returns the
popped block (or `null` if empty).

## Queue File Location

Per-repo, always at `$(git rev-parse --show-toplevel)/queue.md`. This means:

- Each repo has its own independent queue
- Multiple Claude Code sessions in different repos don't interfere
- The file is globally gitignored (see `~/.gitignore_global`)

## Global Gitignore

`queue.md` (and future `cqueue.md`, `cnotes.md`) are in `~/.gitignore_global`:

```
queue.md
cqueue.md
cnotes.md
```

Configured via: `git config --global core.excludesfile ~/.gitignore_global`

## Statusline Integration

Line 3 of the statusline (`~/.claude/statusline.sh`) shows queue state when non-empty:

```
⚡ /commit --split · +2 more
◆ Refactor auth service · +1 more
⏹ stopped · 3 total
```

Reads from `${git_root}/queue.md` directly — always live.
````

> Later evolved: `queue.md` → `sc-queue.md`, `cqueue.md`/`cnotes.md` → `sc-queue.md`/`sc-note.md`.

---

## hooks/notify.ts — Queue Integration + Question Detection (removed)

Insert after the "Structured Logging" section and before "Types & Configuration".

Re-add `writeSync` to the `fs` import. Make `handleStopEvent` async again.

```typescript
// ============================================================================
// Queue Integration
// ============================================================================

/**
 * Find the cqueue.md file for the given cwd by locating the git root.
 * Returns null if cwd is not inside a git repo.
 */
function findQueueFile(cwd: string): string | null {
  try {
    const result = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"], {
      cwd,
      stdout: "pipe",
      stderr: "pipe",
    });
    if (result.exitCode !== 0) return null;
    return join(result.stdout.toString().trim(), "sc-queue.md");
  } catch {
    return null;
  }
}

function parseQueueBlocks(raw: string): string[] {
  const lines = raw.split("\n");

  // Skip leading header lines (# comments and blanks)
  let startIdx = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith("#") || line === "") {
      startIdx = i + 1;
    } else {
      break;
    }
  }

  const body = lines.slice(startIdx).join("\n");
  if (!body.trim()) return [];

  return body.split(/\n---\n/).map((b) => b.trim()).filter((b) => b.length > 0);
}

function writeQueueBlocks(queueFile: string, blocks: string[]): void {
  const content = blocks.length === 0 ? "" : blocks.join("\n---\n") + "\n";
  writeFileSync(queueFile, content);
}

/**
 * Pop the first task from the repo's cqueue.md.
 * Returns null if no queue or empty, "STOP" for the STOP sentinel.
 */
function popQueueTask(queueFile: string): string | null {
  if (!existsSync(queueFile)) return null;

  try {
    const raw = readFileSync(queueFile, "utf-8");
    const blocks = parseQueueBlocks(raw);
    if (blocks.length === 0) return null;

    const [first, ...rest] = blocks;
    writeQueueBlocks(queueFile, rest);

    return first;
  } catch {
    return null;
  }
}

/** Count remaining tasks after a pop. */
function getQueueSize(queueFile: string): number {
  if (!existsSync(queueFile)) return 0;

  try {
    const raw = readFileSync(queueFile, "utf-8");
    return parseQueueBlocks(raw).length;
  } catch {
    return 0;
  }
}

// ============================================================================
// Question Detection (prevents queue from overriding pending questions)
// ============================================================================

interface TranscriptMessage {
  role: string;
  text: string;
}

/**
 * Extract the last N messages from the transcript as role+text pairs.
 * Truncates from the START to preserve the end (where questions live).
 * Last message gets more room since it contains the actual question.
 */
function extractLastMessages(
  transcriptPath: string,
  count: number = 5
): TranscriptMessage[] {
  if (!existsSync(transcriptPath)) return [];

  try {
    const lines = readFileSync(transcriptPath, "utf-8")
      .split("\n")
      .filter((l) => l.trim());

    const messages: TranscriptMessage[] = [];

    for (const line of lines.slice(-count * 2).reverse()) {
      if (messages.length >= count) break;
      try {
        const entry = JSON.parse(line);
        if (entry.role && entry.content && Array.isArray(entry.content)) {
          const textParts: string[] = [];
          for (const block of entry.content) {
            if (block.type === "text" && block.text) {
              textParts.push(block.text);
            }
          }
          if (textParts.length > 0) {
            messages.unshift({ role: entry.role, text: textParts.join("\n") });
          }
        }
      } catch {
        continue;
      }
    }

    // Truncate from the start: last message gets 2000 chars, earlier ones 500
    return messages.map((msg, i) => {
      const isLast = i === messages.length - 1;
      const limit = isLast ? 2000 : 500;
      if (msg.text.length > limit) {
        return { role: msg.role, text: "…" + msg.text.slice(-limit) };
      }
      return msg;
    });
  } catch {
    return [];
  }
}

/**
 * Check if the last assistant turn used the AskUserQuestion tool.
 * Zero false positives — this is the fast/free check.
 */
function hadAskUserQuestion(transcriptPath: string): boolean {
  if (!existsSync(transcriptPath)) return false;

  try {
    const lines = readFileSync(transcriptPath, "utf-8")
      .split("\n")
      .filter((l) => l.trim());

    for (const line of lines.slice(-5).reverse()) {
      try {
        const entry = JSON.parse(line);
        if (entry.role === "assistant" && Array.isArray(entry.content)) {
          for (const block of entry.content) {
            if (
              block.type === "tool_use" &&
              block.name === "AskUserQuestion"
            ) {
              return true;
            }
          }
        }
      } catch {
        continue;
      }
    }
    return false;
  } catch {
    return false;
  }
}

/**
 * Ask Haiku whether Claude is waiting for user input.
 * Only called when the last assistant message contains "?".
 * Returns true if Haiku thinks Claude is asking a question.
 */
async function haikuEvaluatesQuestion(
  messages: TranscriptMessage[]
): Promise<boolean> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey || messages.length === 0) {
    logEvent("hook", "haiku_skip", "warn", {
      reason: !apiKey ? "no_api_key" : "no_messages",
      api_key_present: !!apiKey,
      msg_count: messages.length,
    });
    return false;
  }

  const conversationText = messages
    .map((m) => `[${m.role}]: ${m.text}`)
    .join("\n\n");

  const t0 = Date.now();
  try {
    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 10,
        system:
          "Determine if the assistant's final message is asking the user a question or requesting input/decision/clarification. Respond with only YES or NO.",
        messages: [{ role: "user", content: conversationText }],
      }),
    });

    const latencyMs = Date.now() - t0;

    if (!response.ok) {
      logEvent("hook", "haiku_call", "error", {
        http_status: response.status,
        latency_ms: latencyMs,
        result: false,
      });
      return false;
    }

    const data = (await response.json()) as {
      content?: Array<{ text?: string }>;
    };
    const answer = data.content?.[0]?.text?.trim().toUpperCase();
    const isQuestion = answer?.startsWith("YES") ?? false;

    logEvent("hook", "haiku_call", "info", {
      answer,
      result: isQuestion,
      latency_ms: latencyMs,
      http_status: response.status,
    });

    return isQuestion;
  } catch (err) {
    logEvent("hook", "haiku_call", "error", {
      error: String(err),
      latency_ms: Date.now() - t0,
      result: false,
    });
    return false;
  }
}

/**
 * Two-tier question detection:
 * 1. Fast: check for AskUserQuestion tool (zero false positives)
 * 2. Smart: if last message has "?", ask Haiku to evaluate
 */
async function isWaitingForInput(transcriptPath: string): Promise<boolean> {
  // Tier 1: explicit AskUserQuestion tool
  if (hadAskUserQuestion(transcriptPath)) {
    process.stderr.write("[cq] Question detected (AskUserQuestion tool)\n");
    logEvent("hook", "question_detect", "info", { tier: 1, result: true });
    return true;
  }

  // Tier 2: "?" in last assistant message → Haiku evaluation
  const messages = extractLastMessages(transcriptPath, 5);
  if (messages.length === 0) {
    logEvent("hook", "question_detect", "info", {
      tier: 2,
      result: false,
      reason: "no_messages",
    });
    return false;
  }

  const lastMsg = messages[messages.length - 1];
  const hasQuestionMark =
    lastMsg.role === "assistant" && lastMsg.text.includes("?");

  if (!hasQuestionMark) {
    logEvent("hook", "question_detect", "info", {
      tier: 2,
      result: false,
      reason: "no_question_mark",
      last_role: lastMsg.role,
      last_msg_preview: lastMsg.text.slice(-100),
    });
    return false;
  }

  const isQuestion = await haikuEvaluatesQuestion(messages);
  if (isQuestion) {
    process.stderr.write("[cq] Question detected (Haiku evaluation)\n");
  }
  logEvent("hook", "question_detect", "info", {
    tier: 2,
    has_question_mark: true,
    haiku_result: isQuestion,
    result: isQuestion,
  });
  return isQuestion;
}
```

### handleStopEvent (replace the simplified version)

```typescript
async function handleStopEvent(
  input: HookInput,
  state: NotificationState
): Promise<NotificationConfig | null> {
  const queueFile = findQueueFile(input.cwd);
  const queueSize = queueFile ? getQueueSize(queueFile) : 0;

  logEvent("hook", "queue_state", "info", {
    file: queueFile,
    size: queueSize,
    exists: queueFile ? existsSync(queueFile) : false,
  });

  // Before popping: check if Claude is asking the user a question
  const hasQueue =
    queueFile && existsSync(queueFile) && queueSize > 0;
  if (hasQueue && (await isWaitingForInput(input.transcript_path))) {
    // Skip queue — let the user answer first. Queue stays intact.
    const remaining = getQueueSize(queueFile!);
    process.stderr.write(
      `[cq] Paused queue (${remaining} remaining) — Claude needs input\n`
    );
    logEvent("hook", "stop_decision", "info", {
      decision: "pause_for_question",
      remaining,
    });
    // Fall through to normal stop notification
    const duration = getDuration(state);
    const project = state.projectName || "Task";
    const branch = state.gitBranch;
    const parts = [project];
    if (branch) parts.push(branch);
    if (duration) parts.push(duration);
    return {
      title: "Claude Code",
      subtitle: "Input Required (queue paused)",
      body: parts.join(" • "),
      sound:
        WORKSPACE_SOUNDS[state.workspace || "Other"],
    };
  }

  const nextTask = queueFile ? popQueueTask(queueFile) : null;

  if (nextTask !== null) {
    const taskType =
      nextTask === "STOP"
        ? "stop"
        : nextTask.trim() === "/clear"
        ? "clear"
        : nextTask.trim().startsWith("/")
        ? "slash"
        : "text";
    logEvent("hook", "queue_pop", "info", {
      task_type: taskType,
      preview: nextTask.slice(0, 80),
      remaining: queueFile ? getQueueSize(queueFile) : 0,
    });
  }

  if (nextTask === "STOP") {
    process.stderr.write("[sc] STOPPED\n");
    logEvent("hook", "stop_decision", "info", { decision: "stop_sentinel" });
    process.exit(0);
  }

  // Handle /clear — end session, signal c() to restart with next task
  if (nextTask?.trim() === "/clear") {
    // Skip consecutive /clear blocks
    let nextRealTask: string | null = null;
    while (true) {
      nextRealTask = queueFile ? popQueueTask(queueFile) : null;
      if (!nextRealTask || nextRealTask.trim() !== "/clear") break;
    }

    if (!nextRealTask || nextRealTask === "STOP") {
      process.stderr.write("[cq] Context clear — session ending\n");
      logEvent("hook", "stop_decision", "info", { decision: "clear_then_stop" });
      process.exit(0);
    }

    // Write next task to marker file — c() reads it and restarts Claude
    writeFileSync(
      join(homedir(), ".claude", ".queue-restart"),
      nextRealTask
    );
    const remaining = getQueueSize(queueFile!);
    process.stderr.write(
      `[cq] Context clear — restarting (${remaining} remaining)\n`
    );
    logEvent("hook", "stop_decision", "info", {
      decision: "clear_then_restart",
      remaining,
      next_preview: nextRealTask.slice(0, 80),
    });
    process.exit(0);
  }

  if (nextTask) {
    // Output JSON to stdout: decision=block continues the session,
    // reason becomes the next user message to Claude. Exit 0 (not 2).
    const taskType = nextTask.trim().startsWith("/") ? "slash" : "text";
    logEvent("hook", "stop_decision", "info", {
      decision: "inject_task",
      task_type: taskType,
      preview: nextTask.slice(0, 80),
    });
    const output = JSON.stringify({ decision: "block", reason: nextTask });
    writeSync(1, output);
    process.exit(0);
  }

  // Normal stop notification
  logEvent("hook", "stop_decision", "info", { decision: "normal_stop" });
  const duration = getDuration(state);
  const project = state.projectName || "Task";
  const branch = state.gitBranch;

  const parts = [project];
  if (branch) parts.push(branch);
  if (duration) parts.push(duration);

  return {
    title: "Claude Code",
    subtitle: "Task Complete",
    body: parts.join(" • "),
    sound: SOUNDS.success,
  };
}
```

Also update the dispatcher:

```typescript
case "Stop":
  notificationConfig = await handleStopEvent(input, state);
  break;
```

---

## config/zsh/claude.zsh — restart loop (removed)

```zsh
# Claude Code launcher — with cqueue /clear restart loop
#
# Usage: c [claude-args...]
#
# Skills load from ~/.claude/skills/ (global) and <repo>/.claude/skills/ (per-repo)
# automatically — no --plugin-dir needed. Workspace detection lives in skills
# themselves (e.g. SourceRoot/IuRoot 1Password account routing).
#
# Queue restart: when the stop hook writes a next task to .queue-restart,
# the session is restarted with fresh context and the task injected.

c() {
  local restart_marker="$HOME/.claude/.queue-restart"
  local claude_args=("$@")

  while true; do
    # Auto-sync Claude Code theme with macOS appearance (no "system" theme exists)
    local appearance claude_theme
    appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null)
    [[ "$appearance" == "Dark" ]] && claude_theme="dark-ansi" || claude_theme="light-ansi"
    jq --arg t "$claude_theme" '.theme = $t' ~/.claude.json > /tmp/.claude.json.tmp \
      && mv /tmp/.claude.json.tmp ~/.claude.json

    ENABLE_TOOL_SEARCH=true ANTHROPIC_API_KEY="" ANTHROPIC_BASE_URL="" claude --dangerously-skip-permissions "${claude_args[@]}"

    if [[ -f "$restart_marker" ]]; then
      local next_task
      next_task=$(<"$restart_marker")
      rm -f "$restart_marker"
      if [[ -n "$next_task" ]]; then
        echo "\n[cq] Fresh context — continuing queue\n"
        claude_args=("$next_task")
        continue
      fi
    fi
    break
  done
}
```

---

## scripts/statusline.sh — Line 3 queue section (removed)

Insert after the `# ── Git ──` block, before the `# ── Output ──` block. Also
change the header comment back to "2–3 line layout" and re-add the queue line
to the final echo block.

```bash
# ── Queue (read sc-queue.md from git root of session cwd) ───────────────────────
queue_line=""
git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
queue_file=""
[ -n "$git_root" ] && queue_file="${git_root}/sc-queue.md"
if [ -n "$queue_file" ] && [ -f "$queue_file" ]; then
  # Strip comment lines and blank lines to get task content
  content=$(grep -v '^#' "$queue_file" | sed '/^[[:space:]]*$/d')
  if [ -n "$content" ]; then
    seps=$(echo "$content" | grep -c '^---$' 2>/dev/null)
    seps=${seps:-0}
    queue_count=$((seps + 1))
    # First task = everything before the first --- separator
    first_task=$(echo "$content" | sed '/^---$/,$d' | head -1)

    if [ "$first_task" = "STOP" ]; then
      queue_line="⏹ stopped · ${queue_count} total"
    elif echo "$first_task" | grep -q '^/'; then
      preview="${first_task:0:40}"
      if [ "$queue_count" -gt 1 ]; then
        queue_line="⚡ ${preview} · +$((queue_count - 1)) more"
      else
        queue_line="⚡ ${preview}"
      fi
    else
      preview="${first_task:0:40}"
      if [ "$queue_count" -gt 1 ]; then
        queue_line="◆ ${preview} · +$((queue_count - 1)) more"
      else
        queue_line="◆ ${preview}"
      fi
    fi
  fi
fi
```

Final output block becomes:

```bash
echo -e "$line1"
echo -e "${cwd_display}${git_section}"
[ -n "$queue_line" ] && echo -e "${queue_line}"
exit 0
```

---

## config/gitignore_global — re-add queue file entries

```
# Claude Code per-repo AI files — never commit these
sc-queue.md
sc-note.md
queue.md

# sideclaw atomic write temp files
.sc-queue.md.tmp
.sc-note.md.tmp
```

---

## config/zshrc — `cq` aliases help block (removed)

Insert under the `# ── Claude Code ──` section.

```
# cq add "task"      append task to queue (single-line)
# cq add             append multi-line task via stdin (Ctrl+D to finish)
# cq list            show all pending tasks with index
# cq status          pending count
# cq edit            open cqueue.md in $EDITOR
# cq stop            append STOP sentinel — ends queue processing
# cq clear           empty the queue
```

---

## Makefile — cqueue web dashboard targets (removed)

```makefile
# ============================================================================
# cqueue — web dashboard (http://cqueue.local)
# ============================================================================

.PHONY: up
up:
	cd cqueue && docker compose up -d --build

.PHONY: down
down:
	cd cqueue && docker compose down

.PHONY: rebuild
rebuild:
	cd cqueue && docker compose up -d --build --force-recreate

.PHONY: logs
logs:
	cd cqueue && docker compose logs -f

.PHONY: shell
shell:
	cd cqueue && docker compose exec cqueue sh

.PHONY: ps
ps:
	cd cqueue && docker compose ps
```

Help block additions:

```makefile
@echo "  make up         Start cqueue dashboard"
@echo "  make down       Stop cqueue"
@echo "  make rebuild    Force-recreate cqueue container"
@echo "  make logs       Tail cqueue logs"
@echo "  make shell      Shell into cqueue container"
@echo "  make ps         Container status"
@echo ""
```

Note: these were the *old* docker-compose targets from before the LaunchAgent
rename. The actually-installed cqueue ran via `com.jkrumm.cqueue.plist` from
the `cqueue/` directory directly — see `cqueue/Makefile` in git history for
the `make install-agent` / `make reload` flow that superseded these.

---

## scripts/fetch_usage.py — variable rename (cosmetic)

```python
CQUEUE_URL = "http://localhost:7705/api/usage"
# ...
_http_post_json(CQUEUE_URL, { ... })
```

The endpoint never moved — port 7705 is still sideclaw. Only the variable name
referenced the old app name.

---

## docs/sideclaw-PRD.md (deleted)

The historical PRD for extracting `dotfiles/cqueue/` into a standalone
`~/SourceRoot/sideclaw` repo with the file/label renames (`cqueue.md` →
`sc-queue.md`, `com.jkrumm.cqueue` → `com.jkrumm.sideclaw`, etc.). The rename
itself shipped — this doc was the spec. Recover from git if needed; not
restoring it on rollback since the work it described is already done.

---

## Sideclaw side — what changed and how to un-gate

Gating commit on sideclaw adds two env flags and short-circuits the queue
surface. Files touched:

- `server/lib/feature-flags.ts` — `queueDisabled`
- `server/routes/queue.ts` — GET returns `[]`, PUT returns 503
- `server/routes/completed.ts` — returns `[]`
- `server/routes/repos.ts` — `/api/repo` returns `queue: []`; repo init skips creating `sc-queue.md`
- `server/routes/events.ts` — SSE watcher skips queue file
- `src/pages/RepoDashboard.tsx` — QueuePanel hidden, refresh no-op
- `.env.example`, `CLAUDE.md` — documented flag

**To un-gate without reverting:** set both env vars to empty (or remove the
lines) in `~/SourceRoot/sideclaw/.env`, then `make reload`. The
`QueuePanel.tsx`, `QueueCard.tsx`, `parse-queue.ts`, `queue-cache.ts`, DB
table, etc. are all still in the tree.
