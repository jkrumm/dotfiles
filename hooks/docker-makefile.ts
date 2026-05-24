#!/usr/bin/env bun

/**
 * PreToolUse hook: prefer Makefile targets over raw docker/docker-compose commands.
 *
 * When a Bash command contains docker/docker-compose and the cwd has a Makefile,
 * denies the command and tells Claude to use `make` targets instead.
 *
 * If no Makefile exists in the project, the command is allowed through.
 *
 * Read-only docker commands (ps, logs, inspect, images) are always allowed —
 * they don't involve orchestration context that Makefiles encode.
 *
 * `docker exec` is also always allowed: it runs commands inside an
 * already-running container and carries no Compose orchestration context.
 */

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
  cwd?: string;
}

// Match docker/docker-compose only as a command (start of string or after pipe/chain/subshell),
// not as part of a filename like "docker-makefile.ts"
const DOCKER_PATTERN = /(?:^|[|;&]\s*|(?:&&|\|\|)\s*)(?:sudo\s+)?(docker\s+compose|docker-compose|docker)\b/;

// Commands that don't need Makefile orchestration: read-only inspection plus
// `docker exec` (runs inside an already-running container, no Compose context).
const ALLOWED_SUBCOMMANDS = /(?:^|[|;&]\s*|(?:&&|\|\|)\s*)(?:sudo\s+)?(docker|docker-compose|docker\s+compose)\s+(ps|logs|inspect|images|stats|top|port|version|info|exec)\b/;

function findGitRoot(cwd: string): string | null {
  const result = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return null;
  return result.stdout.toString().trim();
}

function hasMakefile(dir: string): boolean {
  const result = Bun.spawnSync(["test", "-f", `${dir}/Makefile`], {
    stdout: "pipe",
    stderr: "pipe",
  });
  return result.exitCode === 0;
}

function getMakeTargets(dir: string): string[] {
  const result = Bun.spawnSync(
    ["make", "-pnRr"],
    { cwd: dir, stdout: "pipe", stderr: "pipe" }
  );
  if (result.exitCode !== 0) return [];

  const output = result.stdout.toString();
  const targets: string[] = [];

  for (const line of output.split("\n")) {
    // Lines like "target: deps" that aren't built-in
    if (
      line.match(/^[a-zA-Z][\w-]*\s*:/) &&
      !line.startsWith(".") &&
      !line.includes("=")
    ) {
      const target = line.split(":")[0].trim();
      if (target && !target.startsWith("_") && target !== "Makefile") {
        targets.push(target);
      }
    }
  }

  return [...new Set(targets)].sort();
}

function deny(reason: string): never {
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

const input: HookInput = JSON.parse(await Bun.stdin.text());

if (input.tool_name !== "Bash") process.exit(0);

const command = (input.tool_input?.command ?? "").trim();

// Not a docker command — allow
if (!DOCKER_PATTERN.test(command)) process.exit(0);

// Read-only inspection + `docker exec` are always fine
if (ALLOWED_SUBCOMMANDS.test(command)) process.exit(0);

// Check for Makefile in project root
const cwd = input.cwd ?? process.cwd();
const root = findGitRoot(cwd) ?? cwd;

if (!hasMakefile(root)) process.exit(0);

// Makefile exists — deny and suggest targets
const targets = getMakeTargets(root);
const targetList = targets.length > 0
  ? `Available targets: ${targets.join(", ")}`
  : "Run `make` or `make help` to see available targets.";

deny(
  [
    "Raw docker/docker-compose commands are blocked when a Makefile exists.",
    "",
    "Makefiles in this project encode secret injection, deployment order, and required flags.",
    "Use the appropriate `make` target instead.",
    "",
    targetList,
    "",
    "If no target fits your need, ask the user rather than running docker directly.",
  ].join("\n")
);
