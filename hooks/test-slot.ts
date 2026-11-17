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
 *   - the project's Makefile or package.json already says `slot run` or `agw check`
 *     (software-factory's `make test` and the like).
 *
 * Fail open: no `factory` binary on PATH (the MacBook, CI) or an unparseable payload means
 * the command runs as written. A factory server that is down is handled by `factory slot run`
 * itself: it runs the command anyway with one line on stderr.
 *
 * In a chain of `&&` / `;` / newline segments only the segment that runs a test takes the slot
 * (`vite build && factory slot run … -c 'bun test x'`); the build is not queued behind other tests,
 * and a `cd <dir>` segment stays outside so the session's cwd still follows it. A chain that cannot
 * be cut safely (`||`, `&`, subshells, heredocs, `for … do … done`, a segment that leaves shell state
 * such as `PORT=4000;` or `set -o pipefail;`) takes one slot whole.
 */

import { existsSync, readFileSync } from "node:fs";
import { cpus } from "node:os";
import { resolve } from "node:path";
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

const UV_VALUE_FLAGS = new Set(["--with", "--python", "-p", "--project", "--directory", "--extra", "--group", "--with-requirements", "--env-file"]);

const JS_TEST_BINARIES = new Set(["vitest", "jest", "pytest", "py.test", "mocha"]);

/** `npm|pnpm|yarn|bun run <script>`: a script that tests or checks. */
const TEST_SCRIPT = /^(test|tests|check|e2e)([-:_].+)?$/;
// One optional word prefix (`ui-check`, `api-test`): a monorepo/IuRoot Makefile scopes its gates by area, and the
// 2026-11-11 load-212 incident was three `make ui-check` (vitest, 12 workers each) running outside any slot.
const MAKE_TARGET = /^([a-z0-9]+[-_])?(check|test|tests|e2e)([-:_].+)?$/;

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
  if (RUNNERS.has(name)) return testRunner(args.filter((a) => !a.startsWith("-")));

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
      // Every positional, not the first: `make -C dir check` and `make -j 4 test` carry flag values.
      const target = positional.find((a) => MAKE_TARGET.test(a));
      return target ? `make ${target}` : null;
    }
    case "python":
    case "python3": {
      const m = args.indexOf("-m");
      return m !== -1 && ["pytest", "unittest"].includes(args[m + 1] ?? "") ? `python -m ${args[m + 1]}` : null;
    }
    case "uv":
    case "poetry": {
      const run = args.indexOf("run");
      if (run === -1) return null;
      // Skip flags after `run`, and the value of the ones that take one (`uv run --with x pytest`).
      const rest = args.slice(run + 1);
      let k = 0;
      while (k < rest.length && rest[k].startsWith("-")) k += UV_VALUE_FLAGS.has(rest[k]) ? 2 : 1;
      return testRunner(rest.slice(k));
    }
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

/** Does the project's Makefile or package.json already take a slot itself (`slot run`, or `agw check`, which does)? */
function projectHasSlot(dir: string): boolean {
  for (const file of ["Makefile", "package.json"]) {
    try {
      if (readFileSync(`${dir}/${file}`, "utf8").match(/slot run|agw check/)) return true;
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

  const segments = splitChain(command);
  if (segments && segments.length > 1) return rewriteSegments(segments, opts);

  // One segment, or a chain that cannot be split safely: the whole command takes the slot.
  let prefix = "";
  let body = command.trim();
  let dir = opts.cwd;
  const cd = LEADING_CD.exec(body);
  if (cd) {
    prefix = `cd ${cd[1]} && `;
    body = cd[2];
    dir = resolveDir(cd[1], opts.cwd, opts.env);
  }
  if (existsSync(dir) && projectHasSlot(dir)) return null;
  return { command: prefix + slotWrap(body, dir, runner, opts.cores), runner };
}

/** Where `cd <word>` leads from `base`; `cd -` is unknown, so the directory stays. */
function resolveDir(word: string, base: string, env: Record<string, string | undefined>): string {
  const target = word.replace(/^["']|["']$/g, "");
  if (target === "-") return base;
  return resolve(base, target.startsWith("~") ? (env.HOME ?? "") + target.slice(1) : target);
}

function slotWrap(body: string, dir: string, runner: string, cores: number): string {
  const workers = Math.max(1, Math.floor(cores / 2));
  const caps = [
    `"VITEST_MAX_WORKERS=\${VITEST_MAX_WORKERS:-${workers}}"`,
    `"PYTEST_XDIST_AUTO_NUM_WORKERS=\${PYTEST_XDIST_AUTO_NUM_WORKERS:-${workers}}"`,
  ].join(" ");
  const shell = '"${SHELL:-/bin/sh}"';
  return (
    `factory slot run --name ${shQuote(`${repoName(dir)} ${runner}`)} -- ` +
    `env FACTORY_SLOT_ACTIVE=1 ${caps} ${shell} -c ${shQuote(body)}`
  );
}

interface Segment {
  text: string;
  /** The separator that follows it (`&&`, `;` or a newline), with its surrounding whitespace. */
  sep: string;
}

/** Shell keywords that open or continue a compound command: a chain containing one is not split at `;`. */
const COMPOUND_WORDS = new Set(["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function", "!", "}"]);

/** Builtins that leave state for the segments after them, which a separate `sh -c` would not see. */
const STATE_WORDS = new Set(["set", "shopt", "source", ".", "unset", "alias", "declare", "local", "typeset", "read", "shift", "trap", "umask", "ulimit", "eval", "pushd", "popd"]);
/** Does the segment hold a command made only of variable assignments (`PORT=4000`, `A="x y"`, `V=$(cmd)`)? Those are not exported. */
function hasBareAssignment(text: string): boolean {
  return splitIntoCommands(text).some((tokens) => tokens.length > 0 && tokens.every((t) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(t)));
}

/**
 * The command cut at its top-level `&&`, `;` and newlines, or null when that is not provably safe:
 * `||` (precedence: `a && b || c` is not `a && (b || c)`), `&`, subshells and groups, heredocs,
 * comments, compound commands (`for … ; do … ; done`), segments that leave shell state behind
 * (`PORT=4000;`, `set -o pipefail;`) and unbalanced quotes. A pipe stays inside
 * its segment. Quotes, `$(…)` and backticks hide their separators.
 */
export function splitChain(command: string): Segment[] | null {
  const segments: Segment[] = [];
  let start = 0;
  let i = 0;
  const n = command.length;

  const cut = (end: number, sepEnd: number): void => {
    const text = command.slice(start, end);
    if (text.trim()) segments.push({ text, sep: command.slice(end, sepEnd) });
    else if (segments.length > 0) segments[segments.length - 1].sep += command.slice(end, sepEnd);
    start = sepEnd;
    i = sepEnd;
  };
  /** Index just past the `close` matching an opener already consumed, or -1. */
  const skipNested = (from: number, open: string, close: string): number => {
    let depth = 1;
    for (let j = from; j < n; j++) {
      const c = command[j];
      if (c === "\\") j++;
      else if (c === "'" && close !== "`") {
        const e = command.indexOf("'", j + 1);
        if (e === -1) return -1;
        j = e;
      } else if (c === open && open !== close) depth++;
      else if (c === close && --depth === 0) return j + 1;
    }
    return -1;
  };

  while (i < n) {
    const c = command[i];
    const prev = i > 0 ? command[i - 1] : " ";
    if (c === "\\") {
      i += 2;
    } else if (c === "'") {
      const e = command.indexOf("'", i + 1);
      if (e === -1) return null;
      i = e + 1;
    } else if (c === '"') {
      let j = i + 1;
      while (j < n && command[j] !== '"') {
        if (command[j] === "\\") j += 2;
        else if (command[j] === "$" && command[j + 1] === "(") {
          j = skipNested(j + 2, "(", ")");
          if (j === -1) return null;
        } else if (command[j] === "`") {
          j = skipNested(j + 1, "`", "`");
          if (j === -1) return null;
        } else j++;
      }
      if (j >= n) return null;
      i = j + 1;
    } else if (c === "$" && command[i + 1] === "(") {
      i = skipNested(i + 2, "(", ")");
      if (i === -1) return null;
    } else if (c === "`") {
      i = skipNested(i + 1, "`", "`");
      if (i === -1) return null;
    } else if (c === "&" && command[i + 1] === "&") {
      cut(i, i + 2);
    } else if (c === ";" && command[i + 1] !== ";") {
      cut(i, i + 1);
    } else if (c === "\n") {
      cut(i, i + 1);
    } else if (c === "|" && command[i + 1] === "|") {
      return null;
    } else if (c === "&") {
      // `2>&1`, `>&2`, `&>file` are redirections; anything else backgrounds.
      if (prev !== ">" && prev !== "<" && command[i + 1] !== ">") return null;
      i++;
    } else if (c === "(" || c === ")" || c === ";") {
      return null;
    } else if (c === "<" && command[i + 1] === "<" && command[i + 2] !== "<") {
      return null;
    } else if (c === "#" && /\s/.test(prev)) {
      return null;
    } else {
      i++;
    }
  }
  cut(n, n);

  for (const { text } of segments) {
    const first = text.trim().split(/\s+/)[0];
    if (COMPOUND_WORDS.has(first) || STATE_WORDS.has(first) || /^\{/.test(first) || hasBareAssignment(text)) return null;
  }
  return segments;
}

/** `cd <plain word>` alone: it moves the directory the later segments are judged in. */
const CD_ONLY = /^cd\s+((?:"[^"$`\\]+"|'[^']+'|[\w@%+=:,./~-]+))$/;

/** A chain of `&&`/`;` segments: each test segment takes its own slot, the rest run as written. */
function rewriteSegments(
  segments: Segment[],
  opts: { cwd: string; env: Record<string, string | undefined>; cores: number },
): Rewrite | null {
  let dir = opts.cwd;
  let first: string | null = null;
  const parts: string[] = [];
  for (const { text, sep } of segments) {
    const lead = text.match(/^\s*/)?.[0] ?? "";
    const trail = text.match(/\s*$/)?.[0] ?? "";
    const body = text.trim();
    const cd = CD_ONLY.exec(body);
    if (cd) dir = resolveDir(cd[1], dir, opts.env);
    const runner = splitIntoCommands(body)
      .map(testRunner)
      .find((r): r is string => r !== null);
    if (!runner || (existsSync(dir) && projectHasSlot(dir))) {
      parts.push(text + sep);
      continue;
    }
    first ??= runner;
    parts.push(lead + slotWrap(body, dir, runner, opts.cores) + trail + sep);
  }
  return first ? { command: parts.join(""), runner: first } : null;
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
          updatedInput: { ...input.tool_input, command: result.command },
        },
      }),
    );
  } catch {
    // fail open: never block a command because the hook broke
  }
  process.exit(0);
}
