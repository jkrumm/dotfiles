#!/usr/bin/env bun

/**
 * PreToolUse hook: deny pattern kills that reach other agents' processes.
 *
 * Incident 2026-11-01 20:12: an agent ran
 *
 *     for p in $(pgrep -f 'gate.sh'); do pkill -TERM -P $p; kill $p; done
 *
 * to stop its own gate script. `pgrep -f` matches the full command line of every
 * process of the user, and a Claude Code session's prompt is its argv, so every
 * session whose prompt mentioned `gate.sh` got SIGTERM: eight agents across three
 * repos ended in the same second.
 *
 * Denied (command position only — quoted text is data, see docker-makefile.ts):
 *   - `pkill` with `-f`/`--full`, or without a `-P <pid>` / `-g <pgid>` scope;
 *   - `killall`;
 *   - `kill`, `xargs kill` and `pkill -P`/`-g` whose target is not a literal
 *     PID (`$!`, a number, `%job`) in a command that also runs `pgrep -f`.
 *     The last rule is deliberately coarse: the shell structure is flattened by
 *     the tokenizer, so "the same call also ran `pgrep -f`" stands in for "fed
 *     by it". `kill "$(cat pidfile)"` is therefore fine alone and denied beside
 *     a `pgrep -f` — split it into two calls.
 *
 * Allowed: `kill <literal pid>`, `kill $!`, `kill "$(cat pidfile)"`, `kill %1`,
 * `pkill -P <literal pid | $!>`, `pgrep` alone, and every word above inside
 * quotes (a grep pattern, a commit message).
 *
 * Not covered (out of scope, same hazard class): `kill $(pgrep <name>)` without
 * `-f`, and `ps | grep | awk | xargs kill`.
 */

import { splitIntoCommands } from "./docker-makefile.ts";

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
}

interface Invocation {
  name: string;
  args: string[];
  /** Arguments arrive on stdin (`… | xargs kill`) and cannot be inspected. */
  stdin?: boolean;
}

const REASON =
  "Pattern kills hit every agent on this machine (incident 2026-11-01). " +
  "Kill only what you started: keep $! in a pidfile and kill that PID or its process group.";

// ── Resolving a simple command ───────────────────────────────────────────────

interface WrapperSpec {
  /** Flags that consume the next token as their value. */
  valueFlags: ReadonlySet<string>;
  /** Positional arguments before the wrapped command (`timeout 5 cmd`). */
  positionals: number;
}

const wrapper = (flags: string[] = [], positionals = 0): WrapperSpec => ({
  valueFlags: new Set(flags),
  positionals,
});

/** Prefixes that run another command; `sudo -n` must not eat the command. */
const WRAPPERS: Record<string, WrapperSpec> = {
  sudo: wrapper([
    "-u", "-g", "-C", "-U", "-h", "-p", "-r", "-t",
    "--user", "--group", "--chdir", "--host", "--prompt", "--role", "--type", "--other-user",
  ]),
  doas: wrapper(["-u", "-C"]),
  env: wrapper(["-u", "-C", "--unset", "--chdir"]),
  nice: wrapper(["-n", "--adjustment"]),
  timeout: wrapper(["-s", "-k", "--signal", "--kill-after"], 1),
  stdbuf: wrapper(["-i", "-o", "-e", "--input", "--output", "--error"]),
  command: wrapper(),
  builtin: wrapper(),
  exec: wrapper(),
  nohup: wrapper(),
  time: wrapper(),
};

/** Shell keywords that precede a command in `for … do <cmd>` and friends. */
const KEYWORDS = new Set(["do", "then", "else", "elif", "if", "while", "until", "!"]);

const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);

const basename = (token: string): string => token.split("/").pop() ?? token;

/** A command with the scripts handed to it as option values (`env -S '<cmd>'`). */
interface Resolved {
  inv: Invocation | null;
  scripts: string[];
}

/** `>file`, `2>`, `<in` at the start of a command: not the executable. */
const REDIRECT = /^\d*(?:>>?|<)/;

/** Skip keywords, redirections, env assignments and wrappers; return the command proper. */
function resolve(tokens: string[]): Resolved {
  const scripts: string[] = [];
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (KEYWORDS.has(t) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
      i++;
      continue;
    }
    // `>/dev/null cmd`, `> out cmd`; `2>&1 cmd` arrives as `2>` then `1`.
    if (REDIRECT.test(t) || /^\d+$/.test(t)) {
      i += /^\d*(?:>>?|<)$/.test(t) ? 2 : 1;
      continue;
    }
    const name = basename(t);
    const spec = WRAPPERS[name];
    if (!spec) break;
    i++;
    while (i < tokens.length && tokens[i].startsWith("-")) {
      const flag = tokens[i++];
      if (flag === "--") break;
      if (name === "env" && (flag === "-S" || flag === "--split-string")) {
        if (i < tokens.length) scripts.push(tokens[i++]);
      } else if (name === "env" && flag.startsWith("--split-string=")) {
        scripts.push(flag.slice("--split-string=".length));
      } else if (spec.valueFlags.has(flag)) {
        i++;
      }
    }
    i += spec.positionals;
  }
  if (i >= tokens.length) return { inv: null, scripts };
  return { inv: { name: basename(tokens[i]), args: tokens.slice(i + 1) }, scripts };
}

const XARGS_VALUE_FLAGS = new Set(["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a", "-J", "-R", "-S"]);
const XARGS_LONG_VALUE_FLAGS = new Set([
  "--max-args",
  "--max-procs",
  "--max-lines",
  "--max-chars",
  "--delimiter",
  "--arg-file",
  "--eof",
  "--replace",
]);

function stripXargsFlags(args: string[]): string[] {
  let i = 0;
  while (i < args.length && args[i].startsWith("-")) {
    const flag = args[i++];
    if (flag === "--") break;
    if (XARGS_VALUE_FLAGS.has(flag) || XARGS_LONG_VALUE_FLAGS.has(flag)) i++;
  }
  return args.slice(i);
}

/** The script of `bash -c <script>` / `sh -lc <script>`, if there is one. */
function shellScript(args: string[]): string | undefined {
  const at = args.findIndex((a) => /^-[a-zA-Z]*c[a-zA-Z]*$/.test(a));
  return at === -1 ? undefined : args[at + 1];
}

/**
 * Every command the input runs, wrappers stripped. Looks through `xargs <cmd>`,
 * `bash -c '<script>'` and `eval` — quoted text is data, except where it is
 * handed to a shell.
 */
function collect(command: string, depth = 0): Invocation[] {
  const out: Invocation[] = [];
  if (depth > 4) return out;

  const add = ({ inv, scripts }: Resolved) => {
    for (const script of scripts) out.push(...collect(script, depth + 1));
    if (!inv) return;
    if (inv.name === "xargs") {
      const inner = resolve(stripXargsFlags(inv.args));
      add({ inv: inner.inv && { ...inner.inv, stdin: true }, scripts: inner.scripts });
      return;
    }
    if (SHELLS.has(inv.name)) {
      const script = shellScript(inv.args);
      if (script !== undefined) out.push(...collect(script, depth + 1));
      return;
    }
    if (inv.name === "eval") {
      out.push(...collect(inv.args.join(" "), depth + 1));
      return;
    }
    out.push(inv);
  };

  // The tokenizer drops heredoc bodies (data for most commands); a body fed to
  // a shell is a script.
  for (const body of shellHeredocBodies(command)) out.push(...collect(body, depth + 1));
  for (const tokens of splitIntoCommands(command)) add(resolve(tokens));
  return out;
}

/**
 * Scripts fed to a shell on stdin: `bash <<EOF … EOF`, `sh <<-'EOF' … EOF`,
 * `bash <<< 'script'`. (The tokenizer reads `<<<` as a heredoc and drops it.)
 */
function shellHeredocBodies(command: string): string[] {
  const herestring = /\b(?:bash|sh|zsh|dash|ksh)\b[^\n|;&]*?<<<[ \t]*(?:'([^']*)'|"([^"]*)"|(\S+))/g;
  const strings = [...command.matchAll(herestring)].map((m) => m[1] ?? m[2] ?? m[3]);
  const re =
    /\b(?:bash|sh|zsh|dash|ksh)\b[^\n|;&]*?<<-?[ \t]*(['"]?)(\w+)\1[^\n]*\n([\s\S]*?)\n[ \t]*\2[ \t]*(?:\n|$)/g;
  return [...strings, ...[...command.matchAll(re)].map((m) => m[3])];
}

// ── pgrep / pkill arguments ──────────────────────────────────────────────────

interface ProcArgs {
  /** Short flags (long names normalised, `--full` → `f`). */
  flags: Set<string>;
  /** Value flags by short name: `-P 12`, `-P12`, `--parent=12` → `P`. */
  values: Map<string, string>;
}

const SHORT_VALUE_FLAGS = new Set("PgGuUstcFd".split(""));
const LONG_VALUE_FLAGS: Record<string, string> = {
  parent: "P",
  pgroup: "g",
  group: "G",
  euid: "u",
  uid: "U",
  session: "s",
  terminal: "t",
  pidfile: "F",
  delimiter: "d",
  signal: "signal",
  ns: "ns",
  nslist: "nslist",
  cgroup: "cgroup",
  runstates: "runstates",
};

function parseProcArgs(args: string[]): ProcArgs {
  const flags = new Set<string>();
  const values = new Map<string, string>();

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--") break;

    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      const name = a.slice(2, eq === -1 ? undefined : eq);
      const key = LONG_VALUE_FLAGS[name];
      if (key) values.set(key, eq === -1 ? (args[++i] ?? "") : a.slice(eq + 1));
      else flags.add(name === "full" ? "f" : name);
      continue;
    }

    if (!a.startsWith("-") || a.length === 1) continue;
    // A signal (`-9`, `-TERM`, `-SIGKILL`), not a flag cluster: `-PIPE` must not
    // read as `-P IPE`.
    if (/^-\d+$/.test(a) || /^-[A-Z]{2,}[A-Z0-9]*$/.test(a)) continue;

    const cluster = a.slice(1);
    for (let k = 0; k < cluster.length; k++) {
      const c = cluster[k];
      if (SHORT_VALUE_FLAGS.has(c)) {
        values.set(c, cluster.slice(k + 1) || (args[++i] ?? ""));
        break;
      }
      flags.add(c);
    }
  }
  return { flags, values };
}

/** A PID the agent started itself: a number or `$!`. */
const isLiteralPid = (v: string): boolean => /^\d+$/.test(v) || v === "$!" || v === "${!}";

/** Targets of `kill`: literal PIDs, negative PGIDs, `$!`, `%job`. */
const isLiteralKillTarget = (v: string): boolean =>
  isLiteralPid(v) || /^-\d+$/.test(v) || /^%[%+\-\w]*$/.test(v);

function killTargets(args: string[]): string[] {
  let i = 0;
  if (args[0] === "-s" || args[0] === "-n") i = 2;
  else if (args[0]?.startsWith("-") && args[0] !== "--") i = 1; // `-9`, `-TERM`
  if (args[i] === "--") i++;
  return args.slice(i);
}

// ── Policy ───────────────────────────────────────────────────────────────────

/** Why this command must not run, or null when it may. */
export function findViolation(command: string): string | null {
  const invocations = collect(command);

  const usesPgrepFull = invocations.some(
    (inv) => inv.name === "pgrep" && parseProcArgs(inv.args).flags.has("f"),
  );

  for (const inv of invocations) {
    if (inv.name === "killall") {
      return `\`killall\` kills every process with that name. ${REASON}`;
    }

    if (inv.name === "pkill") {
      const { flags, values } = parseProcArgs(inv.args);
      if (flags.has("f")) {
        return `\`pkill -f\` matches every process's full command line, including other agents' prompts. ${REASON}`;
      }
      const scope = values.get("P") ?? values.get("g");
      if (scope === undefined) {
        return `\`pkill\` without \`-P <pid>\` or \`-g <pgid>\` matches by name across the machine. ${REASON}`;
      }
      if (usesPgrepFull && !isLiteralPid(scope)) {
        return `\`pkill -P\`/\`-g\` fed by \`pgrep -f\` reaches whatever \`pgrep -f\` matched. ${REASON}`;
      }
    }

    if (inv.name === "kill" && usesPgrepFull) {
      const targets = killTargets(inv.args);
      // No visible target means it arrives some other way (stdin, or `xargs -I{}`
      // whose braces the tokenizer split away).
      if (inv.stdin || targets.length === 0 || targets.some((t) => !isLiteralKillTarget(t))) {
        return `\`kill\` fed by \`pgrep -f\` reaches whatever \`pgrep -f\` matched. ${REASON}`;
      }
    }
  }
  return null;
}

function deny(reason: string): never {
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
  if (input.tool_name !== "Bash") process.exit(0);

  const violation = findViolation((input.tool_input?.command ?? "").trim());
  if (violation) deny(violation);
}
