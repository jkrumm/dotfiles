#!/usr/bin/env bun

/**
 * PreToolUse hook: no agent restarts, updates or starts the herdr-core, or
 * reboots the mini.
 *
 * Incident 2026-11-13 (docs/incident-2026-11-13-mini-panic.md, "Standing
 * constraint: HerdrCore must stay recoverable and unbroken"): the owner's rule is
 * one update path, `make herdr-core-update`, run by hand in a quiet window; no
 * agent restarts, stops, updates or starts the core, writes a wrapper at
 * `~/.local/bin/{hc,herdr-core}`, or reboots / kills to prove a change. Until now
 * only prose held it. Active in every Claude Code session (factory or not): the
 * owner runs these by hand, in a terminal of his own.
 *
 * Denied (command position only — quoted text is data, see docker-makefile.ts;
 * `ssh <host> '<cmd>'`, `bash -c`, `eval`, `xargs`, `hc run <cmd>` and a heredoc
 * fed to a shell are looked through):
 *   - `hc` / `herdr-core`: `server <anything but status>`, `update`,
 *     `machine update`, `serve`, `connect`, and a bare `herdr-core`;
 *   - `make herdr-core-{update,setup,teardown,clean-restart}`;
 *   - `launchctl kickstart|bootout|bootstrap|unload|load|stop|kill|remove|disable`
 *     naming herdr-core, and `launchctl reboot`;
 *   - `shutdown`, `reboot`, `halt` (with or without `sudo`);
 *   - `kill`/`pkill`/`killall` naming herdr-core (or a `kill` beside a
 *     `pgrep`/`pidof` that does);
 *   - Write/Edit, a redirection, or `tee|cp|mv|ln|install|touch|dd` creating
 *     `~/.local/bin/hc` or `~/.local/bin/herdr-core`.
 *
 * Allowed: the read verbs (`hc read|send|wait|list|ls|run|attach|events|kill`,
 * `hc server status`), `make herdr-core-status|test|launcher`, `launchctl print`,
 * and every word above inside quotes (a grep pattern, a commit message).
 *
 * Not covered (same hazard class): `hc send <terminal> '<cmd>'` typing a denied
 * command into a terminal, `make setup` reaching `herdr-core-setup`, `osascript`
 * restart, `echo '<cmd>' | bash`, a `>|` clobber redirection (the tokenizer reads the `|` as a pipe), a script that wraps a denied command,
 * `rm`, `sed -i`, `chmod` or `truncate` on the wrapper paths, and a relative path after `cd ~/.local/bin`.
 */

import { homedir } from "node:os";
import { collect, type Invocation } from "./broad-kill-guard.ts";
import { splitIntoCommands } from "./docker-makefile.ts";

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; file_path?: string; [key: string]: unknown };
}

const REASON =
  "HerdrCore must stay recoverable and unbroken (docs/incident-2026-11-13-mini-panic.md, " +
  "\"Standing constraint\"). The one update path is `make herdr-core-update`, run by the owner by hand " +
  "in a quiet window. No agent restarts, stops, updates or starts the core, writes a wrapper at " +
  "`~/.local/bin/{hc,herdr-core}`, or reboots or kills to prove a change: proof is a test plus reading the code path.";

const deny = (what: string): string => `${what}. ${REASON}`;

const CORE = /herdr[- ]?core/i;

// ── hc / herdr-core ──────────────────────────────────────────────────────────

const VERBS = new Set([
  "server", "update", "machine", "serve", "connect", "start", "stop", "restart", "run", "read", "send", "wait",
  "list", "ls", "attach", "events", "kill", "new", "rm", "label", "labels", "template", "templates", "rpc", "help",
]);

/** `hc --machine mini server restart` → verb `server`, rest `[restart]`. Flag values read as positionals, so the verb is the first known one. */
function verbOf(args: string[]): { verb: string | undefined; rest: string[]; index: number } {
  const positionals = args.map((a, index) => ({ a, index })).filter(({ a }) => !a.startsWith("-"));
  const at = positionals.findIndex(({ a }) => VERBS.has(a));
  const first = at === -1 ? 0 : at;
  const verb = positionals[first]?.a;
  return { verb, rest: positionals.slice(first + 1).map(({ a }) => a), index: positionals[first]?.index ?? args.length };
}

function coreCliViolation(inv: Invocation): string | null {
  const bare = inv.name === "herdr-core";
  const { verb, rest } = verbOf(inv.args);
  if (!verb) {
    return bare && inv.args.every((a) => !a.startsWith("-")) ? deny("A bare `herdr-core` starts the core") : null;
  }
  if (verb === "update") return deny(`\`${inv.name} update\` updates the core`);
  if (verb === "machine" && rest[0] === "update") return deny(`\`${inv.name} machine update\` updates a machine's core`);
  if (verb === "server" && rest[0] !== undefined && rest[0] !== "status") {
    return deny(`\`${inv.name} server ${rest[0]}\` restarts, stops or starts the core`);
  }
  if (["serve", "connect", "start", "stop", "restart"].includes(verb) && (bare || verb === "serve")) {
    return deny(`\`${inv.name} ${verb}\` starts or stops the core`);
  }
  return null;
}

// ── make ─────────────────────────────────────────────────────────────────────

const MAKE_TARGETS = new Set([
  "herdr-core-update",
  "herdr-core-setup",
  "herdr-core-teardown",
  "herdr-core-clean-restart",
]);

// ── launchctl ────────────────────────────────────────────────────────────────

const LAUNCHCTL_VERBS = new Set([
  "kickstart", "bootout", "bootstrap", "unload", "load", "stop", "kill", "remove", "disable", "start",
]);

// ── kill ─────────────────────────────────────────────────────────────────────

const KILLERS = new Set(["kill", "pkill", "killall"]);
const FINDERS = new Set(["pgrep", "pidof"]);

// ── ~/.local/bin/{hc,herdr-core} ─────────────────────────────────────────────

const HOME_PREFIX = String.raw`(?:~|\$HOME|\$\{HOME\}|/(?:Users|home)/[^/]+)`;
const WRAPPER_PATH = new RegExp(String.raw`^${HOME_PREFIX}/\.local/bin/(?:hc|herdr-core)$`);

export const isCoreBinaryPath = (path: string): boolean => {
  const home = homedir();
  return WRAPPER_PATH.test(path) || path === `${home}/.local/bin/hc` || path === `${home}/.local/bin/herdr-core`;
};

/** Commands whose every path argument is written or moved (`mv` also takes the file away). */
const WRITES_EVERY_ARG = new Set(["tee", "mv", "touch", "dd"]);
/** Commands that read their sources and write the last path (or `-t <dir>`). */
const WRITES_LAST_ARG = new Set(["cp", "ln", "install"]);

function writesCoreBinary({ name, args }: Invocation): boolean {
  const paths = args.filter((a) => !a.startsWith("-") || a.startsWith("of="));
  if (WRITES_EVERY_ARG.has(name)) return paths.some((a) => isCoreBinaryPath(a.replace(/^of=/, "")));
  if (!WRITES_LAST_ARG.has(name)) return false;
  const dir = args.findIndex((a) => a === "-t" || a === "--target-directory");
  return isCoreBinaryPath(dir === -1 ? (paths.at(-1) ?? "") : (args[dir + 1] ?? ""));
}

/** Targets of redirections (`>`, `>>`, `>|`, `&>`, `N>`) among raw tokens. */
function redirectTargets(tokens: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const m = /^(?:\d*|&)>{1,2}\|?(.*)$/.exec(tokens[i]);
    if (!m) continue;
    const target = m[1] || tokens[i + 1] || "";
    if (!target.startsWith("&")) out.push(target);
  }
  return out;
}

// ── Looking through ssh and hc run ───────────────────────────────────────────

const SSH_VALUE_FLAGS = new Set([
  "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
]);

/** The remote command of `ssh [opts] host cmd…`, as text. */
function sshRemote(args: string[]): string {
  let i = 0;
  while (i < args.length && args[i].startsWith("-")) {
    const flag = args[i++];
    if (flag === "--") break;
    if (SSH_VALUE_FLAGS.has(flag)) i++;
  }
  return args.slice(i + 1).join(" "); // i is the host
}

const shellQuote = (word: string): string => (/^[\w@%+=:,./-]+$/.test(word) ? word : `'${word.replaceAll("'", "'\\''")}'`);

/**
 * What `hc run` hands to a terminal: the tokens after `--` if present, else after `run` (its flag values are unknown, so
 * every suffix). Each suffix is read as one command string (`hc run 'hc update'`) and as an argv (`hc run -- sh -c 'hc update'`,
 * where the quoting must survive the join).
 */
function hcRunCommands(args: string[]): string[] {
  const dashes = args.indexOf("--");
  const tail = dashes !== -1 ? args.slice(dashes + 1) : args.slice(verbOf(args).index + 1);
  const suffixes = dashes !== -1 ? [tail] : tail.map((_, i) => tail.slice(i));
  return suffixes.flatMap((words) => [words.join(" "), words.map(shellQuote).join(" ")]);
}

// ── Policy ───────────────────────────────────────────────────────────────────

function invocationViolation(inv: Invocation, finders: Invocation[], depth: number): string | null {
  const { name, args } = inv;

  if (name === "hc" || name === "herdr-core") {
    const violation = coreCliViolation(inv);
    if (violation) return violation;
    if (verbOf(args).verb === "run") {
      for (const cmd of hcRunCommands(args)) {
        const nested = findViolation(cmd, depth + 1);
        if (nested) return nested;
      }
    }
  }

  if (name === "ssh") {
    const remote = sshRemote(args);
    if (remote) {
      const nested = findViolation(remote, depth + 1);
      if (nested) return nested;
    }
  }

  if (name === "make") {
    const target = args.find((a) => MAKE_TARGETS.has(a));
    if (target) return deny(`\`make ${target}\` restarts, installs or removes the core`);
  }

  if (name === "launchctl") {
    const verb = args.find((a) => !a.startsWith("-"));
    if (verb === "reboot") return deny("`launchctl reboot` reboots the mini");
    if (verb && LAUNCHCTL_VERBS.has(verb) && args.some((a) => CORE.test(a))) {
      return deny(`\`launchctl ${verb}\` on the core's launchd job`);
    }
  }

  if (name === "shutdown" || name === "reboot" || name === "halt") return deny(`\`${name}\` takes the mini down`);

  if (KILLERS.has(name)) {
    if (args.some((a) => CORE.test(a))) return deny(`\`${name}\` names the core`);
    if (name === "kill" && finders.some((f) => f.args.some((a) => CORE.test(a)))) {
      return deny("`kill` fed by a lookup of the core's process");
    }
  }

  if (writesCoreBinary(inv)) return deny(`\`${name}\` writes a wrapper at \`~/.local/bin/{hc,herdr-core}\``);
  if (redirectTargets(args).some(isCoreBinaryPath)) {
    return deny("A redirection writes a wrapper at `~/.local/bin/{hc,herdr-core}`");
  }
  return null;
}

/** Why this command must not run, or null when it may. */
export function findViolation(command: string, depth = 0): string | null {
  if (depth > 4) return null;
  const invocations = collect(command);
  const finders = invocations.filter((inv) => FINDERS.has(inv.name));
  for (const inv of invocations) {
    const violation = invocationViolation(inv, finders, depth);
    if (violation) return violation;
  }
  // A leading redirection (`> ~/.local/bin/hc echo …`) is stripped before collect sees the command, and the
  // tokenizer drops what follows a heredoc opener on its line (`cat <<EOF > ~/.local/bin/hc`).
  const lines = [...command.matchAll(/(?<!<)<<(?!<)-?[ \t]*['"]?[^\s'"<>;&|]+['"]?([^\n]*)/g)].map((m) => m[1]);
  for (const tokens of [...splitIntoCommands(command), ...lines.flatMap((l) => splitIntoCommands(l))]) {
    if (redirectTargets(tokens).some(isCoreBinaryPath)) {
      return deny("A redirection writes a wrapper at `~/.local/bin/{hc,herdr-core}`");
    }
  }
  return null;
}

/** Write/Edit on the core's binaries. */
export function findFileViolation(filePath: string): string | null {
  return isCoreBinaryPath(filePath.trim()) ? deny(`Writing \`${filePath}\` creates a wrapper at \`~/.local/bin/{hc,herdr-core}\``) : null;
}

function emitDeny(reason: string): never {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    }),
  );
  process.exit(0);
}

// ── Main ─────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  const input: HookInput = JSON.parse(await Bun.stdin.text());
  const violation =
    input.tool_name === "Bash"
      ? findViolation((input.tool_input?.command ?? "").trim())
      : ["Write", "Edit", "MultiEdit"].includes(input.tool_name)
        ? findFileViolation(input.tool_input?.file_path ?? "")
        : null;
  if (violation) emitDeny(violation);
}
