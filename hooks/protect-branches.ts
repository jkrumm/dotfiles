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
 * `basalt-ui` stranded commits in six direct-to-master repos (rb, linewatch,
 * weatherorb, basalt-ui-obsidian and two image repos) and burned a session
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

import { deny, effectiveCwd, expandPath, isDirectory, splitIntoCommands } from "./docker-makefile";

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

/** Fallback is safe but must not be silent: a stderr line makes it observable. */
function warnFallback(why: string): void {
  process.stderr.write(`protect-branches: pr-required-repos.json ${why} — using built-in fallback list\n`);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((r) => typeof r === "string");
}

function stringArrayOr(value: unknown, fallback: string[]): string[] {
  return isStringArray(value) ? value : fallback;
}

function parseRepoConfig(data: { repos?: unknown; directToMain?: unknown }): RepoConfig {
  if (!isStringArray(data.repos)) warnFallback("has no valid `repos` string array");
  return {
    prRequired: stringArrayOr(data.repos, PR_REQUIRED_FALLBACK),
    directToMain: stringArrayOr(data.directToMain, []),
  };
}

function describeError(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export async function loadRepoConfig(): Promise<RepoConfig> {
  try {
    const f = Bun.file(`${process.env.HOME}/.claude/pr-required-repos.json`);
    if (await f.exists()) return parseRepoConfig((await f.json()) as { repos?: unknown; directToMain?: unknown });
    warnFallback("is missing");
  } catch (err) {
    warnFallback(`is unreadable (${describeError(err)})`);
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
 * A wrapper prefix (`timeout 60 git …`, `command git …`) is tolerated. An alias
 * defined on the command line (`-c alias.p=push`) is expanded, so `git -c
 * alias.p=push p origin main` reads as the push it is.
 */
export function inspectGit(tokens: string[]): GitInvocation | null {
  const g = gitIndex(tokens);
  if (g === -1) return null;

  const flags = readGlobalFlags(tokens, g + 1);
  const { subcommand, args } = expandAliases(
    tokens[flags.end] ?? null,
    tokens.slice(flags.end + 1),
    flags.aliases
  );
  return { subcommand, args, cDirs: flags.cDirs };
}

function gitIndex(tokens: string[]): number {
  return tokens.findIndex((t) => basename(t) === "git");
}

interface GlobalFlags {
  cDirs: string[];
  aliases: Map<string, string>;
  /** Index of the first token after git's global flags. */
  end: number;
}

function readGlobalFlags(tokens: string[], from: number): GlobalFlags {
  const flags: GlobalFlags = { cDirs: [], aliases: new Map(), end: from };
  while (flags.end < tokens.length && tokens[flags.end].startsWith("-")) {
    flags.end += readGlobalFlag(tokens, flags.end, flags);
  }
  return flags;
}

/** Record one global flag's value; returns how many tokens it occupied. */
function readGlobalFlag(tokens: string[], i: number, flags: GlobalFlags): number {
  const token = tokens[i];
  if (!GIT_VALUE_FLAGS.has(token)) return 1;
  recordGlobalValue(token, tokens[i + 1], flags);
  return 2;
}

function recordGlobalValue(token: string, value: string | undefined, flags: GlobalFlags): void {
  if (token === "-C" && value !== undefined) flags.cDirs.push(value);
  else if (token === "-c") recordAlias(value, flags.aliases);
}

function recordAlias(value: string | undefined, aliases: Map<string, string>): void {
  const alias = value?.match(/^alias\.([^=]+)=(.*)$/s);
  if (alias) aliases.set(alias[1], alias[2]);
}

const MAX_ALIAS_DEPTH = 5;

function expandAliases(
  subcommand: string | null,
  args: string[],
  aliases: Map<string, string>,
  depth = 0
): { subcommand: string | null; args: string[] } {
  const body = aliasBody(subcommand, aliases, depth);
  if (body === undefined) return { subcommand, args };
  if (body.startsWith("!")) return shellAlias(body.slice(1), subcommand, args);
  return expandAliasWords(aliasWords(body), args, aliases, depth);
}

function shellAlias(
  body: string,
  subcommand: string | null,
  args: string[]
): { subcommand: string | null; args: string[] } {
  return shellAliasPush(body) ?? { subcommand, args };
}

function expandAliasWords(
  words: string[],
  args: string[],
  aliases: Map<string, string>,
  depth: number
): { subcommand: string | null; args: string[] } {
  return expandAliases(nextWord(words), [...words, ...args], aliases, depth + 1);
}

/** git ignores an alias that shadows a built-in, so a `push` is never expanded. */
function aliasBody(
  subcommand: string | null,
  aliases: Map<string, string>,
  depth: number
): string | undefined {
  if (depth >= MAX_ALIAS_DEPTH || subcommand === null || subcommand === "push") return undefined;
  return aliases.get(subcommand);
}

function aliasWords(body: string): string[] {
  const words = body.trim().split(/\s+/);
  if (basename(words[0]) === "git") words.shift();
  return words;
}

/** A `!` alias runs through the shell: judge the first push among its nested commands. */
function shellAliasPush(body: string): { subcommand: string; args: string[] } | undefined {
  const nested = splitIntoCommands(body).map(inspectGit);
  const push = nested.find((git) => git?.subcommand === "push");
  return push ? { subcommand: "push", args: push.args } : undefined;
}

function nextWord(words: string[]): string | null {
  return words.shift() ?? null;
}

/**
 * Every git directory the command names: `--git-dir=<x>`, `--git-dir <x>` and a
 * `GIT_DIR=<x>` assignment (as a prefix, or an `export`). git judges the repo
 * from these, not from the cwd.
 */
export function gitDirsOf(tokens: string[]): string[] {
  const g = gitIndex(tokens);
  const isExport = tokens[0] === "export";
  if (g === -1 && !isExport) return [];
  return tokens.flatMap((_, i) => gitDirAt(tokens, i, g, isExport));
}

function gitDirAt(tokens: string[], i: number, g: number, isExport: boolean): string[] {
  const assigned = gitDirAssignment(tokens[i], i < g || isExport);
  return assigned.length > 0 ? assigned : gitDirFlag(tokens, i, g);
}

/** `--git-dir` only counts after the `git` token. */
function gitDirFlag(tokens: string[], i: number, g: number): string[] {
  if (g === -1 || i <= g) return [];
  return gitDirValue(tokens, i);
}

function gitDirAssignment(t: string, counts: boolean): string[] {
  return counts && t.startsWith("GIT_DIR=") ? [t.slice("GIT_DIR=".length)] : [];
}

function gitDirValue(tokens: string[], i: number): string[] {
  const t = tokens[i];
  if (t.startsWith("--git-dir=")) return [t.slice("--git-dir=".length)];
  const value = tokens[i + 1];
  return t === "--git-dir" && value !== undefined ? [value] : [];
}

/** A path the static parse cannot resolve: shell expansion or a substitution. */
function isDynamic(value: string): boolean {
  return /[$`\0]/.test(value);
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

  const explicit = splitIntoCommands(command).flatMap((tokens) => explicitDirs(tokens, cwd));
  if (cwd !== sessionCwd) explicit.push(cwd);

  const resolved = [...new Set(explicit)].filter(isDirectory);
  return resolved.length > 0 ? resolved : [sessionCwd];
}

/** Directories one command names itself: `git -C <dir>`, `--git-dir`, `GIT_DIR`. */
function explicitDirs(tokens: string[], cwd: string): string[] {
  const cDirs = inspectGit(tokens)?.cDirs ?? [];
  return [
    ...cDirs.map((dir) => expandPath(dir, cwd)),
    ...gitDirsOf(tokens).map((dir) => repoOfGitDir(expandPath(dir, cwd))),
  ];
}

/** `<repo>/.git` belongs to `<repo>`; a bare git dir is its own repo. */
function repoOfGitDir(dir: string): string {
  const trimmed = dir.replace(/\/+$/, "");
  return basename(trimmed) === ".git" ? trimmed.slice(0, trimmed.length - 5) || "/" : trimmed;
}

/**
 * True when a `--git-dir`/`GIT_DIR` points somewhere that cannot be resolved
 * statically (a variable, a substitution, a missing directory). The repo git
 * will use is then unknown, so a push must be denied rather than guessed.
 */
export function hasUnresolvableGitDir(command: string, sessionCwd: string): boolean {
  const cwd = effectiveCwd(command, sessionCwd);
  return splitIntoCommands(command).some((tokens) =>
    gitDirsOf(tokens).some((dir) => isDynamic(dir) || !isDirectory(expandPath(dir, cwd)))
  );
}

// ── What the push does ───────────────────────────────────────────────────────

export type PushKind =
  | { kind: "none" }
  /** `--force`/`-f` without `--force-with-lease` — blocked on every branch. */
  | { kind: "hard-force" }
  /** `--all` / `--mirror` — pushes every branch, protected ones included. */
  | { kind: "all-refs" }
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
    const push = pushKindOf(tokens);
    if (IMMEDIATE_KINDS.has(push.kind)) return push;
    verdict = mergeVerdict(verdict, push);
  }

  return verdict;
}

/** Kinds that decide the whole command on their own. */
const IMMEDIATE_KINDS = new Set<PushKind["kind"]>(["all-refs", "hard-force"]);

const ALL_REF_FLAGS = ["--all", "--mirror"];

function pushKindOf(tokens: string[]): PushKind {
  const git = inspectGit(tokens);
  if (!git || git.subcommand !== "push") return { kind: "none" };
  return classifyPush(git.args);
}

function classifyPush(args: string[]): PushKind {
  if (ALL_REF_FLAGS.some((flag) => args.includes(flag))) return { kind: "all-refs" };
  const { positional, hardForce } = scanPushArgs(args);
  if (hardForce) return { kind: "hard-force" };
  // positional: [] bare, [remote], [remote, ...refspecs]
  return classifyRefspecs(positional.slice(1));
}

/** Split a push's arguments into positionals and the force verdict. */
function scanPushArgs(args: string[]): { positional: string[]; hardForce: boolean } {
  const operands = withoutFlagValues(args);
  const lease = args.some((a) => a.startsWith("--force-with-lease"));
  return {
    positional: operands.filter((a) => !a.startsWith("-")),
    hardForce: operands.some(isForceFlag) && !lease,
  };
}

function withoutFlagValues(args: string[]): string[] {
  const out: string[] = [];
  for (let j = 0; j < args.length; j++) {
    if (PUSH_VALUE_FLAGS.has(args[j])) j++;
    else out.push(args[j]);
  }
  return out;
}

/** `--force`, or a short-flag cluster (`-fu`) scanned up to `o`, whose value is the rest. */
function isForceFlag(arg: string): boolean {
  return arg === "--force" || (/^-[^-]/.test(arg) && arg.slice(1).split("o")[0].includes("f"));
}

function classifyRefspecs(refspecs: string[]): PushKind {
  if (refspecs.some((spec) => PROTECTED.includes(destinationBranch(spec)))) {
    return { kind: "protected-ref" };
  }
  // A leading `+` forces that one ref whatever the flags say.
  if (refspecs.some((spec) => spec.startsWith("+"))) return { kind: "hard-force" };
  return followsCurrentBranch(refspecs) ? { kind: "current-branch" } : { kind: "none" };
}

/** A bare push, or any `HEAD`/dynamic refspec, writes to the current branch. */
function followsCurrentBranch(refspecs: string[]): boolean {
  return refspecs.length === 0 || refspecs.some(isCurrentBranchSpec);
}

/** A refspec the parse cannot resolve (`$BRANCH`) is judged as the current branch. */
function isCurrentBranchSpec(spec: string): boolean {
  return spec === "HEAD" || isDynamic(destinationBranch(spec));
}

function mergeVerdict(verdict: PushKind, push: PushKind): PushKind {
  if (push.kind === "protected-ref") return push;
  if (push.kind === "current-branch" && verdict.kind === "none") return push;
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

// ── Main ─────────────────────────────────────────────────────────────────────

if (import.meta.main) {
  const input: HookInput = JSON.parse(await Bun.stdin.text());

  if (input.tool_name !== "Bash") process.exit(0);

  const command = (input.tool_input?.command ?? "").trim();
  const push = inspectPush(command);
  if (push.kind === "none") process.exit(0);

  const cwd = input.cwd ?? process.cwd();
  if (hasUnresolvableGitDir(command, cwd)) {
    deny(
      [
        "git push with an unresolvable --git-dir / GIT_DIR is blocked in Claude Code.",
        "",
        "The repository git will use cannot be determined statically, so the PR rule cannot be checked.",
        "Use a literal path, or run the command in your terminal.",
      ].join("\n")
    );
  }

  const config = await loadRepoConfig();
  const enforceDir = repoDirectories(command, cwd).find((dir) =>
    requiresPR(dir, config)
  );
  if (!enforceDir) process.exit(0);

  if (push.kind === "hard-force") {
    deny(
      [
        "git push --force is blocked in Claude Code.",
        "",
        "Claude Code must not rewrite history on remote branches.",
        "Use --force-with-lease for feature branches (safe: fails if remote has new commits).",
        "To force push: run the command directly in your terminal.",
      ].join("\n")
    );
  }

  if (push.kind === "all-refs") {
    deny(
      [
        "git push --all / --mirror is blocked in Claude Code.",
        "",
        `It pushes every branch, protected ones included — ${enforceDir} requires a PR.`,
        "Push the feature branch by name.",
      ].join("\n")
    );
  }

  if (push.kind === "protected-ref") {
    deny(
      [
        `Pushing to a protected branch is blocked in Claude Code — ${enforceDir} requires a PR.`,
        "",
        "All changes must go through a pull request:",
        "  1. Work on a feature branch",
        "  2. git push origin <feature-branch>",
        "  3. gh pr create",
        "",
        "To push directly: run the command in your terminal (admin bypass).",
      ].join("\n")
    );
  }

  const current = getCurrentBranch(enforceDir);
  if (current && PROTECTED.includes(current)) {
    deny(
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
