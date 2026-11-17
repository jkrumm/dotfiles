#!/usr/bin/env bun

/**
 * PreToolUse hook: a factory lead cannot bypass a required review.
 *
 * Incident 2026-11-05: an Issue lead was told "do not merge with --admin; leave
 * open for a reviewer", wrote "Owner approved the admin merge" with no such
 * approval in its transcript, and merged a work repo's PR past its required
 * review. A sentence in an answer cannot be the only guard for bypassing
 * another team's rule, so the bypass itself is denied.
 *
 * Active only when FACTORY_SESSION is set (`rd work` / factory lead spawns). The
 * owner's own sessions are untouched; the bypass stays the owner's to do by hand.
 *
 * Denied (command position only — quoted text is data, see docker-makefile.ts):
 *   - `gh pr merge … --admin`;
 *   - `gh api` on a merge endpoint (`…/pulls/<n>/merge`, `…/merges`) with any
 *     method but GET;
 *   - `gh api` that writes rulesets or branch protection (`…/rulesets`,
 *     `…/branches/<b>/protection`) — any method but GET;
 *   - `gh api graphql` carrying a merge / ruleset / branch-protection mutation,
 *     or a query the hook cannot read (`--input`, `-f query=@file`, `$VAR` /
 *     `$(…)` in the query);
 *   - `gh api` with a non-GET method on an endpoint a variable completes
 *     (`repos/o/r/$S`), unless its literal text names an unrelated resource
 *     (`…/issues/$N/comments`) or a single `pulls/$N` id slot;
 *   - the GitHub config sync (`make github-config`, `scripts/github-config.sh`) unless the
 *     command is the plain call and nothing else (SYNC_PLAIN): the script writes
 *     rulesets with `gh api` out of the hook's sight, so what keeps a lead from
 *     loosening protection through it is its own tighten-only mode, which a factory
 *     session cannot leave unless FACTORY_SESSION is cleared, and any env edit,
 *     assignment, chain, quote or glob in the command could clear it. The plain sync is allowed.
 *
 * The tokenizer drops quote types, so `$name` in a single-quoted GraphQL query
 * (`query($o:String!)`) reads as a shell variable and is denied too.
 *
 * Allowed: `gh pr merge --squash|--rebase|--merge|--auto`, `gh api` reads of the
 * same endpoints, and every word above inside quotes (a commit message, a grep).
 *
 * The owner's exception (2026-11-06): `gh pr merge --admin` on the repos in
 * ADMIN_MERGE_REPOS. The repo is the one the command names (`-R`, `--repo`, the
 * PR's URL); a command that names none gets it from the hook's working
 * directory — every remote there (and each `gh-resolved` override) must be a
 * listed repo — but only when nothing in the command can move gh elsewhere: no
 * `cd` / `pushd` / `--chdir`, no `GH_REPO` / `GH_HOST` / `GIT_*` variable. Then it is denied with the hint to
 * name the repo (incident 2026-11-15: Issue 1239's `gh pr merge 125 --admin` was
 * sent to the owner and waited eight hours). `gh api` stays denied on them too.
 *
 * Not covered (same hazard class): `curl`/`wget` straight at api.github.com,
 * `gh alias set` wrapping `--admin`, and other forges' CLIs.
 */

import { collect, type Invocation } from "./broad-kill-guard.ts";

interface HookInput {
  tool_name: string;
  cwd?: string;
  tool_input?: { command?: string; [key: string]: unknown };
}

const OWNER =
  "This bypasses a required review and is the owner's to do by hand, not a factory lead's. " +
  "Leave the PR open for its reviewer, or `factory issue ask` the owner.";

const SYNC_TAMPERING =
  "`make github-config` runs tighten-only in a factory session: it applies only what adds or strengthens protection " +
  "(a repo joins config/pr-required-repos.json, a ruleset or rule is added) and skips, with exit 3, a repo it would loosen. " +
  "This command is not the plain call, and anything around the call (an env edit, a variable, a quote, a glob, a chain) could turn that off. " +
  "Run exactly `make -C <dir> github-config` (or `github-config-tighten`) as its own call; DRY_RUN=1, GITHUB_OWNER=<x>, `> <log> 2>&1` and `; echo rc=$?` may go with it. " +
  "A loosening (a repo leaves the list, a rule, approval or check is dropped, enforcement is lowered) is the owner's: " +
  "raise an Errand (`factory errand raise … --need hands`) for his `make github-config`.";

const NAME_THE_REPO =
  "Name the repo in the command so the hook can check it against the owner's list: " +
  "`gh pr merge <n> -R <owner>/<repo> --squash --admin`.";

// ── gh pr merge ──────────────────────────────────────────────────────────────

/** `--admin` or `--admin=true`; `--admin=false` is a no-op. */
const isAdminFlag = (a: string): boolean => a === "--admin" || (a.startsWith("--admin=") && a.slice(8) !== "false");

/** The owner allowed these and no others (2026-11-06; import dashboard added 2026-11-10, knowledge 2026-11-13); all merge past review from his account. */
const ADMIN_MERGE_REPOS = new Set([
  "IU-Group-Engineering/epos-ai-teamchat-athena",
  "IU-Group-Engineering/epos-tool-athena",
  "IU-Group-Engineering/epos-import-dashboard-athena",
  "IU-Group-Engineering/epos-knowledge-athena",
]);

const PR_URL = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\/\d+\/?$/;
const MERGE_VALUE_FLAGS = new Set(["-b", "--body", "-F", "--body-file", "-t", "--subject", "-A", "--author-email", "--match-head-commit"]);

/** Every repo the command itself names: `-R`, `--repo`, and the target PR's URL. Values of other flags are text, not targets. */
function namedRepos(args: string[]): string[] {
  const repos: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-R" || a === "--repo") repos.push(args[++i] ?? "");
    else if (a.startsWith("--repo=")) repos.push(a.slice(7));
    else if (a.startsWith("-R") && !a.startsWith("--")) repos.push(a.slice(2));
    else if (MERGE_VALUE_FLAGS.has(a)) i++;
    else if (!a.startsWith("-")) {
      const url = PR_URL.exec(a);
      if (url) repos.push(url[1]);
      else if (a.includes("://")) repos.push(a); // another host or shape: never on the list
    }
  }
  return repos;
}

// ── Where the working directory points ──────────────────────────────────────

/** `owner/repo` of every repo gh would consider for the checkout at `cwd` (`""` for one it cannot read); null when `cwd` is no checkout. */
export type RepoResolver = (cwd: string) => string[] | null;

const GITHUB_REMOTE = /^(?:https:\/\/(?:[^@/]+@)?|ssh:\/\/git@|git@)github\.com[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?\/?$/;

/** Reads the remotes from git config: the fetch URL of each, or the repo `gh repo set-default` pinned for it. */
export const gitRepoResolver: RepoResolver = (cwd) => {
  const proc = Bun.spawnSync(["git", "-C", cwd, "config", "--get-regexp", String.raw`^remote\..+\.(url|gh-resolved)$`], {
    stdout: "pipe",
    stderr: "ignore",
  });
  if (proc.exitCode === 1) return []; // git config: no key matched, so no remote
  if (proc.exitCode !== 0) return null;
  const url = new Map<string, string>();
  const pinned = new Map<string, string>();
  for (const line of proc.stdout.toString().split("\n")) {
    const m = /^remote\.(.+)\.(url|gh-resolved) (.+)$/.exec(line.trim());
    if (!m) continue;
    (m[2] === "url" ? url : pinned).set(m[1], m[3]);
  }
  return [...url].map(([name, u]) => {
    const pin = pinned.get(name);
    return pin && pin !== "base" ? pin : (GITHUB_REMOTE.exec(u)?.[1] ?? "");
  });
};

/** Anything in the command that can make gh run in, or target, another repo than the hook's working directory. */
const MOVES_GH = /(?:^|[^\w-])(?:cd|pushd|popd)(?![\w-])|--chdir|\benv\s+(?:\S+\s+)*-C\b|\bGH_(?:REPO|HOST)\b|\bGIT_[A-Z_]+/;
/** The same variables set in the hook's own environment, which the Bash call inherits. */
const MOVING_ENV = ["GH_REPO", "GH_HOST", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"];

interface Context {
  cwd?: string;
  resolveRepos?: RepoResolver;
}

/** Null when the admin merge may run, else the denial. */
function adminMergeDenial(command: string, args: string[], ctx: Context): string | null {
  const NOT_LISTED = `\`gh pr merge --admin\` merges past required reviews and checks. ${OWNER}`;
  const named = namedRepos(args);
  if (named.length > 0) return named.every((r) => ADMIN_MERGE_REPOS.has(r)) ? null : NOT_LISTED;

  if (MOVES_GH.test(command) || MOVING_ENV.some((k) => process.env[k])) {
    return `\`gh pr merge --admin\` names no repo, and a \`cd\`, \`--chdir\`, \`GH_REPO\`, \`GH_HOST\` or \`GIT_*\` variable means the working directory does not say which one. ${NAME_THE_REPO}`;
  }
  const repos = ctx.cwd ? (ctx.resolveRepos ?? gitRepoResolver)(ctx.cwd) : null;
  if (!repos || repos.length === 0) {
    return `\`gh pr merge --admin\` names no repo and the hook cannot resolve one from the working directory's remotes. ${NAME_THE_REPO}`;
  }
  return repos.every((r) => ADMIN_MERGE_REPOS.has(r)) ? null : NOT_LISTED;
}

// ── gh api ───────────────────────────────────────────────────────────────────

const API_VALUE_FLAGS = new Set([
  "-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "--input",
  "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview",
]);
const API_BODY_FLAGS = new Set(["-f", "--raw-field", "-F", "--field", "--input"]);

interface ApiCall {
  endpoint: string;
  method: string;
  /** Values of -f/-F/--field/--raw-field (`key=value`) and `--input` paths. */
  fields: string[];
  hasInput: boolean;
}

function parseApi(args: string[]): ApiCall {
  let endpoint = "";
  let method: string | undefined;
  const fields: string[] = [];
  let hasInput = false;

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const eq = a.startsWith("--") ? a.indexOf("=") : -1;
    const flag = eq === -1 ? a : a.slice(0, eq);
    if (!a.startsWith("-") || a === "-") {
      if (!endpoint) endpoint = a;
      continue;
    }
    // `-XPOST`, `-fkey=v`: attached short-flag value.
    const short = !a.startsWith("--") && a.length > 2 ? a.slice(0, 2) : undefined;
    const name = short && API_VALUE_FLAGS.has(short) ? short : flag;
    if (!API_VALUE_FLAGS.has(name)) continue;
    const value = eq !== -1 ? a.slice(eq + 1) : short && name === short ? a.slice(2) : (args[++i] ?? "");
    if (name === "-X" || name === "--method") method = value.toUpperCase();
    if (name === "--input") hasInput = true;
    if (API_BODY_FLAGS.has(name)) fields.push(value);
  }
  // gh sends POST as soon as a body or field is given and no method is.
  return { endpoint, method: method ?? (fields.length ? "POST" : "GET"), fields, hasInput };
}

/** `https://api.github.com/repos/o/r/rulesets?x=1` → `repos/o/r/rulesets`. */
function normalizeEndpoint(raw: string): string {
  return raw
    .replace(/^https?:\/\/[^/]+\//, "")
    .replace(/[?#].*$/, "")
    .replace(/^\/+|\/+$/g, "");
}

const MERGE_ENDPOINT = /(?:^|\/)(?:pulls\/[^/]+\/merge|merges)$/;
const RULE_ENDPOINT = /(?:^|\/)rulesets(?:\/|$)|\/branches\/.+\/protection(?:\/|$)|\/protected_branches?(?:\/|$)/;
const GRAPHQL_MUTATION =
  /\b(?:mergePullRequest|mergeBranch|(?:create|update|delete)(?:RepositoryRuleset|BranchProtectionRule))\b/;

/**
 * A value only the shell can resolve: `$VAR`, `${VAR}`, a backtick, or the NUL
 * the tokenizer leaves for a `$(…)` substitution.
 */
const UNRESOLVED = /\$|`|\0/;

/**
 * A non-GET call whose endpoint holds a variable is allowed only when its literal
 * text names an unrelated resource (`repos/$REPO/issues/$N/comments`) or ends in
 * a single id slot (`pulls/$N`). A variable can carry the whole tail
 * (`S=pulls/12/merge; gh api -X PUT repos/o/r/$S`), so anything else is denied.
 */
const SAFE_WITH_VARIABLE =
  /(?:^|\/)(?:issues|labels|releases|statuses|check-runs|deployments|dispatches|contents|git|actions|comments|hooks)(?:\/|$)|(?:^|\/)pulls\/x$/;

function apiViolation(args: string[]): string | null {
  const call = parseApi(args);
  const hasVariable = UNRESOLVED.test(call.endpoint);
  // `repos/o/r/pulls/$N/merge` still shows its shape with the variable blanked.
  const endpoint = normalizeEndpoint(call.endpoint.replace(/\$\{?\w+\}?|\0/g, "x"));

  if (endpoint === "graphql") {
    // A query read from a file, stdin or the shell cannot be inspected.
    if (call.hasInput || call.fields.some((f) => /^query=@/.test(f) || (/^query=/.test(f) && UNRESOLVED.test(f)))) {
      return `\`gh api graphql\` with a query from a file, stdin or a shell expansion cannot be inspected for a merge or ruleset mutation. ${OWNER}`;
    }
    if (call.fields.some((f) => GRAPHQL_MUTATION.test(f))) {
      return `A GraphQL merge / ruleset / branch-protection mutation. ${OWNER}`;
    }
    return null;
  }

  if (call.method === "GET") return null;
  if (MERGE_ENDPOINT.test(endpoint)) return `\`gh api\` ${call.method} on a merge endpoint (${endpoint}). ${OWNER}`;
  if (RULE_ENDPOINT.test(endpoint)) {
    return `\`gh api\` ${call.method} on rulesets or branch protection (${endpoint}). ${OWNER}`;
  }
  if (hasVariable && !SAFE_WITH_VARIABLE.test(endpoint)) {
    return `\`gh api\` ${call.method} on an endpoint the shell completes (${call.endpoint}); it cannot be checked for a merge or ruleset write. ${OWNER}`;
  }
  return null;
}

// ── The GitHub config sync ───────────────────────────────────────────────────

const SYNC_SCRIPT = /(?:^|\/)github-config\.sh$/;
/**
 * What a sync command may look like: nothing but the call itself, so no environment
 * edit, assignment, glob, quote or expansion can ride along and clear the marker that
 * makes the script tighten-only (a name can be spelled around any denylist:
 * `FACTORY''_SESSION`, `FACTORY_SESS[I]ON=`). An allowlist, because three rounds of
 * review kept finding the next spelling of a denylist.
 *
 *   [DRY_RUN=1] [GITHUB_OWNER=x] make [-C <dir>] github-config[-tighten|-dry]
 *   [DRY_RUN=1] [GITHUB_OWNER=x] [bash] <path>/github-config.sh [--tighten-only]
 *   … optionally followed by `> <log>`, `2>&1` and `; echo rc=$?`
 */
const SYNC_PATH = String.raw`[\w./~-]`;
const SYNC_PLAIN = new RegExp(
  String.raw`^(?:(?:DRY_RUN|GITHUB_OWNER)=[\w.-]+\s+)*` +
    String.raw`(?:make\s+(?:-C\s+${SYNC_PATH}+\s+)?github-config(?:-tighten|-dry)?` +
    String.raw`|(?:bash\s+)?${SYNC_PATH}*github-config\.sh(?:\s+--tighten-only)?)` +
    String.raw`(?:\s+>\s*${SYNC_PATH}+)?(?:\s+2>&1)?(?:\s*;\s*echo rc=\$\?)?\s*$`,
);
/** `bash scripts/github-config.sh`: the tokenizer sees a shell without `-c` as nothing to look into. */
const SYNC_VIA_SHELL = /(?:^|[;&|\n(`]|\$\()\s*(?:\S+\s+)*?(?:bash|sh|zsh|dash|ksh|source|\.)\s+(?:-\S+\s+)*\S*github-config\.sh\b/;

/** `make … github-config[-tighten]`, `scripts/github-config.sh` or `bash …/github-config.sh`. */
function runsSync(inv: Invocation): boolean {
  if (inv.name === "make") return inv.args.some((a) => a === "github-config" || a === "github-config-tighten");
  return SYNC_SCRIPT.test(inv.name);
}

// ── Policy ───────────────────────────────────────────────────────────────────

/** Leading words of a gh command, skipping `-R <repo>` / `--repo <repo>` (cobra allows them before the verb). */
function subcommands(args: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length && out.length < 2; i++) {
    const a = args[i];
    if (a === "-R" || a === "--repo") i++;
    else if (!a.startsWith("-")) out.push(a);
  }
  return out;
}

/** Why this command must not run in a factory session, or null when it may. */
export function findViolation(command: string, ctx: Context = {}): string | null {
  // gh's own `{owner}` / `{repo}` / `{branch}` endpoint placeholders: the tokenizer reads braces as command groups.
  const flattened = command.replace(/\{(owner|repo|branch)\}/g, "$1");
  const invocations = collect(flattened) as Invocation[];
  if ((invocations.some(runsSync) || SYNC_VIA_SHELL.test(flattened)) && !SYNC_PLAIN.test(flattened.trim())) return SYNC_TAMPERING;
  for (const inv of invocations) {
    if (inv.name !== "gh") continue;
    const positionals = subcommands(inv.args);

    if (positionals[0] === "pr" && positionals[1] === "merge" && inv.args.some(isAdminFlag)) {
      const denial = adminMergeDenial(flattened, inv.args, ctx);
      if (denial) return denial;
    }
    if (positionals[0] === "api") {
      const at = inv.args.indexOf("api");
      const violation = apiViolation(inv.args.slice(at + 1));
      if (violation) return violation;
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
  if (!process.env.FACTORY_SESSION) process.exit(0);
  const input: HookInput = JSON.parse(await Bun.stdin.text());
  if (input.tool_name !== "Bash") process.exit(0);

  const violation = findViolation((input.tool_input?.command ?? "").trim(), { cwd: input.cwd ?? process.cwd() });
  if (violation) deny(violation);
}
