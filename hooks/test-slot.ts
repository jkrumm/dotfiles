#!/usr/bin/env bun

/**
 * PreToolUse hook: put test runners through the factory's test slot.
 *
 * 2026-11-05/06: load reached 346 on 12 cores, largely from vitest and pytest runs in
 * sessions that never passed through `factory slot run`. The factory admits its own leads
 * under load; a session outside it (or an IuRoot `make check`) is unbounded. This hook
 * bounds them from the dotfiles side, for every Claude Code session on the machine.
 *
 * A Bash command that *invokes* a test runner in command position (vitest, jest, pytest,
 * `bun test`, `npm test`, `make check`, `go test`, ...; quoted text is data, see
 * docker-makefile.ts) is rewritten, not denied:
 *
 *     factory slot run --name <repo> -- env FACTORY_SLOT_ACTIVE=1 VITEST_MAX_WORKERS=<n> … sh -c '<command>'
 *
 * The slot waits on contention, so two runs started at once run one after the other
 * (as many at once as the server has slots, `FACTORY_SLOTS`). Worker caps (half the cores,
 * the figure `agw check` uses) apply to the wrapped run unless the caller set them.
 *
 * Left alone, so a check never takes a second slot while it holds one (two such runs would
 * each hold one and wait on the other until the 45-minute limit):
 *   - the session is already inside a slot (`FACTORY_SLOT_ACTIVE`);
 *   - the command already calls `factory slot run` or `agw` (`agw check` takes its own slot);
 *   - the project's Makefile or package.json already says `slot run` (software-factory's
 *     `make test` and the like).
 *
 * Fail open: no `factory` binary on PATH (the MacBook, CI) or an unparseable payload means
 * the command runs as written. A factory server that is down is handled by `factory slot run`
 * itself: it runs the command anyway with one line on stderr.
 *
 * A leading `cd <dir> &&` stays outside the wrapper so the session's cwd still follows it.
 */

import { existsSync, readFileSync } from "node:fs";
import { cpus } from "node:os";
import { splitIntoCommands } from "./docker-makefile.ts";

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
  cwd?: string;
}

/** Commands that run another command; peeled to find the real program. */
const WRAPPERS = new Set(["sudo", "env", "command", "nice", "nohup", "stdbuf", "time", "exec"]);

/** Package runners whose next token is the program (`npx vitest`). */
const RUNNERS = new Set(["npx", "bunx", "pnpx"]);

const JS_TEST_BINARIES = new Set(["vitest", "jest", "pytest", "py.test", "mocha"]);

/** `npm|pnpm|yarn|bun run <script>`: a script that tests or checks. */
const TEST_SCRIPT = /^(test|tests|check|e2e)([-:_].+)?$/;
const MAKE_TARGET = /^(check|test|tests|e2e)([-:_].+)?$/;

function basename(token: string): string {
  return token.split("/").pop() ?? token;
}

/** Drop env assignments and wrapper commands (with their flags) from the front. */
function peel(tokens: string[]): string[] {
  let i = 0;
  let sawWrapper = false;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) i++;
    else if (sawWrapper && t.startsWith("-")) i++;
    else if (WRAPPERS.has(basename(t))) {
      sawWrapper = true;
      i++;
    } else break;
  }
  return tokens.slice(i);
}

/** The runner name when this simple command is a test run, else null. */
export function testRunner(simple: string[]): string | null {
  const tokens = peel(simple);
  if (tokens.length === 0) return null;
  const name = basename(tokens[0]);
  const args = tokens.slice(1);
  const positional = args.filter((a) => !a.startsWith("-"));

  if (JS_TEST_BINARIES.has(name)) return name;
  if (RUNNERS.has(name)) return args.length ? testRunner(args) : null;

  switch (name) {
    case "playwright":
      return positional[0] === "test" ? "playwright" : null;
    case "bun":
      if (positional[0] === "test") return "bun test";
      if (positional[0] === "run" && TEST_SCRIPT.test(positional[1] ?? "")) return `bun run ${positional[1]}`;
      if (positional[0] === "x" || positional[0] === "run") return testRunner(positional.slice(1));
      return null;
    case "npm":
    case "pnpm":
    case "yarn":
      if (positional[0] === "test" || positional[0] === "t") return `${name} test`;
      if (positional[0] === "run" && TEST_SCRIPT.test(positional[1] ?? "")) return `${name} run ${positional[1]}`;
      if (name !== "npm" && TEST_SCRIPT.test(positional[0] ?? "")) return `${name} ${positional[0]}`;
      if (["exec", "dlx"].includes(positional[0] ?? "")) return testRunner(positional.slice(1));
      return null;
    case "make":
    case "gmake": {
      const target = positional.find((a) => !a.includes("="));
      return target && MAKE_TARGET.test(target) ? `make ${target}` : null;
    }
    case "python":
    case "python3": {
      const m = args.indexOf("-m");
      return m !== -1 && ["pytest", "unittest"].includes(args[m + 1] ?? "") ? `python -m ${args[m + 1]}` : null;
    }
    case "uv":
    case "poetry":
      return positional[0] === "run" ? testRunner(positional.slice(1)) : null;
    case "cargo":
    case "go":
      return positional[0] === "test" ? `${name} test` : null;
    case "xcodebuild":
      return positional.some((a) => a === "test" || a === "test-without-building") ? "xcodebuild test" : null;
    default:
      return null;
  }
}

/** Commands that take their own slot, or are the slot: never wrap those. */
function takesOwnSlot(simple: string[]): boolean {
  const tokens = peel(simple);
  const name = basename(tokens[0] ?? "");
  if (name === "agw") return true;
  return name === "factory" && tokens[1] === "slot";
}

/** Does the project's Makefile or package.json already run its tests through `slot run`? */
function projectHasSlot(dir: string): boolean {
  for (const file of ["Makefile", "package.json"]) {
    try {
      if (readFileSync(`${dir}/${file}`, "utf8").includes("slot run")) return true;
    } catch {
      // no such file: nothing to find
    }
  }
  return false;
}

/** `cd <dir> && rest` with a plain directory word: the part that must stay outside the wrapper. */
const LEADING_CD = /^cd\s+((?:"[^"$`\\]+"|'[^']+'|[\w@%+=:,./~-]+))\s*&&\s*([\s\S]+)$/;

function shQuote(text: string): string {
  return `'${text.replace(/'/g, `'\\''`)}'`;
}

function repoName(cwd: string): string {
  const main = cwd.replace(/\/\.claude\/worktrees\/.*$/, "");
  return basename(main) || "session";
}

export interface Rewrite {
  command: string;
  runner: string;
}

/**
 * The wrapped command, or null when the command is left as written.
 * `cores` and `which` are parameters so tests do not depend on the machine.
 */
export function rewrite(
  command: string,
  opts: { cwd: string; env: Record<string, string | undefined>; cores: number; hasFactory: boolean },
): Rewrite | null {
  if (!opts.hasFactory || opts.env.FACTORY_SLOT_ACTIVE) return null;

  const simples = splitIntoCommands(command);
  if (simples.some(takesOwnSlot)) return null;

  const runner = simples.map(testRunner).find((r): r is string => r !== null);
  if (!runner) return null;

  let prefix = "";
  let body = command.trim();
  let dir = opts.cwd;
  const cd = LEADING_CD.exec(body);
  if (cd) {
    prefix = `cd ${cd[1]} && `;
    body = cd[2];
    const target = cd[1].replace(/^["']|["']$/g, "");
    dir = target.startsWith("/") ? target : target.startsWith("~") ? (opts.env.HOME ?? "") + target.slice(1) : `${opts.cwd}/${target}`;
  }
  if (existsSync(dir) && projectHasSlot(dir)) return null;

  const workers = Math.max(1, Math.floor(opts.cores / 2));
  const caps = [
    `"VITEST_MAX_WORKERS=\${VITEST_MAX_WORKERS:-${workers}}"`,
    `"PYTEST_XDIST_AUTO_NUM_WORKERS=\${PYTEST_XDIST_AUTO_NUM_WORKERS:-${workers}}"`,
  ].join(" ");
  const shell = '"${SHELL:-/bin/sh}"';
  const wrapped =
    `${prefix}factory slot run --name ${shQuote(`${repoName(dir)} ${runner}`)} -- ` +
    `env FACTORY_SLOT_ACTIVE=1 ${caps} ${shell} -c ${shQuote(body)}`;
  return { command: wrapped, runner };
}

// ── Main ─────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  try {
    const input: HookInput = JSON.parse(await Bun.stdin.text());
    if (input.tool_name !== "Bash") process.exit(0);
    const command = input.tool_input?.command ?? "";
    const result = rewrite(command, {
      cwd: input.cwd ?? process.cwd(),
      env: process.env,
      cores: cpus().length,
      hasFactory: Bun.which("factory") !== null,
    });
    if (!result) process.exit(0);
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          permissionDecisionReason: `test runner (${result.runner}) runs in the factory test slot`,
          updatedInput: { ...input.tool_input, command: result.command },
        },
      }),
    );
  } catch {
    // fail open: never block a command because the hook broke
  }
  process.exit(0);
}
