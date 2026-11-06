#!/usr/bin/env bun

/**
 * PreToolUse hook: prefer Makefile targets over raw docker/docker-compose commands.
 *
 * When a Bash command *invokes* docker/docker-compose and the cwd has a Makefile,
 * denies the command and tells Claude to use `make` targets instead.
 *
 * If no Makefile exists in the project, the command is allowed through.
 *
 * Read-only docker commands (ps, logs, inspect, images) are always allowed —
 * they don't involve orchestration context that Makefiles encode.
 *
 * `docker exec` is also always allowed: it runs commands inside an
 * already-running container and carries no Compose orchestration context.
 *
 * `docker build --check` (and the `buildx` spelling) is allowed for the same
 * reason: it is BuildKit's Dockerfile *linter*, not a build — see
 * isLintOnlyBuild below.
 *
 * Docker's management form (`docker image inspect`) is classified on the verb,
 * not the object noun — see isReadOnlyManagement below.
 *
 * The matching is shell-aware on purpose. A plain regex over the command string
 * cannot tell an invocation from a mention, so it denied things like
 *
 *     grep -n 'foo\|docker-socket' Makefile
 *
 * where the `|` inside the quoted grep pattern looked like a pipe and
 * `docker-socket` looked like the docker binary. Quoted text is data: we
 * tokenize with quote/escape state and only inspect tokens in *command
 * position* (start of input, or after an unquoted `|`, `;`, `&`, `&&`, `||`,
 * newline, or subshell boundary). Command substitutions are parsed recursively,
 * so `$(docker compose up)` is still caught.
 */

interface HookInput {
  tool_name: string;
  tool_input?: { command?: string; [key: string]: unknown };
  cwd?: string;
}

/** Prefixes that wrap another command without changing what is being run. */
const WRAPPERS = new Set([
  "sudo",
  "env",
  "command",
  "nice",
  "nohup",
  "stdbuf",
  "time",
  "timeout",
  "gtimeout",
  "xargs",
  "watch",
]);

/**
 * Wrapper flags that consume the following token as their value, per wrapper.
 * Without the arity `sudo -u deploy docker …` read `deploy` as the wrapped
 * command and the docker call behind it escaped. Unknown flags stay one token.
 */
const WRAPPER_VALUE_FLAGS: Record<string, Set<string>> = {
  sudo: new Set(["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "--user", "--group"]),
  env: new Set(["-u", "-C", "-S", "--unset", "--chdir", "--split-string"]),
  nice: new Set(["-n", "--adjustment"]),
  stdbuf: new Set(["-i", "-o", "-e"]),
  timeout: new Set(["-k", "-s", "--kill-after", "--signal"]),
  gtimeout: new Set(["-k", "-s", "--kill-after", "--signal"]),
  xargs: new Set(["-I", "-n", "-P", "-d", "-L", "-s", "-E", "-a"]),
  watch: new Set(["-n", "--interval"]),
};

/** Wrappers whose first positional argument is a duration, not the command. */
const DURATION_WRAPPERS = new Set(["timeout", "gtimeout"]);

/**
 * Strip leading env assignments and wrapper commands (with their flags and flag
 * values) and return the tokens of the command they wrap.
 */
export function unwrapWrappers(tokens: string[]): string[] {
  const state: WrapperState = { wrapper: null, needsDuration: false };
  let i = 0;
  while (i < tokens.length) {
    const skip = wrapperSkip(tokens[i], state);
    if (skip === 0) break;
    i += skip;
  }
  return tokens.slice(i);
}

interface WrapperState {
  wrapper: string | null;
  needsDuration: boolean;
}

const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/** How many tokens the prefix at `t` occupies; 0 when `t` starts the wrapped command. */
function wrapperSkip(t: string, state: WrapperState): number {
  if (ENV_ASSIGNMENT.test(t)) return 1;
  if (state.wrapper !== null) {
    const skip = wrapperOperandSkip(t, state, state.wrapper);
    if (skip > 0) return skip;
  }
  return enterWrapper(t, state);
}

/** A flag (with its value, if the wrapper's flag takes one) or the duration operand. */
function wrapperOperandSkip(t: string, state: WrapperState, wrapper: string): number {
  if (t.startsWith("-")) return flagWidth(wrapper, t);
  if (!state.needsDuration) return 0;
  state.needsDuration = false;
  return 1;
}

function flagWidth(wrapper: string, flag: string): number {
  return WRAPPER_VALUE_FLAGS[wrapper]?.has(flag) ? 2 : 1;
}

function enterWrapper(t: string, state: WrapperState): number {
  const name = basename(t);
  if (!WRAPPERS.has(name)) return 0;
  state.wrapper = name;
  state.needsDuration = DURATION_WRAPPERS.has(name);
  return 1;
}

/**
 * Commands hidden inside a shell string: `bash -c '…'`, `sh -c`, `zsh -c`
 * (including `-lc`-style clusters) and `eval …`. Returns the parsed inner
 * commands, which may themselves nest.
 */
function nestedShellCommands(tokens: string[]): string[][] {
  const script = nestedScript(unwrapWrappers(tokens));
  return script === undefined ? [] : splitIntoCommands(script);
}

const SHELLS = new Set(["sh", "bash", "zsh"]);
const SHELL_C_FLAG = /^-[a-zA-Z]*c[a-zA-Z]*$/;

/** The shell text a wrapped command executes: an `eval` body or a `-c` script. */
function nestedScript(rest: string[]): string | undefined {
  const name = basename(rest[0] ?? "");
  if (name === "eval") return rest.slice(1).join(" ");
  return SHELLS.has(name) ? shellCommandString(rest) : undefined;
}

function shellCommandString(rest: string[]): string | undefined {
  const flagIndexes: number[] = [];
  for (let i = 1; i < rest.length && rest[i].startsWith("-"); i++) flagIndexes.push(i);
  const at = flagIndexes.find((i) => SHELL_C_FLAG.test(rest[i]) && rest[i + 1] !== undefined);
  return at === undefined ? undefined : rest[at + 1];
}

/**
 * Subcommands that need no Makefile orchestration: read-only inspection plus
 * `exec` (runs inside an already-running container, no Compose context).
 */
const READ_ONLY = new Set([
  "ps",
  "logs",
  "inspect",
  "images",
  "stats",
  "top",
  "port",
  "version",
  "info",
  "exec",
]);

/**
 * Nouns in docker's `docker <object> <verb>` management form. Every entry here
 * is a namespace, never an action — the token *after* it decides whether the
 * command reads or writes.
 */
const MANAGEMENT_OBJECTS = new Set([
  "image",
  "container",
  "volume",
  "network",
  "system",
  "builder",
  "buildx",
  "context",
  "node",
  "service",
  "secret",
  "config",
  "plugin",
  "stack",
  "swarm",
  "manifest",
  "trust",
  "checkpoint",
]);

/**
 * Verbs that only read, in the management form. Superset of READ_ONLY: `ls` and
 * friends exist only after an object, so they are not top-level subcommands.
 */
const READ_ONLY_VERBS = new Set([
  ...READ_ONLY,
  "ls",
  "list",
  "history",
  "df",
  "du",
  "events",
]);

/** Global flags that consume the following token as their value. */
/**
 * The subset of VALUE_FLAGS whose value is a path into the project being
 * operated on — a compose file or a Dockerfile.
 */
const FILE_FLAGS = new Set(["-f", "--file"]);

const VALUE_FLAGS = new Set([
  "-H",
  "--host",
  "-f",
  "--file",
  "-c",
  "--context",
  "-p",
  "--project-name",
  "--project-directory",
  "--env-file",
  "--profile",
  "--log-level",
  "--tlscacert",
  "--tlscert",
  "--tlskey",
]);

/**
 * Split a shell command line into simple commands, each a list of tokens.
 *
 * Quote- and escape-aware. Text inside quotes becomes part of a token and is
 * never treated as a command or an operator. Command substitutions (`$(...)`
 * and backticks) are parsed recursively so commands nested in them are seen.
 */
/** Index of the delimiter that closes a nested construct, or end of string. */
function findClosing(src: string, start: number, open: string, close: string): number {
  let depth = 1;
  let j = start;
  while (j < src.length) {
    const c = src[j];
    if (c === "\\") {
      j += 2;
      continue;
    }
    if (open && c === open) depth++;
    else if (c === close) {
      depth--;
      if (depth === 0) return j;
    }
    j++;
  }
  return src.length;
}

/**
 * Collect commands from `$(...)` / backtick substitutions appearing anywhere in
 * src. Used for unquoted heredoc bodies, where the body is stdin data but
 * substitutions inside it still execute.
 */
function collectSubstitutions(src: string, sink: string[][]): void {
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === "\\") {
      i += 2;
      continue;
    }
    if (c === "'") {
      const close = src.indexOf("'", i + 1);
      i = (close === -1 ? src.length : close) + 1;
      continue;
    }
    if (c === "$" && src[i + 1] === "(") {
      const end = findClosing(src, i + 2, "(", ")");
      for (const cmd of splitIntoCommands(src.slice(i + 2, end))) sink.push(cmd);
      i = end + 1;
      continue;
    }
    if (c === "`") {
      const end = findClosing(src, i + 1, "", "`");
      for (const cmd of splitIntoCommands(src.slice(i + 1, end))) sink.push(cmd);
      i = end + 1;
      continue;
    }
    i++;
  }
}

export function splitIntoCommands(input: string): string[][] {
  return new CommandSplitter(input).run();
}

interface Span {
  start: number;
  end: number;
}

/** The `$(...)` or backtick substitution starting at `i`, or null. */
function substitutionSpan(src: string, i: number): Span | null {
  if (src[i] === "$" && src[i + 1] === "(") {
    return { start: i + 2, end: findClosing(src, i + 2, "(", ")") };
  }
  if (src[i] === "`") return { start: i + 1, end: findClosing(src, i + 1, "", "`") };
  return null;
}

/** Index of the next `quote` at or after `from`, or end of string. */
function quoteEnd(src: string, from: number, quote: string): number {
  const close = src.indexOf(quote, from);
  return close === -1 ? src.length : close;
}

/** `<<` heredoc opener; `<<<` is a herestring (a word), so it is excluded. */
function isHeredocStart(src: string, i: number): boolean {
  return src[i] === "<" && src[i + 1] === "<" && src[i + 2] !== "<";
}

interface HeredocHeader {
  word: string;
  /** Any part of the delimiter was quoted: the body has no substitution. */
  literal: boolean;
  /** `<<-` strips leading tabs from the terminator line. */
  dashed: boolean;
  /** Index just past the delimiter word. */
  end: number;
}

const DELIMITER_END = /[\s;&|<>()]/;

function skipBlanks(src: string, from: number): number {
  let j = from;
  while (src[j] === " " || src[j] === "\t") j++;
  return j;
}

function readHeredocHeader(src: string, opener: number): HeredocHeader {
  let j = opener + 2;
  const dashed = src[j] === "-";
  if (dashed) j++;
  const header: HeredocHeader = { word: "", literal: false, dashed, end: skipBlanks(src, j) };
  while (header.end < src.length && !DELIMITER_END.test(src[header.end])) {
    readDelimiterPart(src, header);
  }
  return header;
}

function readDelimiterPart(src: string, header: HeredocHeader): void {
  const c = src[header.end];
  if (c === "'" || c === '"') return readQuotedDelimiterPart(src, header, c);
  if (c === "\\") return readEscapedDelimiterPart(src, header);
  header.word += c;
  header.end++;
}

function readQuotedDelimiterPart(src: string, header: HeredocHeader, quote: string): void {
  const end = quoteEnd(src, header.end + 1, quote);
  header.literal = true;
  header.word += src.slice(header.end + 1, end);
  header.end = end + 1;
}

function readEscapedDelimiterPart(src: string, header: HeredocHeader): void {
  header.literal = true;
  if (header.end + 1 < src.length) header.word += src[header.end + 1];
  header.end += 2;
}

/** The body runs from `start` to a line equal to the delimiter. */
function readHeredocBody(src: string, start: number, header: HeredocHeader): { body: string; bodyEnd: number } {
  let pos = start;
  let body = "";
  while (pos <= src.length) {
    const newline = src.indexOf("\n", pos);
    const lineEnd = newline === -1 ? src.length : newline;
    const line = src.slice(pos, lineEnd);
    if (isHeredocTerminator(line, header)) return { body, bodyEnd: lineEnd };
    body += line + "\n";
    pos = lineEnd + 1;
  }
  return { body, bodyEnd: src.length };
}

function isHeredocTerminator(line: string, { word, dashed }: HeredocHeader): boolean {
  return (dashed ? line.replace(/^\t+/, "") : line) === word;
}

const OPERATOR_CHARS = new Set(["|", ";", "&", "\n"]);
/** Operators that double up (`&&`, `||`) and are consumed as one. */
const DOUBLED_OPERATORS = new Set(["|", "&"]);
const GROUP_CHARS = new Set(["(", ")", "{", "}"]);
const BLANK_CHARS = new Set([" ", "\t", "\r"]);

/**
 * Single-pass shell tokenizer. Each handler claims the character at the cursor
 * (returning true after consuming it) or declines; an unclaimed character is
 * plain token text.
 */
class CommandSplitter {
  private readonly commands: string[][] = [];
  private current: string[] = [];
  private token = "";
  private hasToken = false;
  private i = 0;

  private readonly handlers = [
    this.escape,
    this.singleQuote,
    this.doubleQuote,
    this.substitution,
    this.heredoc,
    this.operator,
    this.group,
    this.blank,
  ];

  constructor(private readonly input: string) {}

  run(): string[][] {
    while (this.i < this.input.length) this.step();
    this.endCommand();
    return this.commands;
  }

  private get ch(): string {
    return this.input[this.i];
  }

  private step(): void {
    if (this.handlers.some((handle) => handle.call(this))) return;
    this.add(this.ch);
    this.i++;
  }

  private add(text: string): void {
    this.token += text;
    this.hasToken = true;
  }

  private endToken(): void {
    if (!this.hasToken) return;
    this.current.push(this.token);
    this.token = "";
    this.hasToken = false;
  }

  private endCommand(): void {
    this.endToken();
    if (this.current.length === 0) return;
    this.commands.push(this.current);
    for (const nested of nestedShellCommands(this.current)) this.commands.push(nested);
    this.current = [];
  }

  /** The next character is literal; backslash-newline is a continuation the shell drops. */
  private addEscaped(): void {
    const next = this.input[this.i + 1];
    if (next !== undefined && next !== "\n") this.add(next);
    this.i += 2;
  }

  private escape(): boolean {
    if (this.ch !== "\\") return false;
    this.addEscaped();
    return true;
  }

  /** Single quotes: pure data, no substitution of any kind. */
  private singleQuote(): boolean {
    if (this.ch !== "'") return false;
    const end = quoteEnd(this.input, this.i + 1, "'");
    this.add(this.input.slice(this.i + 1, end));
    this.i = end + 1;
    return true;
  }

  /** Double quotes: data, but $(...) and `...` still run. */
  private doubleQuote(): boolean {
    if (this.ch !== '"') return false;
    this.i++;
    while (this.i < this.input.length && this.ch !== '"') this.doubleQuotedChar();
    this.i++; // past closing quote
    this.hasToken = true; // "" is still a token
    return true;
  }

  private doubleQuotedChar(): void {
    if (this.ch === "\\") return this.addEscaped();
    if (this.substitution()) return;
    this.add(this.ch);
    this.i++;
  }

  /** Parse a nested command substitution and fold its commands into ours. */
  private substitution(): boolean {
    const span = substitutionSpan(this.input, this.i);
    if (!span) return false;
    for (const cmd of splitIntoCommands(this.input.slice(span.start, span.end))) this.commands.push(cmd);
    // The substitution itself yields a value in the outer token.
    this.add("\0");
    this.i = span.end + 1;
    return true;
  }

  /**
   * Heredoc. The body is stdin data, never commands: a commit message or a doc
   * written with `<<'EOF'` routinely *mentions* docker.
   */
  private heredoc(): boolean {
    if (!isHeredocStart(this.input, this.i)) return false;
    const header = readHeredocHeader(this.input, this.i);
    if (header.word === "") {
      // Not a heredoc we understand — treat as ordinary redirection chars.
      this.add("<<");
      this.i += 2;
      return true;
    }
    const newline = this.input.indexOf("\n", header.end);
    if (newline === -1) {
      this.endCommand();
      this.i = this.input.length;
      return true;
    }
    this.consumeHeredocBody(header, newline + 1);
    return true;
  }

  private consumeHeredocBody(header: HeredocHeader, start: number): void {
    const { body, bodyEnd } = readHeredocBody(this.input, start, header);
    // An unquoted delimiter still expands substitutions inside the body.
    if (!header.literal) collectSubstitutions(body, this.commands);
    // The newline after the delimiter word ended this simple command.
    this.endCommand();
    this.i = bodyEnd;
  }

  /** Unquoted operators end the current simple command. */
  private operator(): boolean {
    const ch = this.ch;
    if (!OPERATOR_CHARS.has(ch)) return false;
    this.endCommand();
    if (DOUBLED_OPERATORS.has(ch) && this.input[this.i + 1] === ch) this.i++;
    this.i++;
    return true;
  }

  /** Subshell / group boundaries also start a fresh command position. */
  private group(): boolean {
    if (!GROUP_CHARS.has(this.ch)) return false;
    this.endCommand();
    this.i++;
    return true;
  }

  private blank(): boolean {
    if (!BLANK_CHARS.has(this.ch)) return false;
    this.endToken();
    this.i++;
    return true;
  }
}

/** Strip a leading path so `/usr/local/bin/docker` reads as `docker`. */
function basename(token: string): string {
  return token.split("/").pop() ?? token;
}

export interface DockerInvocation {
  /** The subcommand, or null if the command ended before one appeared. */
  subcommand: string | null;
  /** Tokens after the subcommand, in order. */
  args: string[];
  /**
   * Values of every `-f` / `--file` the invocation carries — the compose files
   * and Dockerfiles it operates on. These name the project far more reliably
   * than the cwd does, which is why the gate consults them; see
   * projectDirectories.
   */
  fileArgs: string[];
}

/**
 * `docker build --check` is BuildKit's Dockerfile linter: it resolves the
 * frontend, evaluates the build graph and prints warnings, but produces no
 * image and runs no build step. It is the only way to verify a Dockerfile
 * against the exact frontend a `# syntax=` pin selects, and it is what
 * ~/.claude/rules/dockerfile.md asks for. Nothing about it touches the secret
 * injection, deploy order, or flags a Makefile target encodes, so blocking it
 * bought nothing and cost the ability to check our own Dockerfiles.
 */
function isLintOnlyBuild({ subcommand, args }: DockerInvocation): boolean {
  const isBuild =
    subcommand === "build" || (subcommand === "buildx" && args[0] === "build");
  return isBuild && args.includes("--check");
}

/**
 * Objects whose `prune` reclaims host disk and destroys nothing a project owns.
 *
 * `volume` is deliberately absent and must stay absent: eleven volumes are
 * active on this machine and `idss-mysql` holds real data, so `docker volume
 * prune` is the one prune that destroys work rather than reclaiming waste.
 * `system` is absent too — it is a compound that sweeps several objects at once
 * and grows `--volumes`, so allowing it would smuggle the volume case back in
 * under a different spelling.
 */
const PRUNABLE_OBJECTS = new Set(["image", "container", "builder", "buildx"]);

/**
 * `docker image|container|builder prune` is host-level daemon maintenance: it
 * deletes dangling layers and stale build cache belonging to the *daemon*, not
 * to any project. There is no secret injection, deploy order, or flag set for a
 * Makefile target to encode, and no repo here ships a target for it — the same
 * reasoning that already lets `ps`/`logs`/`inspect` through.
 *
 * Blocking it cost something real: 84 G of `~/.colima` on a host at 70% disk,
 * with the only remedy being a hand-run command outside the hook's view. The
 * carve-out is by *verb after object*, never a blanket `prune`, so
 * `docker volume prune` stays blocked — see PRUNABLE_OBJECTS.
 */
function isHostDaemonPrune({ subcommand, args }: DockerInvocation): boolean {
  if (subcommand === null || !PRUNABLE_OBJECTS.has(subcommand)) return false;
  return args[0] === "prune";
}

/**
 * Docker spells most subcommands two ways: the terse alias (`docker inspect`)
 * and the management form (`docker image inspect`). Matching only the first
 * non-flag token saw the object noun, not the verb, so every management-form
 * read was denied while its alias sailed through — `docker inspect web` allowed,
 * `docker image inspect web` blocked. The verb is what reads or writes, so that
 * is what gets classified.
 */
function isReadOnlyManagement({ subcommand, args }: DockerInvocation): boolean {
  if (subcommand === null || !MANAGEMENT_OBJECTS.has(subcommand)) return false;
  const verb = args[0];
  // `docker image` / `docker image --help` print help and do nothing.
  if (verb === undefined || verb.startsWith("-")) return true;
  return READ_ONLY_VERBS.has(verb);
}

/**
 * Inspect one simple command. Returns null when it does not invoke docker.
 */
export function inspectDockerCommand(tokens: string[]): DockerInvocation | null {
  tokens = unwrapWrappers(tokens);
  let i = 0;

  if (tokens.length === 0) return null;

  const name = basename(tokens[i]);
  if (name !== "docker" && name !== "docker-compose") return null;
  i++;

  const fileArgs: string[] = [];
  const collectFile = (flag: string, value: string | undefined) => {
    if (!FILE_FLAGS.has(flag)) return;
    if (value !== undefined && !value.startsWith("-")) fileArgs.push(value);
  };

  const skipFlags = () => {
    while (i < tokens.length && tokens[i].startsWith("-")) {
      const flag = tokens[i];
      i++;
      if (VALUE_FLAGS.has(flag) && i < tokens.length) {
        collectFile(flag, tokens[i]);
        i++;
      } else {
        const eq = flag.indexOf("=");
        if (eq > 0) collectFile(flag.slice(0, eq), flag.slice(eq + 1));
      }
    }
  };

  skipFlags();
  if (name === "docker" && tokens[i] === "compose") {
    i++;
    skipFlags();
  }

  const args = tokens.slice(i + 1);

  // `-f` after the subcommand too: `docker build -f apps/api/Dockerfile .`
  for (let j = 0; j < args.length; j++) {
    const eq = args[j].indexOf("=");
    if (args[j].startsWith("--") && eq > 0) {
      collectFile(args[j].slice(0, eq), args[j].slice(eq + 1));
    } else {
      collectFile(args[j], args[j + 1]);
    }
  }

  return { subcommand: tokens[i] ?? null, args, fileArgs };
}

/**
 * Should this Bash command be blocked (assuming a Makefile exists)?
 *
 * Blocks when any simple command invokes docker with a subcommand that is not
 * read-only. Mentions of "docker" inside quoted arguments are not invocations.
 */
export function shouldBlock(command: string): boolean {
  for (const tokens of splitIntoCommands(command)) {
    const invocation = inspectDockerCommand(tokens);
    if (!invocation) continue;
    // A bare `docker` with no subcommand just prints help — harmless.
    if (invocation.subcommand === null) continue;
    if (READ_ONLY.has(invocation.subcommand)) continue;
    if (isReadOnlyManagement(invocation)) continue;
    if (isLintOnlyBuild(invocation)) continue;
    if (isHostDaemonPrune(invocation)) continue;
    return true;
  }
  return false;
}

/**
 * The directory a command actually operates in.
 *
 * The hook receives the *session* cwd, which is wherever Claude was started —
 * not where the command runs. A `cd elsewhere && docker …` was therefore judged
 * against the session's Makefile, so a session started in a repo that has one
 * blocked docker everywhere, including scratch directories that have no project
 * to speak of. That is backwards: the policy is "use the Makefile of the project
 * you are operating on", and the leading `cd` names that project.
 *
 * Only a leading `cd` is honoured — tracking directory state across a whole
 * pipeline is guesswork, and guessing wrong here fails open.
 *
 * On its own this is not a gate: consulting *only* the `cd` target let one
 * prepended token switch the guardrail off, because `cd /tmp && docker compose
 * -f ~/homelab/compose.yml up -d` is judged against /tmp, which has no Makefile
 * to deny on behalf of — while the command still deploys the homelab stack. See
 * projectDirectories, which is what the gate actually consults.
 */
export function effectiveCwd(command: string, sessionCwd: string): string {
  const first = splitIntoCommands(command)[0];
  if (!first || first[0] !== "cd" || first.length !== 2) return sessionCwd;

  const target = first[1];
  if (target.startsWith("-")) return sessionCwd;

  const resolved = expandPath(target, sessionCwd);

  return isDirectory(resolved) ? resolved : sessionCwd;
}

/**
 * Every directory a command might belong to, most specific first.
 *
 * A `-f` path is the strongest signal there is: it names the project the command
 * operates on outright, regardless of where the shell happens to be standing.
 * The `cd` target comes next, then the session cwd as the backstop — which is
 * what makes this fail *closed*. Consulting the `cd` target alone meant a
 * directory with no Makefile silently allowed the command; now a Makefile-less
 * scratch dir just falls through to the next candidate, and only a command that
 * matches nothing anywhere is allowed.
 *
 * Relative `-f` paths resolve against the effective cwd, since that is where the
 * command runs.
 */
export function projectDirectories(command: string, sessionCwd: string): string[] {
  const cwd = effectiveCwd(command, sessionCwd);
  const dirs: string[] = [];

  for (const tokens of splitIntoCommands(command)) {
    const invocation = inspectDockerCommand(tokens);
    if (!invocation) continue;
    for (const file of invocation.fileArgs) {
      const abs = expandPath(file, cwd);
      const dir = abs.includes("/") ? abs.slice(0, abs.lastIndexOf("/")) : cwd;
      dirs.push(dir || "/");
    }
  }

  dirs.push(cwd);
  if (cwd !== sessionCwd) dirs.push(sessionCwd);

  // A `-f` can name a path that does not exist. Spawning git with a missing cwd
  // throws rather than failing, so drop those before anyone tries.
  return [...new Set(dirs)].filter(isDirectory);
}

export function expandPath(target: string, base: string): string {
  const home = process.env.HOME ?? "";
  const expanded =
    target === "~" ? home : target.startsWith("~/") ? home + target.slice(1) : target;
  return expanded.startsWith("/") ? expanded : `${base}/${expanded}`;
}

export function isDirectory(path: string): boolean {
  const result = Bun.spawnSync(["test", "-d", path], { stdout: "pipe", stderr: "pipe" });
  return result.exitCode === 0;
}

function findGitRoot(cwd: string): string | null {
  const result = Bun.spawnSync(["git", "rev-parse", "--show-toplevel"], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return null;
  return result.stdout.toString().trim();
}

/**
 * Does this project drive docker through its Makefile?
 *
 * The gate used to be "a Makefile exists", which is not the same claim. The rule
 * this hook enforces is that Makefile targets encode secret injection, deploy
 * order and required flags *for docker* — a Makefile that never mentions docker
 * encodes none of that, and denying on its behalf just blocks work while naming
 * targets that cannot help. `free-planning-poker` and `basalt-ui` both have
 * Makefiles with zero docker references.
 *
 * Deliberately a plain substring check over the whole file, not a target scan:
 * a target that shells out to a script which runs docker still counts, and
 * over-blocking is the safe direction when in doubt.
 */
function makefileDrivesDocker(dir: string): boolean {
  const result = Bun.spawnSync(["cat", `${dir}/Makefile`], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return false;
  return result.stdout.toString().includes("docker");
}

function getMakeTargets(dir: string): string[] {
  const result = Bun.spawnSync(["make", "-pnRr"], {
    cwd: dir,
    stdout: "pipe",
    stderr: "pipe",
  });
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

/** Shared PreToolUse deny: print the permission decision and exit 0. */
export function deny(reason: string): never {
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

  if (!shouldBlock(command)) process.exit(0);

  // Find a project that drives docker through its Makefile. Every candidate is
  // checked, so a scratch directory in the chain cannot switch the gate off.
  const candidates = projectDirectories(command, input.cwd ?? process.cwd());
  const root = candidates
    .map((dir) => findGitRoot(dir) ?? dir)
    .find((dir) => makefileDrivesDocker(dir));

  if (!root) process.exit(0);

  // Makefile exists — deny and suggest targets
  const targets = getMakeTargets(root);
  const targetList =
    targets.length > 0
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
}
