---
name: ralph
description: Scaffold and run a RALPH loop — an autonomous multi-group implementation plan executed by Claude via CLI with state tracking, retries, and per-group learning notes
context: main
---

# RALPH Loop Skill

**RALPH** = Research, Analyze, Learn, Plan, Hack — an autonomous multi-group implementation pattern. Each group is a focused direction; Claude researches, plans, and implements it, then signals completion. The bash runner orchestrates retries, validation, and state between groups.

## When to Use

Large migrations, rewrites, or feature rollouts that are:
- Too big for a single Claude session (>3–4 hours of work)
- Naturally sequenced (each group builds on the previous)
- Risky enough to need per-group validation and rollback safety
- Complex enough to benefit from Claude planning each group independently

Examples: language rewrites, database migrations, API redesigns, CI/CD overhauls.

## Invocation

```
/ralph setup       # Scaffold a new RALPH loop for the current project
/ralph run         # Start/continue running pending groups
/ralph status      # Print group status from state file
/ralph reset N     # Reset group N to pending
/ralph babysitter  # Dynamic /loop observer — status checks + Slack updates every 30 min
/ralph cleanup     # Distill notes into docs/migrations/<name>.md, then delete all ralph artifacts (one-way)
```

---

## How to Run Setup (`/ralph setup`)

When the user invokes `/ralph setup`, follow this workflow:

### Step 1 — Understand the task

Ask the user:
- What is the overall goal? (e.g. "rewrite TypeScript server in Go")
- What tech stack / toolchain is involved?
- What are the validation commands? (build, test, lint, typecheck, E2E)
- How many groups (rough estimate)? Groups should fit in **45 min of autonomous Claude time** each (the `CLAUDE_TIMEOUT`), which usually maps to 1–2h of human work.
- Any hard sequencing constraints (e.g. "Group 5 must pass E2E before Group 6")?
- Does the migration have a **deploy-pause window** — groups whose output is correct but ships brokenness if deployed before the cutover? If yes, `RALPH_BRANCH` defaults to `migration/<name>` and the runner stays on it.

### Step 2 — Define groups

Decompose the goal into focused groups. Apply the split-trigger heuristics below — typical migrations end up in the 10–16 range, not the 5–12 range, once strictness baseline + cross-cutting concerns are extracted.

Rules:
- Group 1 is always the skeleton/foundation (no validation failures possible yet)
- Groups build on previous — never require skipping a group
- **Strictness baseline (TS strict, lint plugins, lefthook, React Compiler) lands as Group 3 or 4** — not at the end. See the dedicated section below.
- E2E green checkpoints: at least one group explicitly validates full E2E before risky changes
- Dangerous/breaking groups (delete old system, cut over production) go last
- Apply the **split-trigger heuristics** below before finalizing the list

Output a numbered list for user review before creating files.

### Step 3 — Create directory structure

```
<project>/
  scripts/
    ralph.sh            # runner (generated from template below)
    ralph-reset.sh      # reset helper
  docs/ralph/
    shared-context.md   # injected into every group prompt
    RALPH_NOTES.md      # Claude appends after each group
    RALPH_REPORT.md     # auto-generated status
    prompts/
      group-1.md
      group-2.md
      ...
```

State and logs are gitignored:
```
.ralph-tasks.json
.ralph-logs/
```

Add to `.gitignore`:
```
.ralph-tasks.json
.ralph-logs/
```

### Step 4 — Write shared-context.md

The shared context is prepended to every group prompt. Include:

```markdown
# <Project> — RALPH Shared Context

You are implementing: **<goal>**. Read this fully before starting your group.

---

## What <Project> Is

[2–3 paragraph description: what it does, why it exists, key design decisions]

---

## Repository Layout

[tree or table of relevant files/dirs]

---

## Tech Stack

| Concern | Choice |
|-|-|
| ... | ... |

---

## Validation Commands

**Primary (run after every group):**
```bash
<build command>    # must compile/bundle clean
<test command>     # all unit tests pass
<lint command>     # must be clean
```

**E2E (only when instructed — may require Docker/infra):**
```bash
<e2e command>
```

---

## Research Before Implementing

Always start by:
1. Explore the codebase with Glob/Grep/Read — understand existing patterns
2. Research unfamiliar libraries with Context7 or Tavily Search + WebFetch
3. Read relevant existing code before writing new code
4. The group prompt is direction, not prescription — use a better approach if you find one

---

## Learning Notes

After completing each group, **always append** to `docs/ralph/RALPH_NOTES.md`:

```markdown
## Group N: <title>

### What was implemented
<1–3 sentences>

### Deviations from prompt
<what you changed and why>

### Gotchas & surprises
<anything unexpected — library APIs, language quirks, tooling surprises>

### Security notes
<security-relevant decisions, if any>

### Tests added
<list of test files/functions added>

### Future improvements
<deferred work, tech debt, better approaches possible>
```

---

## Commit Format

Conventional commits, no AI attribution:
```
feat(<scope>): <description>
refactor(<scope>): <description>
fix(<scope>): <description>
```

Stage only modified files. Commit before signaling completion.

**Use raw `git` only — never invoke interactive skills.** Use `git add <files>` + `git commit -m "..."` directly. **Do not invoke `/commit`, `/commit --split`, `/pr`, `/check`, `/review`, `/ship`, or any other slash-command skill** from inside a group. These skills are interactive workflows that present proposals and wait for user confirmation; in `claude -p` headless mode the confirmation never comes, the skill prints a strategy, the model returns "success" with no side effect, and the group exits with no commit and no `RALPH_TASK_COMPLETE` signal. The runner then resets the group to `pending`, the working tree is left dirty, and the babysitter has to wake the human. If a group genuinely needs to split into multiple commits, do `git add <subset> && git commit -m "..."` once per logical commit.

---

## Completion Signal

Output exactly one of these at the end, as the very last line:

```
RALPH_TASK_COMPLETE: Group N
```

If you cannot proceed due to an unresolvable blocker:

```
RALPH_TASK_BLOCKED: Group N - <reason in one sentence>
```
```

### Step 5 — Write group prompt files

Each `group-N.md` follows this template:

```markdown
# Group N: <Title>

## What You're Doing

[2–4 sentences. What is the goal of this group? What state does it leave the codebase in?]

---

## Research & Exploration First

1. [Specific file to read — always read before writing]
2. [Library to research via Context7 or Tavily]
3. [Existing pattern to understand]
4. [Edge case to investigate]

---

## What to Implement

### 1. <Component/file name>

[What to create or change. Be specific about interfaces, types, function signatures.]

```<lang>
// Key signatures or skeleton
```

### 2. <Next component>

[...]

---

## Validation

```bash
<build>    # must pass
<test>     # all pass, including new tests for this group
<lint>     # clean
```

[List what to test specifically — table-driven tests, edge cases, happy paths.]

---

## Commit

```
feat(<scope>): <description of this group's work>
```

---

## Done

Append learning notes to `docs/ralph/RALPH_NOTES.md`, then:
```
RALPH_TASK_COMPLETE: Group N
```
```

**Group prompt discipline:**
- Group 1: foundation only, no validation gate (nothing to validate yet)
- E2E checkpoint groups: explicitly state "Run full E2E: `<cmd>`"
- Cutover/breaking groups: add a "DANGER" note at the top, explicit rollback instructions
- Keep prompts tight: direction + key signatures + validation. Not a full spec.

### Step 6 — Generate the runner script

Write `scripts/ralph.sh` using the proven template:

```bash
#!/usr/bin/env bash
# <Project> — RALPH Loop Runner
#
# Usage:
#   ./scripts/ralph.sh              # Run all pending groups
#   ./scripts/ralph.sh 3            # Run only group 3
#   ./scripts/ralph.sh --reset 3    # Reset group 3 to pending, then run
#   ./scripts/ralph.sh --status     # Print status and exit
#
# Logs: .ralph-logs/group-N.log
# Watch live: tail -f .ralph-logs/group-N.log
#
# Prerequisites:
#   brew install coreutils   # for gtimeout
#   claude CLI must be in PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$REPO_ROOT/docs/ralph"
PROMPTS_DIR="$DOCS_DIR/prompts"
STATE_FILE="$REPO_ROOT/.ralph-tasks.json"
LOGS_DIR="$REPO_ROOT/.ralph-logs"
REPORT_FILE="$DOCS_DIR/RALPH_REPORT.md"

MAX_RETRIES=3
CLAUDE_TIMEOUT=2700  # 45 minutes per group

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

TOTAL_GROUPS=<N>

GROUP_TITLES=(
  ""  # 1-indexed
  "<title 1>"
  "<title 2>"
  # ...
)

log_info()    { echo -e "${BLUE}[ralph]${NC} $*"; }
log_success() { echo -e "${GREEN}[ralph]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[ralph]${NC} $*"; }
log_error()   { echo -e "${RED}[ralph]${NC} $*"; }

require_commands() {
  local missing=0
  for cmd in claude gtimeout python3; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd not found."
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || { echo "Install: brew install coreutils"; exit 1; }
}

# ── State management ──────────────────────────────────────────────────────────

init_state() {
  [[ -f "$STATE_FILE" ]] && { log_info "Resuming from existing state."; return; }
  log_info "Initializing task state..."
  python3 - <<PYEOF
import json
titles = [$(printf '"%s", ' "${GROUP_TITLES[@]:1}" | sed 's/, $//')]
groups = [{"id": i+1, "title": t, "status": "pending", "attempts": 0,
           "started_at": None, "completed_at": None}
          for i, t in enumerate(titles)]
state = {"groups": groups, "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)
print("State initialized.")
PYEOF
}

get_field() {
  python3 -c "
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
for g in state['groups']:
    if g['id'] == $1:
        print(g.get('$2', ''))
        break
"
}

set_field() {
  python3 - <<PYEOF
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
for g in state['groups']:
    if g['id'] == $1:
        val = '$3'
        if val in ('True', 'False', 'None'):
            val = {'True': True, 'False': False, 'None': None}[val]
        g['$2'] = val
        break
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

inc_attempts() {
  python3 - <<PYEOF
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
for g in state['groups']:
    if g['id'] == $1:
        g['attempts'] = g.get('attempts', 0) + 1
        break
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

print_status() {
  python3 - <<PYEOF
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
icons = {'complete': '✅', 'blocked': '🚫', 'pending': '⬜', 'in_progress': '🔄'}
total = len(state['groups'])
done = sum(1 for g in state['groups'] if g['status'] == 'complete')
blocked = sum(1 for g in state['groups'] if g['status'] == 'blocked')
pending = total - done - blocked
print(f"  {total} groups | {done} complete | {pending} pending | {blocked} blocked")
print()
for g in state['groups']:
    icon = icons.get(g['status'], '⬜')
    attempts = f"  (attempt {g['attempts']})" if g['attempts'] > 0 else ""
    print(f"  {icon}  Group {g['id']}: {g['title']}{attempts}")
PYEOF
}

# ── Validation ────────────────────────────────────────────────────────────────

validate() {
  local label=${1:-""}
  log_info "Validation${label:+ ($label)}..."
  cd "$REPO_ROOT"
  # CUSTOMIZE: replace with your project's validation commands
  if ! <build command> 2>&1; then log_error "Build failed"; return 1; fi
  if ! <test command> 2>&1; then log_error "Tests failed"; return 1; fi
  log_success "Validation passed"
  return 0
}

# ── Claude invocation ─────────────────────────────────────────────────────────

run_group() {
  local group_id=$1
  local prompt_file="$PROMPTS_DIR/group-$group_id.md"
  local context_file="$DOCS_DIR/shared-context.md"
  local log_file="$LOGS_DIR/group-$group_id.log"

  mkdir -p "$LOGS_DIR"

  if [[ ! -f "$prompt_file" ]]; then
    log_error "Prompt not found: $prompt_file"
    return 1
  fi

  local full_prompt
  full_prompt="$(cat "$context_file")"$'\n\n---\n\n'"$(cat "$prompt_file")"

  log_info "Claude running (timeout: ${CLAUDE_TIMEOUT}s) → log: .ralph-logs/group-$group_id.log"
  log_info "Watch live: tail -f .ralph-logs/group-$group_id.log"
  echo ""

  local exit_code=0
  if CLAUDE_CODE_ENABLE_TASKS=true CLAUDECODE="" gtimeout "$CLAUDE_TIMEOUT" claude \
    -p "$full_prompt" \
    --model sonnet \
    --effort high \
    --dangerously-skip-permissions \
    --output-format stream-json \
    --verbose \
    --no-session-persistence \
    < /dev/null > "$log_file" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  # Check completion signal BEFORE the timeout guard — Claude may have finished its
  # work and emitted the signal, but the post-signal summary/notes/commit pushed the
  # process past the timeout limit. In that case the group is done; don't treat it as failed.
  grep -q "RALPH_TASK_COMPLETE: Group $group_id" "$log_file" && return 0
  grep -q "RALPH_TASK_BLOCKED: Group $group_id" "$log_file" && return 2

  [[ $exit_code -eq 124 ]] && { log_error "Timed out after ${CLAUDE_TIMEOUT}s"; return 1; }

  log_warn "Claude finished but no completion signal in log."
  return 1
}

# ── Report ────────────────────────────────────────────────────────────────────

generate_report() {
  python3 - <<PYEOF
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
icons = {'complete': '✅', 'blocked': '🚫', 'pending': '⬜', 'in_progress': '🔄'}
total = len(state['groups'])
done = sum(1 for g in state['groups'] if g['status'] == 'complete')
blocked = sum(1 for g in state['groups'] if g['status'] == 'blocked')
pending = total - done - blocked
lines = [
    "# RALPH Report",
    "",
    f"Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)",
    f"Groups: {total} total | {done} complete | {pending} pending | {blocked} blocked",
    "", "## Status", "",
]
for g in state['groups']:
    icon = icons.get(g['status'], '⬜')
    attempts = f" (attempts: {g['attempts']})" if g['attempts'] > 0 else ""
    lines.append(f"- {icon} **Group {g['id']}**: {g['title']}{attempts}")
lines += ["", "## Next Steps", ""]
if done == total:
    lines += ["All groups complete.", "", "1. Review: `git log --oneline -20`", "2. Run full E2E", "3. Create PR: `/pr`"]
elif pending > 0:
    lines.append("Run `./scripts/ralph.sh` to continue.")
with open('$REPORT_FILE', 'w') as f:
    f.write('\n'.join(lines) + '\n')
print(f"Report: $REPORT_FILE")
PYEOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  local target_group=""
  local do_reset=false
  local status_only=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --status) status_only=true; shift ;;
      --reset) do_reset=true; target_group="${2:?'--reset requires a group number'}"; shift 2 ;;
      [0-9]*) target_group="$1"; shift ;;
      *) echo "Unknown: $1"; echo "Usage: $0 [group] [--reset group] [--status]"; exit 1 ;;
    esac
  done

  echo ""
  echo -e "${BOLD}  RALPH Loop${NC}"
  echo ""

  require_commands
  cd "$REPO_ROOT"
  init_state

  if $status_only; then print_status; exit 0; fi

  if $do_reset; then
    log_info "Resetting Group $target_group to pending..."
    set_field "$target_group" "status" "pending"
    python3 - <<PYEOF
import json
with open('$STATE_FILE') as f:
    state = json.load(f)
for g in state['groups']:
    if g['id'] == $target_group:
        g['attempts'] = 0; break
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
  fi

  print_status; echo ""

  local groups_to_run=()
  if [[ -n "$target_group" ]]; then
    groups_to_run=("$target_group")
  else
    for i in $(seq 1 $TOTAL_GROUPS); do groups_to_run+=("$i"); done
  fi

  for group_id in "${groups_to_run[@]}"; do
    local status
    status=$(get_field "$group_id" "status")

    if [[ "$status" == "complete" ]]; then
      echo -e "  ✅  Group $group_id: ${GROUP_TITLES[$group_id]} — skipped (complete)"
      continue
    fi
    if [[ "$status" == "blocked" ]]; then
      echo -e "  🚫  Group $group_id: ${GROUP_TITLES[$group_id]} — skipped (blocked)"
      continue
    fi

    local attempts
    attempts=$(get_field "$group_id" "attempts")

    if [[ "$attempts" -ge "$MAX_RETRIES" ]]; then
      log_warn "Group $group_id reached max retries. Marking blocked."
      set_field "$group_id" "status" "blocked"
      continue
    fi

    echo ""
    echo "  ────────────────────────────────────────────"
    echo -e "  ${BOLD}Group $group_id: ${GROUP_TITLES[$group_id]}${NC}"
    echo "  Attempt: $((attempts + 1)) / $MAX_RETRIES"
    echo "  ────────────────────────────────────────────"
    echo ""

    # Pre-group validation (skip group 1 — nothing to validate yet)
    if [[ "$group_id" -gt 1 ]]; then
      if ! validate "pre-group $group_id"; then
        log_error "Pre-group validation failed. Fix before continuing."
        exit 1
      fi
      echo ""
    fi

    set_field "$group_id" "status" "in_progress"
    inc_attempts "$group_id"

    run_result=0
    run_group "$group_id" || run_result=$?
    echo ""

    if [[ $run_result -eq 0 ]]; then
      log_success "Group $group_id complete."
      set_field "$group_id" "status" "complete"
      set_field "$group_id" "completed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo ""
      if validate "post-group $group_id"; then
        log_success "Post-group validation passed ✓"
      else
        log_warn "Post-group validation FAILED. Review log and fix."
        log_warn "Retry: ./scripts/ralph.sh --reset $group_id"
      fi
    elif [[ $run_result -eq 2 ]]; then
      log_warn "Group $group_id blocked. See: .ralph-logs/group-$group_id.log"
      set_field "$group_id" "status" "blocked"
    else
      log_error "Group $group_id failed (attempt $((attempts + 1)) / $MAX_RETRIES)"
      set_field "$group_id" "status" "pending"
      log_info "Log: .ralph-logs/group-$group_id.log"
      new_attempts=$(get_field "$group_id" "attempts")
      if [[ "$new_attempts" -ge "$MAX_RETRIES" ]]; then
        set_field "$group_id" "status" "blocked"
      elif [[ -z "$target_group" ]]; then
        log_warn "Stopping. Fix Group $group_id before proceeding."
        break
      fi
    fi

    echo ""
  done

  echo ""
  generate_report
  echo ""
  echo -e "${BOLD}  RALPH loop done.${NC}"
  echo ""
  print_status
  echo ""
}

main "$@"
```

Also create `scripts/ralph-reset.sh`:

```bash
#!/usr/bin/env bash
# Reset a group to pending (allows re-running after manual fix)
# Usage: ./scripts/ralph-reset.sh <group-id>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ralph.sh" --reset "${1:?'Usage: ralph-reset.sh <group-id>'}"
```

Make both executable: `chmod +x scripts/ralph.sh scripts/ralph-reset.sh`

---

## Pre-flight Setup (REQUIRED — bake into runner)

Five issues silently break autonomous loops on macOS + 1Password + multi-day migrations. All are mechanical fixes that belong in `ralph.sh`, not in user instructions.

### 1. Commit-signing biometric block

If the user's git config has `commit.gpgsign = true` with `gpg.format = ssh` and `gpg.ssh.program = /Applications/1Password.app/Contents/MacOS/op-ssh-sign`, **every commit hangs on Touch ID**. The autonomous loop will time out at the first commit.

Detect this at runner startup. Disable signing **per-repo** for the loop's duration. Restore via `trap` on exit. Never `--no-gpg-sign` (that violates the user's commit rules); use the local config override instead.

```bash
ORIG_GPGSIGN=""
GPGSIGN_TOUCHED=false

disable_commit_signing() {
  cd "$REPO_ROOT"
  ORIG_GPGSIGN="$(git config --local --get commit.gpgsign || echo '__unset__')"
  local effective
  effective="$(git config --get commit.gpgsign || echo 'false')"
  if [[ "$effective" == "true" ]]; then
    log_warn "commit.gpgsign=true detected — disabling for the loop (would block on Touch ID)."
    git config --local commit.gpgsign false
    GPGSIGN_TOUCHED=true
  fi
}

restore_commit_signing() {
  $GPGSIGN_TOUCHED || return 0
  cd "$REPO_ROOT" 2>/dev/null || return 0
  if [[ "$ORIG_GPGSIGN" == "__unset__" ]]; then
    git config --local --unset commit.gpgsign 2>/dev/null || true
  else
    git config --local commit.gpgsign "$ORIG_GPGSIGN"
  fi
  log_info "Restored commit.gpgsign (was: $ORIG_GPGSIGN)."
}

trap restore_commit_signing EXIT
```

Call `disable_commit_signing` from `main()` after `require_commands`. The trap handles every exit path (success, failure, SIGINT).

### 2. Default-branch guard

Autonomous commits to `master` / `main` are unsafe — `deploy.yml` typically fires on push, and the user's workflow assumes humans review before that happens. The runner must refuse to run when HEAD is on the default branch.

This is a guard, **not** a branch-creator. Users normally invoke `/ralph setup` from a feature branch they already chose (e.g. `feat/v2`, `wip/migration`). Silently switching them to a hard-coded branch name fights that workflow. The right move is to fail loudly and let the user `git checkout -b <name>` themselves.

```bash
refuse_default_branch() {
  cd "$REPO_ROOT"
  local current
  current="$(git rev-parse --abbrev-ref HEAD)"
  case "$current" in
    master|main)
      log_error "Refusing to run on '$current' — autonomous commits to the default branch are unsafe."
      log_error "Switch to a feature/migration branch first: git checkout -b <name>"
      exit 1
      ;;
  esac
  log_info "Running on branch: $current"
}
```

Call from `main()` together with the signing fix. For migrations with a "deploy pause" window (groups that produce code that's correct in isolation but breaks production if shipped before the cutover lands), the same guard suffices — the user runs the loop on their existing branch and pushes manually only when ready. No long-lived `migration/<name>` branch needed unless the user explicitly wants one.

### 3. 1Password CLI session pre-flight

Groups that read secrets via `op run --account <acct>` (database URLs, API keys, OTLP credentials) hang on Touch ID the same way `op-ssh-sign` does, just on a different surface. The runner must verify the session is alive before launching the first group — otherwise group N is mid-flight when biometric prompts the user at 3am.

```bash
require_op_session() {
  log_info "Verifying 1Password CLI session (op --account <acct>)..."
  if ! gtimeout 5 op whoami --account <acct> >/dev/null 2>&1; then
    log_error "1Password CLI session is not active."
    log_error "Sign in once before launching: eval \$(op signin --account <acct>)"
    exit 1
  fi
  log_success "op session active."
}
```

Note the `gtimeout 5` — without it, a missing session can itself hang on Touch ID prompt. With it, the runner exits fast and tells the user what to do.

### 4. Secrets pre-fetch (eliminate `op run` from the loop body)

The `op whoami` check (step 3) only verifies a session **exists**. It doesn't guarantee that `op run` mid-loop won't prompt for Touch ID — that depends on the user's 1Password settings (auto-lock timer, "Require Touch ID for each command", etc.). At 3am when the user is asleep, **any** mid-loop biometric prompt halts everything.

The robust pattern: **fetch every secret the loop needs during pre-flight, write to a mode-600 env file, source it into the runner's environment, and delete on exit.** Mid-loop, no `op` interaction. Groups that need a secret read the env var directly; groups that need an `op://`-backed config file generate it from the env var (e.g. docker-compose env interpolation).

```bash
SECRETS_FILE="$REPO_ROOT/.ralph-secrets.env"
SECRETS_INSTALLED=false   # only the invocation that wrote the file may delete it

prefetch_secrets() {
  log_info "Pre-fetching secrets via op (Touch ID may prompt)..."
  local db_password
  db_password="$(gtimeout 30 op read 'op://<vault>/<item>/<field>' --account <acct> 2>/dev/null || true)"
  if [[ -z "$db_password" ]]; then
    log_error "Failed to read secret. Make sure the 1Password app is unlocked."
    exit 1
  fi
  umask 077
  cat > "$SECRETS_FILE" <<EOF
# Auto-generated by scripts/ralph.sh — DO NOT COMMIT. Deleted on runner exit.
PROJECT_DB_PASSWORD=$db_password
PROJECT_LOCAL_DATABASE_URL=postgres://user:$db_password@localhost:5433/db
EOF
  chmod 600 "$SECRETS_FILE"
  # Export into runner env so subprocesses (claude -p) inherit it.
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
  SECRETS_INSTALLED=true
  log_success "Secrets cached to .ralph-secrets.env (mode 600) and exported."
}

remove_secrets() {
  # Only delete the file if THIS invocation created it. Side-channel invocations
  # like `./scripts/ralph.sh --status` and `--reset N` skip prefetch and must not
  # strip the secrets out from under a running runner (its env is already loaded,
  # but the babysitter still needs the file to recover RALPH_SLACK_WEBHOOK_URL).
  $SECRETS_INSTALLED || return 0
  [[ -f "$SECRETS_FILE" ]] || return 0
  rm -f "$SECRETS_FILE"
  log_info "Removed .ralph-secrets.env."
}
```

**Why the sentinel matters:** the cleanup trap fires on every exit, including `--status` and `--reset`. Without the `$SECRETS_INSTALLED` guard, a babysitter or human running `./scripts/ralph.sh --status` to peek at progress will silently delete the secrets file the active runner installed. The running process is unaffected (its env was sourced before the trap was registered) — but the babysitter loses `RALPH_SLACK_WEBHOOK_URL`, and re-fetching from 1Password forces a Touch ID prompt every 30 min, which defeats the whole point of pre-fetching. Apply the same `<name>_INSTALLED` sentinel pattern to `install_push_guard` / `remove_push_guard` (and any future pre-flight installer).

**Add `.ralph-secrets.env` to `.gitignore`.** Mode-600 + auto-delete are belt-and-suspenders; the gitignore is the real safety net against accidental commit.

**Patterns:**

- **Single source of truth for shared values.** If local dev and production use the same DB password (e.g. you provisioned the local container with the production password rather than inventing a throwaway), pre-fetch *once* and reuse for both `PROJECT_LOCAL_DATABASE_URL` and `PROJECT_PROD_DATABASE_URL`. Don't make the agent invent local-only throwaway credentials — that's a footgun if the agent's hardcoded "throwaway" later collides with a real value.
- **docker-compose env interpolation.** `POSTGRES_PASSWORD: ${PROJECT_DB_PASSWORD}` in `docker-compose.dev.yml` reads from the runner's exported env. Local devs running `make db-up` outside the loop should have the Makefile target source `.ralph-secrets.env` first — same mechanism.
- **Subprocess inheritance is the whole point.** The `set -a; source; set +a` pattern auto-exports every variable defined in the file. Without `set -a`, `claude -p` child processes don't see the vars and you're back to needing `op run` per command.
- **Group prompts reference env vars, not `op run`.** Rewrite group prompts so any DB URL / API key is `"$PROJECT_LOCAL_DATABASE_URL"` (proper double-quote interpolation), not `op run --env-file=...`.

**What pre-fetch does NOT cover:** truly interactive groups like the production cutover, which the user runs hands-on-keyboard during the day. Those can `op run` directly — Touch ID will resolve in seconds. Pre-fetch is for the **autonomous overnight window**.

### 5. Pre-push hook guard

Shared-context tells Claude "commit only, don't push" but that's a soft constraint. An autonomous agent in retry could `git push` and fire `deploy.yml` mid-migration. Install a real `pre-push` hook at runner startup that exits 1; remove on `trap` exit.

```bash
PUSH_GUARD_INSTALLED=false

install_push_guard() {
  cd "$REPO_ROOT"
  PRE_PUSH_HOOK="$(git rev-parse --git-path hooks)/pre-push"
  if [[ -f "$PRE_PUSH_HOOK" ]]; then
    PRE_PUSH_BACKUP="${PRE_PUSH_HOOK}.ralph-backup"
    mv "$PRE_PUSH_HOOK" "$PRE_PUSH_BACKUP"
  fi
  cat > "$PRE_PUSH_HOOK" <<'HOOK'
#!/usr/bin/env bash
echo "[ralph] pre-push hook: autonomous push blocked." >&2
exit 1
HOOK
  chmod +x "$PRE_PUSH_HOOK"
  PUSH_GUARD_INSTALLED=true
}

remove_push_guard() {
  # Same sentinel discipline as remove_secrets: --status / --reset must not
  # uninstall a hook the running runner is depending on.
  $PUSH_GUARD_INSTALLED || return 0
  cd "$REPO_ROOT" 2>/dev/null || return 0
  PRE_PUSH_HOOK="$(git rev-parse --git-path hooks)/pre-push"
  rm -f "$PRE_PUSH_HOOK"
  if [[ -f "${PRE_PUSH_HOOK}.ralph-backup" ]]; then
    mv "${PRE_PUSH_HOOK}.ralph-backup" "$PRE_PUSH_HOOK"
  fi
}
```

Cheap belt-and-suspenders against agent free will.

### Combined cleanup trap

All pre-flight installers register a single cleanup hook:

```bash
cleanup_on_exit() {
  restore_commit_signing
  remove_push_guard
  remove_secrets
}
trap cleanup_on_exit EXIT
```

Pre-flight order in `main()`:
1. `require_commands` (claude, gtimeout, python3, bun, op)
2. `refuse_default_branch`
3. `require_op_session`
4. `prefetch_secrets` — fetch + export into runner env
5. `disable_commit_signing`
6. `install_push_guard`
7. `init_state`

---

## Pull tooling forward — don't trail with strictness

A common pattern in PRDs: "we'll add max-strict TS, extended lint plugins, React Compiler, and pre-commit hooks at the end as Group N." This **always backfires**:

- Groups 3 → (N-1) produce code without those rules.
- Group N flips on `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` + extended lint patterns.
- A cascade of typecheck/lint errors appears across every file written in the prior groups.
- Group N now has two jobs: add the tooling AND fix every cascading error. It silently triples in size.

**Rule:** add **the rules themselves** as early as possible — right after the scaffold group, before any meaningful code lands. Tests and CI workflow can still live at the end (they have content-dependencies on the implementation). But TS strictness, lint plugins, lefthook, and React Compiler all belong in a small standalone group that runs early.

This isn't a "nice to have" — it's load-bearing. Errors caught while writing the code that produced them are 10× cheaper than errors caught in a final sweep.

In group-decomposition step (Step 2 of `/ralph setup`), explicitly extract a "strictness baseline" group and place it as Group 4 or earlier.

---

## Key Design Decisions (battle-tested)

### Claude invocation flags

```bash
gtimeout "$CLAUDE_TIMEOUT" claude \
  -p "$full_prompt" \
  --model sonnet \                  # explicit — don't inherit interactive session model
  --effort high \                   # explicit — don't inherit interactive session effort
  --dangerously-skip-permissions \  # lets Claude run tools without prompting
  --output-format stream-json \     # writes to log file in real-time (text format buffers)
  --verbose \                       # includes tool use in log output
  --no-session-persistence \        # fresh context each group
  < /dev/null                       # prevents interactive prompts from blocking
```

`CLAUDE_CODE_ENABLE_TASKS=true` + `CLAUDECODE=""` suppress interactive UI noise.

**Model choice:** `--model` and `--effort` must be set explicitly. The `/model` and `/effort` commands in an interactive Claude Code session are session-level only — they are **not** inherited by spawned `claude -p` subprocesses. Without explicit flags, each group silently uses whatever the global default is. Sonnet + high effort is the right default for RALPH: good quality at materially lower cost and latency than Opus for 45-minute autonomous runs. Override per-group if needed (e.g. bump to `opus` for a particularly complex migration group).

### Completion signal detection

The runner greps the raw log file for `RALPH_TASK_COMPLETE: Group N`. Claude must emit this as literal text in its response (not inside a code block). If Claude finishes without the signal, it's treated as a failure and retried.

### Validation gate

Pre-group validation (group > 1): ensures previous group left repo clean before Claude starts.
Post-group validation: catches regressions introduced in the current group.
If post-group fails: print warning but don't mark as blocked — Claude completed its task; the human needs to fix validation errors before retrying.

### Retry semantics

- `attempts` increments before run (not after)
- On failure: status → pending; runner stops sequential execution so human can inspect log
- On blocked signal: status → blocked; skipped in all future runs until manual `--reset`
- Max retries reached: auto-mark blocked

### Shared context injection

`full_prompt = shared_context + "\n\n---\n\n" + group_prompt`

Shared context is read fresh each group run — it can be updated between runs.

---

## Group Sizing Guidelines

| Group duration | Size indicator |
|-|-|
| < 30 min | Too small — merge with adjacent group |
| 1–2h | Ideal |
| 2–3h | Acceptable for focused work |
| > 3h | Split — Claude loses focus, errors accumulate |

Each group should leave the repo in a **compilable, testable state**. Never have a group that deliberately breaks the build (except explicitly transient mid-group state).

**Timeout risk:** The 45-minute `CLAUDE_TIMEOUT` is generous for most groups, but groups that combine heavy research + multiple integrations + validation can stretch close to the limit. A group that looks like "2h of work" on paper can push toward timeout when Claude spends significant time researching unfamiliar APIs before writing a line of code. If a group has more than ~5 major components *and* requires researching 3+ libraries from scratch, consider splitting it — not because 2h is too long conceptually, but because research time is unpredictable. The runner handles the timeout-after-completion edge case (emitting the signal before the clock runs out but not before cleanup finishes), so this is a soft concern, not a hard rule.

### Split-trigger heuristics (when reviewing a draft group list)

A group is a split candidate if **any** of these apply:

1. **More than one architectural decision.** Pagination shape, error envelope, schema lib are three decisions — three groups, not one.
2. **N independent sub-resources × M concerns.** "Migrate 7 routes to a new pagination + add 7 new summary endpoints + swap the validation lib across 16 files" reads as 1 group on paper and 4–5 hours of unfocused churn in practice. Each concern is its own group; routes within a concern can be batched.
3. **Touches the same file as another planned group.** Coordination overhead is high; consolidate or sequence explicitly with a "Depends on" link.
4. **Adds new lint or TS rules.** Anything that flips strictness across the codebase is its own group, because the cascade is the work, not the rule flip.
5. **Library version upgrade + feature change in the same group.** Separate the upgrade from the feature so a failure surface is one variable.

Conversely, **mechanical fan-out of one pattern across N files is fine** — Claude can churn through 16 nearly-identical route migrations in <30 min if the pattern is established. The cost is decisions, not keystrokes.

---

## After All Groups Complete

1. `./scripts/ralph.sh --status` — confirm all green
2. `git log --oneline -20` — review commit history
3. Run full E2E suite
4. Review `docs/ralph/RALPH_NOTES.md` — capture gotchas in CLAUDE.md if broadly applicable
5. `/pr` — create PR
6. After PR merges and you're confident you'll never want to `--reset N` and re-run a single group: **`/ralph cleanup`** — distills notes into `docs/migrations/<name>.md` and deletes every ralph artifact in one commit. One-way.

---

## Babysitter Pattern (recommended for overnight runs)

The runner is self-managing for retries but has no external observer. Stuck states (group in_progress with no log activity), repeated retries on the same group, or completion all go unnoticed until the human checks back. For multi-hour autonomous runs, pair the runner with a **lightweight babysitter**.

**How:** the user invokes `/loop` in a Claude Code session with a babysit prompt; that session uses `ScheduleWakeup` to re-fire every 20–30 minutes. Each iteration:

1. Reads `.ralph-tasks.json` and prints status.
2. Tails the most recent `.ralph-logs/group-N.log` (last 40 lines).
3. Detects "no progress in 60 min" — the group is `in_progress` but the log mtime is older than an hour. Probably stuck.
4. Detects "approaching max retries" — `attempts: 2` after a failure means one more chance before auto-blocked.
5. Detects "completion" — all 12 groups `complete`. Ends the loop.
6. Surfaces anomalies briefly. Schedules the next wakeup.

**Why not full intervention from the babysitter?** Stuck-state recovery (e.g. `./scripts/ralph.sh --reset N`) usually needs human judgment about what went wrong. The babysitter's job is detection + reporting, not autonomous repair. The cost of a false-positive auto-reset is high (you lose validated work); the cost of waking the human a few minutes late is low.

The 30-minute cadence is chosen so cache stays warm across iterations (each wake under 5 min from prior cache, see the ScheduleWakeup tool's cache-window guidance — 1200–1800s is the sweet spot for idle observability ticks).

---

## How to Run Babysitter (`/ralph babysitter`)

When the user invokes `/ralph babysitter`, you (the assistant) **become** the babysitter for that Claude Code session. The user is expected to have already launched `./scripts/ralph.sh` in a separate terminal — `.ralph-secrets.env` exists in the repo root with `RALPH_SLACK_WEBHOOK_URL` set by the runner's pre-fetch.

### Per-iteration playbook

Each time the babysitter fires (initial invocation + every `ScheduleWakeup`), do this exactly:

#### Step 1 — Source secrets

```bash
[ -f .ralph-secrets.env ] || { echo "no secrets file — runner not started?"; exit 1; }
source .ralph-secrets.env
```

If the file isn't there, the loop never started or already finished + cleaned up. Stop scheduling further wakeups.

#### Step 2 — Read state + recent log

**Never invoke `./scripts/ralph.sh` (any subcommand) from the babysitter** — even `--status` runs the script's cleanup trap, which can interact badly with the live runner. Read `.ralph-tasks.json` directly:

```bash
python3 - <<'PYEOF'
import json
with open('.ralph-tasks.json') as f:
    state = json.load(f)
total = len(state['groups'])
done = sum(1 for g in state['groups'] if g['status'] == 'complete')
in_prog = [g for g in state['groups'] if g['status'] == 'in_progress']
blocked = sum(1 for g in state['groups'] if g['status'] == 'blocked')
pending = total - done - blocked - len(in_prog)
print(f"TOTAL={total} DONE={done} INPROG={len(in_prog)} BLOCKED={blocked} PENDING={pending}")
for g in in_prog:
    print(f"INPROG_GROUP={g['id']} TITLE={g['title']} ATTEMPTS={g['attempts']} STARTED={g.get('started_at')}")
PYEOF
```

Then tail the active log:

```bash
ls -t .ralph-logs/*.log 2>/dev/null | head -1 | xargs tail -n 60
```

#### Step 3 — Compute flags

- **STUCK:** `in_progress` group's log file's mtime is >60 minutes old. Use:
  ```bash
  log_age=$(( $(date +%s) - $(stat -f %m .ralph-logs/group-N.log) ))
  ```
- **AT RISK:** any group with `attempts >= 2` (one shot left before auto-block).
- **BLOCKED:** any group with status `blocked` since the previous tick.
- **COMPLETE:** all groups status `complete`.

#### Step 4 — Post to Slack

Always post a status, even if uneventful — the user wants to see steady ticks, not silence. Use the homelab watchdog payload shape:

```bash
post_slack() {
  local title="$1" body="$2" color="${3:-#36a64f}"   # green default
  curl -fsS --max-time 10 \
    -H "Content-type: application/json" \
    --data "$(jq -n --arg title "$title" --arg body "$body" --arg color "$color" '{
      attachments: [{
        color: $color,
        blocks: [
          {type: "header", text: {type: "plain_text", text: $title, emoji: true}},
          {type: "section", text: {type: "mrkdwn", text: $body}}
        ]
      }]
    }')" \
    "$RALPH_SLACK_WEBHOOK_URL" > /dev/null
}
```

Color codes: `#36a64f` green (normal tick), `#ECB22E` amber (AT RISK), `#E01E5A` red (STUCK / BLOCKED), `#2EB67D` teal (COMPLETE).

Message body should include:
- Current group + attempt count
- One-line status summary ("3 complete, 1 in-progress, 11 pending")
- Any flag (STUCK / AT RISK / BLOCKED)
- For STUCK/AT-RISK/BLOCKED: the last 5 lines of the log

#### Step 5 — Schedule next tick or end

```
If COMPLETE → post final summary, do NOT call ScheduleWakeup, end.
If BLOCKED  → post alert, do NOT call ScheduleWakeup (human action needed), end.
Otherwise   → call ScheduleWakeup with delaySeconds=1800.
```

The next wakeup re-fires this same skill — the prompt argument is the literal sentinel `<<autonomous-loop-dynamic>>` so the runtime re-injects `/ralph babysitter` instructions.

### Stop conditions (no further wakeups)

- All groups complete.
- Any group blocked (human needed).
- `.ralph-secrets.env` missing (runner ended).
- User explicitly cancelled.

### Concrete first-iteration response template

```
🤖 *RALPH babysitter started.*

Status: 0/15 complete, Group 1 (Workspace move) in progress (attempt 1).
Last log activity: 2 min ago. No flags. Scheduling next tick in 30 min.
```

Keep main-session output concise (~100 words). Slack carries the detail.

### Why a skill, not a raw `/loop` prompt

Encoding the babysitter as a skill (rather than a copy-pasted `/loop` prompt) means:
- One source of truth — fix Slack payload here, every project benefits.
- Slack webhook discovery via the runner's secrets file is automatic.
- The user types `/ralph babysitter` after launching the loop — no copy-paste.

---

## How to Run Cleanup (`/ralph cleanup`)

When the user invokes `/ralph cleanup`, you (the assistant) distill the migration's learning notes into a single archival summary, then delete every ralph artifact. **One-way operation.** After this you cannot `--reset N` and re-run a single group; the whole scaffold is gone.

### Step 1 — Verify completion + scope

Read `.ralph-tasks.json` directly via python (**never** invoke `./scripts/ralph.sh` — the cleanup-trap risk is the same as for the babysitter, even with the sentinel patches in place). Refuse to proceed unless every group is `status: complete`.

```bash
python3 - <<'PYEOF'
import json, sys
with open('.ralph-tasks.json') as f:
    state = json.load(f)
incomplete = [g for g in state['groups'] if g['status'] != 'complete']
if incomplete:
    print("INCOMPLETE:", [(g['id'], g['status']) for g in incomplete])
    sys.exit(1)
print(f"OK_TO_CLEANUP groups={len(state['groups'])}")
PYEOF
```

If incomplete: surface the offending groups to the user and stop. Do **not** offer a `--force` flag implicitly; if the user wants to abandon mid-run, they should ask explicitly and you should confirm they understand they're discarding institutional memory.

Also refuse if a `ralph.sh` process is still running (`pgrep -fl ralph.sh`). The cleanup must follow runner exit, not race it.

### Step 2 — Decide the archive filename

Default: derive a slug from the user's working description (e.g. "v2 migration" → `v2-migration.md`) or from the current branch (`feat/v2` → `v2.md`). Ask the user to confirm the filename before writing — the archive is the migration's permanent record, the name matters.

Target path: `docs/migrations/<slug>.md`. Create `docs/migrations/` if missing.

### Step 3 — Generate the summary

Collect inputs:
- `docs/ralph/shared-context.md` (goal + tech stack)
- `docs/ralph/RALPH_NOTES.md` (the per-group learning notes — the load-bearing source)
- `docs/ralph/RALPH_REPORT.md` (final status)
- `git log --oneline <first-ralph-commit>..HEAD` (commit history)

Delegate the distillation to a haiku subprocess — structured input → structured markdown output is exactly its sweet spot, and the main thread stays cheap. Prompt template:

```
You are summarizing a completed multi-group code migration into one archival
markdown file. The inputs are the shared context, the per-group learning notes,
the final status report, and the git log for the migration range.

Output exactly this shape (no preamble, no AI attribution):

# <Project> — <migration name> (<YYYY-MM-DD> → <YYYY-MM-DD>)

## Goal
<2–4 sentences, distilled from shared-context.md>

## Outcome
<1 paragraph — what landed, what state the codebase is in now>

## Groups
| # | Title | Outcome |
|-|-|-|
(one line per group, "Outcome" is one short clause)

## Architectural decisions that survived
- <bullet — pulled from "Deviations from prompt" where Claude chose differently and it stuck>

## Notable gotchas worth remembering
- <bullet — only the cross-cutting ones; per-group quirks belong in commit messages>

## Deferred work
- <bullet — from "Future improvements" sections>

## Tests added
<count + categories, one sentence>

Be concise. The goal is a reference document a future human can read in 60 seconds.
Do not invent details. If a section is empty, write "—" and move on.
```

Invoke via:
```bash
ANTHROPIC_API_KEY=$(security find-generic-password -s claude-sdk-api-key -w) \
ANTHROPIC_BASE_URL=$(security find-generic-password -s claude-sdk-base-url -w) \
  claude -p --model haiku "$prompt_with_inputs_inlined" > docs/migrations/<slug>.md
```

Show the user the generated file and ask them to confirm before proceeding to deletion. This is the only point where they can still bail.

### Step 4 — Delete artifacts

After user confirmation:
```bash
rm -rf scripts/ralph.sh scripts/ralph-reset.sh
rm -rf docs/ralph/
rm -rf .ralph-tasks.json .ralph-logs/ .ralph-secrets.env
# Remove .gitignore entries that referenced ralph artifacts
```

For `.gitignore`: use `sed` to delete the three lines (`.ralph-tasks.json`, `.ralph-logs/`, `.ralph-secrets.env`) only if they exist — don't strip user's other entries. Prefer reading the file, removing exact-match lines, and writing back via the Edit tool.

Verify nothing ralph-related survives:
```bash
git ls-files | grep -iE 'ralph' || echo "tracked: clean"
ls -la | grep -iE 'ralph' || echo "untracked: clean"
```

### Step 5 — Commit

Single commit:
```
chore(ralph): finalize <migration-name> + cleanup

Archived migration summary to docs/migrations/<slug>.md.
Removed scripts/ralph.sh, scripts/ralph-reset.sh, docs/ralph/, and
gitignored state/log/secrets paths.
```

Stage explicitly — never `git add -A` after a bulk delete (you'll catch unrelated untracked files). Use `git add docs/migrations/<slug>.md .gitignore` then `git add -u` to capture the deletions.

### What NOT to do

- **Never run `./scripts/ralph.sh cleanup`** — cleanup is a Claude-driven playbook, not a bash subcommand. The script's EXIT trap is unsafe for any control-plane operation.
- **Never delete before writing the summary.** If summary generation fails or the user disagrees with the output, you need the source notes to retry.
- **Never delete commits or rewrite history.** Cleanup removes artifacts going forward; the per-group commits in git history are the audit trail.
- **Never run cleanup while `pgrep ralph.sh` returns a PID.** The trap-vs-runner race is the same as the babysitter case.

---

## Anti-Patterns to Avoid

- **God groups**: one group does everything — split it
- **Underspecified validation**: "it should work" — name the exact commands
- **No research step in prompt**: Claude invents APIs it doesn't know — always include "Research First"
- **Skipping the notes template**: the notes file is the institutional memory — don't skip it
- **Overly prescriptive prompts**: include key interfaces and constraints, not a full implementation spec — leave Claude room to find better approaches
- **E2E-only validation**: E2E is slow and fragile for early groups; use unit tests until the system is wired together
- **Strictness baseline at the end**: adding `noUncheckedIndexedAccess`, extended lint plugins, or React Compiler as the final group creates a cascade-error pit. Land the rules early — Group 3 or 4 — even if tests/CI stay at the end.
- **Operating on `master` / `main`**: autonomous commits to the default branch are unsafe — `deploy.yml` typically fires on push. The runner must refuse to start there. Use a simple guard, not a long-lived branch creator (users normally checkout their own feature branch first).
- **Committing without disabling 1Password signing**: on macOS with `op-ssh-sign` and `commit.gpgsign=true`, every commit hangs on Touch ID. Always disable per-repo signing at runner startup; restore via `trap` on exit. Never use `--no-gpg-sign` (violates user commit rules).
- **No `op whoami` pre-flight**: if any group invokes `op run`, an inactive 1Password session blocks mid-loop at 3am. Verify at startup with a `gtimeout 5 op whoami` check; exit fast and tell the user how to sign in.
- **`op run` in group prompts**: even with a warm session, mid-loop `op` invocations risk Touch ID prompts (depends on per-command biometric settings). Pre-fetch every loop-needed secret at startup, write to `.ralph-secrets.env` (mode 600, gitignored, trap-cleaned), source it into runner env so `claude -p` children inherit it, and rewrite group prompts to reference env vars instead of `op run`. Reserve `op run` for hands-on-keyboard groups (cutover, manual).
- **Inventing throwaway local creds**: don't make the agent hardcode local dev passwords (e.g. `argo:argo`). If the production secret is in 1Password, pre-fetch it once and reuse for both local container (`POSTGRES_PASSWORD: ${PROJECT_DB_PASSWORD}`) and prod. One source of truth eliminates a class of "the agent invented something that collides" footguns.
- **No push-block hook**: shared context says "commit don't push" but an autonomous agent can violate it. Drop a `pre-push` hook that exits 1 at runner startup; restore on exit trap.
- **Cutover-only data migration testing**: when a migration involves data (DB ports, schema changes), don't wait until cutover to first exercise the migration script. Pull production data snapshot to local and run the migration script during the early group that introduces the new system. Every later group develops against realistic data and the cutover becomes "run the same script again" — high confidence, low risk surface.
- **No babysitter on overnight runs**: a stuck group can burn 3 × 45min before the runner marks it blocked, then sit idle until you check back. A 30-min `/loop` babysitter detects stuck states in time to act. See the Babysitter Pattern section above.
- **Babysitter shelling into `ralph.sh`**: invoking `./scripts/ralph.sh --status` (or `--reset`) from the babysitter is unsafe — the script's EXIT trap runs `remove_secrets` / `remove_push_guard` regardless of subcommand. The running runner is unaffected (env was sourced before the trap), but the babysitter loses `.ralph-secrets.env` (and with it `RALPH_SLACK_WEBHOOK_URL`), forcing a Touch ID prompt on every subsequent tick. Fix in two places: gate cleanup with a `<name>_INSTALLED` sentinel that only `prefetch_secrets` / `install_push_guard` flip true, AND make the babysitter read `.ralph-tasks.json` directly via python rather than calling the script at all.
- **Invoking interactive slash-skills (`/commit`, `/commit --split`, `/pr`, `/check`, `/review`, `/ship`) from inside a group**: these are interactive Claude Code workflows that propose a plan and *wait for user confirmation*. In `claude -p` headless mode there is no user — the model prints the proposal, the tool call returns "success" without producing a commit/PR/etc., and the group exits with no `RALPH_TASK_COMPLETE` signal. The runner then resets the group to pending, the working tree is left dirty with all of the group's actual work uncommitted, and the human gets paged. Symptom in the log: `RESULT_OBJ` shows `subtype: "success"`, but the last few text blocks discuss a "split commit strategy" instead of acting; final tool calls are `git status` / `Skill: ...` rather than `git commit`. Fix: group prompts must use raw shell (`git add <files> && git commit -m "..."`) and shared-context.md must explicitly forbid `/commit` and friends. Build/check tasks should run the underlying tool directly (`bun test`, `bun run typecheck`, `bun run lint`), never `/check`.
