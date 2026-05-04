#!/usr/bin/env bun

/**
 * PreToolUse hook: Claude Code must never commit or push to protected branches.
 *
 * Protected branches: main, master
 *
 * BLOCKED:
 *   git push ... main/master      — any push targeting a protected branch
 *   git push (no ref)             — when currently on main/master
 *   git push --force / -f         — unconditional force push to any branch
 *
 * ALLOWED:
 *   git commit (anywhere)                      — local commits are always fine
 *   git push origin feature-branch             — normal push to feature branch
 *   git push --force-with-lease origin feat/*  — safe force to feature branch
 *
 * TO BYPASS (as jkrumm):
 *   Run the command directly in your terminal — Claude Code hook does not apply.
 *   GitHub Rulesets enforce PR-required at the server level with admin bypass.
 */

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
  cwd?: string;
}

const PROTECTED = ["main", "master"];

// Repos where direct pushes to main/master are allowed (infra/config repos, no PR workflow)
const UNPROTECTED_REPOS = ["homelab", "homelab-private", "vps", "dotfiles", "hermes-agent", "basalt-ui-playground", "sideclaw"];

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

function getCurrentBranch(cwd: string): string | null {
  const result = Bun.spawnSync(["git", "branch", "--show-current"], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return null;
  return result.stdout.toString().trim() || null;
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

const input: HookInput = JSON.parse(await Bun.stdin.text());

if (input.tool_name !== "Bash") process.exit(0);

// Skip protection for infra/config repos that use direct-to-main workflow
const repoName = getRepoName(input.cwd ?? process.cwd());
if (repoName && UNPROTECTED_REPOS.includes(repoName)) process.exit(0);

const command = (input.tool_input?.command ?? "").trim();
const cwd = input.cwd ?? process.cwd();

// ── git push ──────────────────────────────────────────────────────────────────

if (/\bgit\s+push\b/.test(command)) {
  // Block --force / -f (not --force-with-lease)
  const isHardForce =
    /(?:^|\s)--force(?:\s|$)/.test(command) ||
    /(?:^|\s)-f(?:\s|$)/.test(command);

  if (isHardForce && !command.includes("--force-with-lease")) {
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

  // Block explicit push to main/master (e.g. "git push origin main", "HEAD:master")
  const protectedRef = new RegExp(
    `(?:^|\\s|:)(${PROTECTED.join("|")})(?:\\s|$)`
  );
  if (protectedRef.test(command)) {
    block(
      [
        "Pushing to a protected branch (main/master) is blocked in Claude Code.",
        "",
        "All changes must go through a pull request:",
        "  1. Work on a feature branch",
        "  2. git push origin <feature-branch>",
        "  3. /pr create",
        "",
        "To push directly to main/master: run the command in your terminal (admin bypass).",
      ].join("\n")
    );
  }

  // Block push when current branch is main/master — covers:
  //   git push                        (bare push, no ref)
  //   git push origin                 (remote only, no ref)
  //   git push origin HEAD            (HEAD resolves to current branch)
  //   git push -u origin HEAD         (same with tracking flag)
  const stripped = command
    .replace(/\bgit\s+push\b/, "")
    .replace(/--[\w-]+(=\S+)?/g, "")
    .replace(/(?:^|\s)-\w+/g, "")
    .trim();
  const positional = stripped.split(/\s+/).filter(Boolean);
  // positional: [] = bare, ["origin"] = remote only, ["origin", "HEAD"] = HEAD ref
  const refArg = positional[1]; // undefined, "HEAD", or a branch name
  const pushesToCurrentBranch = !refArg || refArg === "HEAD";

  if (pushesToCurrentBranch) {
    const current = getCurrentBranch(cwd);
    if (current && PROTECTED.includes(current)) {
      block(
        [
          `Pushing to protected branch '${current}' is blocked in Claude Code.`,
          "",
          `You are on '${current}'. Create a feature branch instead:`,
          "  git checkout -b feat/your-change",
          "",
          "To push directly: run the command in your terminal (admin bypass).",
        ].join("\n")
      );
    }
  }
}

// git commit on main/master is intentionally allowed — local commits are safe.
// Move to a branch before pushing: git checkout -b feat/your-change

process.exit(0);
