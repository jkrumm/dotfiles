#!/usr/bin/env bun

/**
 * PreToolUse hook: enforce PR workflow only for repos that actually need it.
 *
 * Default: every repo is direct-to-master — the hook does nothing.
 * Exception: a small denylist of repos where Claude Code must go through a PR.
 *
 * PR-required repos:
 *   - basalt-ui            (NPM published — broken main blocks next release)
 *   - free-planning-poker  (live web app)
 *   - rollhook             (production deployment tool)
 *   - rollhook-action      (consumed via GitHub Marketplace)
 *   - any repo under ~/IuRoot/  (work, PR workflow against `main`)
 *
 * Escape hatch — `directToMain` in pr-required-repos.json:
 *   Repos listed there are NEVER PR-required even if they'd otherwise match
 *   (e.g. a greenfield single-operator agent under ~/IuRoot/ that pushes
 *   straight to main). The directToMain list wins over both the denylist and
 *   the ~/IuRoot/ path rule.
 *
 * For PR-required repos, BLOCKED:
 *   git push ... main/master      — any push targeting a protected branch
 *   git push (no ref)             — when currently on main/master
 *   git push --force / -f         — unconditional force push to any branch
 *
 * For PR-required repos, ALLOWED:
 *   git commit (anywhere)                      — local commits are always fine
 *   git push origin feature-branch             — normal push to feature branch
 *   git push --force-with-lease origin feat/*  — safe force to feature branch
 *
 * TO BYPASS (as jkrumm):
 *   Run the command directly in your terminal — Claude Code hook does not apply.
 *   GitHub Rulesets enforce PR-required at the server level with admin bypass.
 *
 * ── Which repo is being pushed to (fixed 2026-09-10) ─────────────────────────
 *
 * The gate used to resolve the repo from the SESSION cwd alone. A Bash command
 * routinely acts on a different repo via `cd <path> &&` or `git -C <path>`, and
 * the hook could not see that: a session opened in a PR-required repo refused
 * every push to a protected branch in EVERY other repo, including the ones the
 * denylist deliberately omits. Measured cost — a fleet upgrade run from
 * `basalt-ui` stranded commits in six direct-to-master repos (rb, image-share,
 * image-gen, linewatch, weatherorb, basalt-ui-obsidian) and burned a session
 * rediscovering why.
 *
 * `repoDirectories()` now reads the target out of the command. An explicit
 * target REPLACES the session cwd rather than adding to it — a union would
 * re-create the bug, since the session cwd is exactly the repo the operator
 * navigated away from. When nothing explicit resolves to a real directory the
 * session cwd is the fallback, so an unparseable command still fails SAFE.
 *
 * The command is parsed with the shell tokenizer the docker-makefile hook
 * already carries (quotes, heredocs and command substitution are data, not
 * commands) rather than regex-scanning the raw string. That scan matched the
 * branch name anywhere it appeared — including inside a commit message body,
 * which is how writing this very file got blocked once.
 */

import { effectiveCwd, expandPath, isDirectory, splitIntoCommands } from "./docker-makefile";

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
  cwd?: string;
}

const PROTECTED = ["main", "master"];

// Repos where Claude Code must go through a PR (everything else is direct-to-master).
// Single source of truth: ~/.claude/pr-required-repos.json (symlinked from
// dotfiles/config/pr-required-repos.json), shared with scripts/github-config.sh.
// Fallback array is used only if that file is missing/unreadable — failing safe
// (keep protecting the known apps) rather than failing open.
const PR_REQUIRED_FALLBACK = ["basalt-ui", "free-planning-poker", "rollhook", "rollhook-action"];

export interface RepoConfig {
  prRequired: string[];
  directToMain: string[];
}

export async function loadRepoConfig(): Promise<RepoConfig> {
  try {
    const f = Bun.file(`${process.env.HOME}/.claude/pr-required-repos.json`);
    if (await f.exists()) {
      const data = (await f.json()) as { repos?: unknown; directToMain?: unknown };
      const prRequired =
        Array.isArray(data.repos) && data.repos.every((r) => typeof r === "string")
          ? (data.repos as string[])
          : PR_REQUIRED_FALLBACK;
      const directToMain =
        Array.isArray(data.directToMain) && data.directToMain.every((r) => typeof r === "string")
          ? (data.directToMain as string[])
          : [];
      return { prRequired, directToMain };
    }
  } catch {
    // fall through to fallback
  }
  return { prRequired: PR_REQUIRED_FALLBACK, directToMain: [] };
}

// ── Reading the git invocation ───────────────────────────────────────────────

/** git's own global flags that consume the following token as their value. */
const GIT_VALUE_FLAGS = new Set([
  "-C",
  "-c",
  "--namespace",
  "--work-tree",
  "--git-dir",
  "--exec-path",
]);

/** `git push` flags that consume the following token as their value. */
const PUSH_VALUE_FLAGS = new Set(["-o", "--push-option", "--repo", "--receive-pack", "--exec"]);

/** Strip a leading path so `/usr/local/bin/git` reads as `git`. */
function basename(token: string): string {
  const cut = token.lastIndexOf("/");
  return cut === -1 ? token : token.slice(cut + 1);
}

export interface GitInvocation {
  /** The subcommand, e.g. `push`. Null when the tokens are only global flags. */
  subcommand: string | null;
  /** Everything after the subcommand. */
  args: string[];
  /** Every `-C <dir>` handed to git, unresolved. */
  cDirs: string[];
}

/**
 * Read one tokenized command as a git invocation, or null if it isn't one.
 *
 * Walks git's global flags rather than assuming the subcommand sits at index 1,
 * so `git -C repo -c user.name=x push` classifies as a push against `repo`.
 * A wrapper prefix (`timeout 60 git …`, `command git …`) is tolerated.
 */
export function inspectGit(tokens: string[]): GitInvocation | null {
  const g = tokens.findIndex((t) => basename(t) === "git");
  if (g === -1) return null;

  const cDirs: string[] = [];
  let i = g + 1;
  while (i < tokens.length) {
    const token = tokens[i];
    if (!token.startsWith("-")) break;
    if (GIT_VALUE_FLAGS.has(token)) {
      if (token === "-C" && tokens[i + 1] !== undefined) cDirs.push(tokens[i + 1]);
      i += 2;
      continue;
    }
    i++;
  }

  return { subcommand: tokens[i] ?? null, args: tokens.slice(i + 1), cDirs };
}

// ── Which directory the command acts on ──────────────────────────────────────

/**
 * The repo directories this command actually touches, most specific first.
 *
 * An explicit target (`git -C <dir>`, a leading `cd <dir> &&`) replaces the
 * session cwd; the session cwd is the fallback only when nothing explicit
 * resolves to a real directory.
 */
export function repoDirectories(command: string, sessionCwd: string): string[] {
  const cwd = effectiveCwd(command, sessionCwd);

  const explicit: string[] = [];
  for (const tokens of splitIntoCommands(command)) {
    const git = inspectGit(tokens);
    if (!git) continue;
    for (const dir of git.cDirs) explicit.push(expandPath(dir, cwd));
  }
  if (cwd !== sessionCwd) explicit.push(cwd);

  const resolved = [...new Set(explicit)].filter(isDirectory);
  return resolved.length > 0 ? resolved : [sessionCwd];
}

// ── What the push does ───────────────────────────────────────────────────────

export type PushKind =
  | { kind: "none" }
  /** `--force`/`-f` without `--force-with-lease` — blocked on every branch. */
  | { kind: "hard-force" }
  /** A refspec naming a protected branch outright. */
  | { kind: "protected-ref" }
  /** No refspec (or `HEAD`) — blocked only if the current branch is protected. */
  | { kind: "current-branch" };

/** The branch a refspec writes to: `+HEAD:refs/heads/master` → `master`. */
function destinationBranch(refspec: string): string {
  const stripped = refspec.replace(/^\+/, "");
  const colon = stripped.lastIndexOf(":");
  const dest = colon === -1 ? stripped : stripped.slice(colon + 1);
  return dest.replace(/^refs\/heads\//, "");
}

/**
 * Classify the strongest `git push` in a command.
 *
 * Reads the push's own tokens, so a branch name appearing in a commit message,
 * a path or a heredoc body is data — the old whole-string regex blocked on it.
 */
export function inspectPush(command: string): PushKind {
  let verdict: PushKind = { kind: "none" };

  for (const tokens of splitIntoCommands(command)) {
    const git = inspectGit(tokens);
    if (!git || git.subcommand !== "push") continue;

    const { args } = git;
    const hardForce =
      (args.includes("--force") || args.includes("-f")) && !args.includes("--force-with-lease");
    if (hardForce) return { kind: "hard-force" };

    const positional: string[] = [];
    for (let j = 0; j < args.length; j++) {
      if (PUSH_VALUE_FLAGS.has(args[j])) {
        j++;
        continue;
      }
      if (args[j].startsWith("-")) continue;
      positional.push(args[j]);
    }

    // positional: [] bare, [remote], [remote, ...refspecs]
    const refspecs = positional.slice(1);
    if (refspecs.some((spec) => PROTECTED.includes(destinationBranch(spec)))) {
      verdict = { kind: "protected-ref" };
      continue;
    }
    if (refspecs.length === 0 || refspecs.every((spec) => spec === "HEAD")) {
      if (verdict.kind === "none") verdict = { kind: "current-branch" };
    }
  }

  return verdict;
}

// ── Repo identity ────────────────────────────────────────────────────────────

function getRepoName(cwd: string): string | null {
  const result = Bun.spawnSync(["git", "remote", "get-url", "origin"], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return null;
  const url = result.stdout.toString().trim();
  // Handles both SSH (git@github.com:user/repo.git) and HTTPS formats
  const match = url.match(/\/([^/]+?)(?:\.git)?$/);
  return match?.[1] ?? null;
}

function isIuRootRepo(cwd: string): boolean {
  // Work repos live under ~/IuRoot/ (and ~/IuRoot/<repo>.worktrees/<branch>).
  // toplevel resolves both cases; symlinks normalised via realpath.
  const result = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return false;
  const top = result.stdout.toString().trim();
  return top.includes("/IuRoot/");
}

function getCurrentBranch(cwd: string): string | null {
  const result = Bun.spawnSync(["git", "branch", "--show-current"], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return null;
  return result.stdout.toString().trim() || null;
}

export function requiresPR(dir: string, { prRequired, directToMain }: RepoConfig): boolean {
  const repoName = getRepoName(dir);
  // directToMain is the explicit escape hatch — it wins over both the denylist
  // and the ~/IuRoot/ path rule (e.g. a greenfield agent that pushes to main).
  if (repoName !== null && directToMain.includes(repoName)) return false;
  return (repoName !== null && prRequired.includes(repoName)) || isIuRootRepo(dir);
}

function block(reason: string): never {
  const output = JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  });
  process.stdout.write(output);
  process.exit(0);
}

// ── Main ─────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  const input: HookInput = JSON.parse(await Bun.stdin.text());

  if (input.tool_name !== "Bash") process.exit(0);

  const command = (input.tool_input?.command ?? "").trim();
  const push = inspectPush(command);
  if (push.kind === "none") process.exit(0);

  const config = await loadRepoConfig();
  const enforceDir = repoDirectories(command, input.cwd ?? process.cwd()).find((dir) =>
    requiresPR(dir, config)
  );
  if (!enforceDir) process.exit(0);

  if (push.kind === "hard-force") {
    block(
      [
        "git push --force is blocked in Claude Code.",
        "",
        "Claude Code must not rewrite history on remote branches.",
        "Use --force-with-lease for feature branches (safe: fails if remote has new commits).",
        "To force push: run the command directly in your terminal.",
      ].join("\n")
    );
  }

  if (push.kind === "protected-ref") {
    block(
      [
        `Pushing to a protected branch is blocked in Claude Code — ${enforceDir} requires a PR.`,
        "",
        "All changes must go through a pull request:",
        "  1. Work on a feature branch",
        "  2. git push origin <feature-branch>",
        "  3. /pr create",
        "",
        "To push directly: run the command in your terminal (admin bypass).",
      ].join("\n")
    );
  }

  const current = getCurrentBranch(enforceDir);
  if (current && PROTECTED.includes(current)) {
    block(
      [
        `Pushing to protected branch '${current}' is blocked in Claude Code — ${enforceDir} requires a PR.`,
        "",
        `You are on '${current}'. Create a feature branch instead:`,
        "  git checkout -b feat/your-change",
        "",
        "To push directly: run the command in your terminal (admin bypass).",
      ].join("\n")
    );
  }
}

// git commit on a protected branch is intentionally allowed — local commits are safe.
// Move to a branch before pushing: git checkout -b feat/your-change
