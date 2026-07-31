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
]);

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
  const commands: string[][] = [];
  let current: string[] = [];
  let token = "";
  let hasToken = false;

  const endToken = () => {
    if (hasToken) {
      current.push(token);
      token = "";
      hasToken = false;
    }
  };
  const endCommand = () => {
    endToken();
    if (current.length > 0) {
      commands.push(current);
      current = [];
    }
  };
  const add = (text: string) => {
    token += text;
    hasToken = true;
  };

  const findClose = (start: number, open: string, close: string): number =>
    findClosing(input, start, open, close);

  /** Parse a nested command substitution and fold its commands into ours. */
  const recurse = (body: string) => {
    for (const cmd of splitIntoCommands(body)) commands.push(cmd);
    // The substitution itself yields a value in the outer token.
    add("\0");
  };

  let i = 0;
  while (i < input.length) {
    const ch = input[i];

    // Escape outside quotes — next character is literal.
    if (ch === "\\") {
      if (i + 1 < input.length) add(input[i + 1]);
      i += 2;
      continue;
    }

    // Single quotes: pure data, no substitution of any kind.
    if (ch === "'") {
      const close = input.indexOf("'", i + 1);
      const end = close === -1 ? input.length : close;
      add(input.slice(i + 1, end));
      i = end + 1;
      continue;
    }

    // Double quotes: data, but $(...) and `...` still run.
    if (ch === '"') {
      i++;
      while (i < input.length && input[i] !== '"') {
        if (input[i] === "\\") {
          if (i + 1 < input.length) add(input[i + 1]);
          i += 2;
          continue;
        }
        if (input[i] === "$" && input[i + 1] === "(") {
          const end = findClose(i + 2, "(", ")");
          recurse(input.slice(i + 2, end));
          i = end + 1;
          continue;
        }
        if (input[i] === "`") {
          const end = findClose(i + 1, "", "`");
          recurse(input.slice(i + 1, end));
          i = end + 1;
          continue;
        }
        add(input[i]);
        i++;
      }
      i++; // past closing quote
      hasToken = true; // "" is still a token
      continue;
    }

    // Command substitution outside quotes.
    if (ch === "$" && input[i + 1] === "(") {
      const end = findClose(i + 2, "(", ")");
      recurse(input.slice(i + 2, end));
      i = end + 1;
      continue;
    }
    if (ch === "`") {
      const end = findClose(i + 1, "", "`");
      recurse(input.slice(i + 1, end));
      i = end + 1;
      continue;
    }

    // Heredoc. The body is stdin data, never commands — a commit message or a
    // doc written with `<<'EOF'` routinely *mentions* docker. `<<<` is a
    // herestring (a word, not a heredoc), so it falls through to normal parsing.
    if (ch === "<" && input[i + 1] === "<" && input[i + 2] !== "<") {
      let j = i + 2;
      const dashed = input[j] === "-";
      if (dashed) j++;
      while (input[j] === " " || input[j] === "\t") j++;

      // Read the delimiter word. Quoting it (any part of it) disables
      // substitution inside the body — the `<<'EOF'` form.
      let delimiter = "";
      let literal = false;
      while (j < input.length && !/[\s;&|<>()]/.test(input[j])) {
        const c = input[j];
        if (c === "'" || c === '"') {
          literal = true;
          const close = input.indexOf(c, j + 1);
          const end = close === -1 ? input.length : close;
          delimiter += input.slice(j + 1, end);
          j = end + 1;
          continue;
        }
        if (c === "\\") {
          literal = true;
          if (j + 1 < input.length) delimiter += input[j + 1];
          j += 2;
          continue;
        }
        delimiter += c;
        j++;
      }

      if (delimiter === "") {
        // Not a heredoc we understand — treat as ordinary redirection chars.
        add("<<");
        i += 2;
        continue;
      }

      // The body runs from the next newline to a line equal to the delimiter.
      const newline = input.indexOf("\n", j);
      if (newline === -1) {
        endCommand();
        i = input.length;
        continue;
      }

      let pos = newline + 1;
      let body = "";
      let bodyEnd = input.length;
      while (pos <= input.length) {
        let lineEnd = input.indexOf("\n", pos);
        if (lineEnd === -1) lineEnd = input.length;
        const line = input.slice(pos, lineEnd);
        if ((dashed ? line.replace(/^\t+/, "") : line) === delimiter) {
          bodyEnd = lineEnd;
          break;
        }
        body += line + "\n";
        if (lineEnd === input.length) break;
        pos = lineEnd + 1;
      }

      // An unquoted delimiter still expands substitutions inside the body.
      if (!literal) collectSubstitutions(body, commands);

      // The newline after the delimiter word ended this simple command.
      endCommand();
      i = bodyEnd;
      continue;
    }

    // Unquoted operators end the current simple command.
    if (ch === "|" || ch === ";" || ch === "&" || ch === "\n") {
      endCommand();
      // Consume the doubled forms (&&, ||) as one operator.
      if ((ch === "|" || ch === "&") && input[i + 1] === ch) i++;
      i++;
      continue;
    }

    // Subshell / group boundaries also start a fresh command position.
    if (ch === "(" || ch === ")" || ch === "{" || ch === "}") {
      endCommand();
      i++;
      continue;
    }

    if (ch === " " || ch === "\t" || ch === "\r") {
      endToken();
      i++;
      continue;
    }

    add(ch);
    i++;
  }

  endCommand();
  return commands;
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
  let i = 0;

  // Skip leading environment assignments and wrapper commands (and their flags).
  let sawWrapper = false;
  while (i < tokens.length) {
    const t = tokens[i];
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) {
      i++;
      continue;
    }
    if (sawWrapper && t.startsWith("-")) {
      i++;
      continue;
    }
    if (WRAPPERS.has(basename(t))) {
      i++;
      sawWrapper = true;
      continue;
    }
    break;
  }

  if (i >= tokens.length) return null;

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

function expandPath(target: string, base: string): string {
  const home = process.env.HOME ?? "";
  const expanded =
    target === "~" ? home : target.startsWith("~/") ? home + target.slice(1) : target;
  return expanded.startsWith("/") ? expanded : `${base}/${expanded}`;
}

function isDirectory(path: string): boolean {
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
